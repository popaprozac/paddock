package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

type testControl struct {
	srv    *server
	url    string
	client *http.Client
	dir    string
}

// newTestControl runs a control plane on a loopback port with its own CA, and a client that
// trusts that CA alone, as an enrolled host does.
func newTestControl(t *testing.T) *testControl {
	t.Helper()
	dir := t.TempDir()
	authority, err := loadOrCreateAuthority(dir)
	if err != nil {
		t.Fatal(err)
	}
	st, err := openState(dir)
	if err != nil {
		t.Fatal(err)
	}
	audit, err := openAuditLog(filepath.Join(dir, "audit.log"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { audit.close() })
	srv := newServer(st, authority, audit)
	cert, err := authority.serverCertificate(currentReach(nil))
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewUnstartedServer(srv.routes())
	ts.TLS = &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{*cert}}
	ts.StartTLS()
	t.Cleanup(func() {
		srv.closeAll()
		ts.Close()
	})
	pool := x509.NewCertPool()
	pool.AddCert(authority.cert)
	client := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool}}}
	return &testControl{srv: srv, url: ts.URL, client: client, dir: dir}
}

func newHostKey(t *testing.T) (*ecdsa.PrivateKey, []byte) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	return key, der
}

func (c *testControl) token(t *testing.T) string {
	t.Helper()
	token, _, err := c.srv.state.newToken(hostKind, c.srv.authority.pin(), time.Hour, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return token
}

func (c *testControl) enroll(t *testing.T, token, name string, publicKey []byte) (int, enrollResponse) {
	t.Helper()
	body, _ := json.Marshal(enrollRequest{Token: token, Name: name, PublicKey: publicKey})
	response, err := c.client.Post(c.url+"/v1/enroll", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	var decoded enrollResponse
	_ = json.NewDecoder(response.Body).Decode(&decoded)
	return response.StatusCode, decoded
}

// link opens a host's link and answers its challenge by signing with key.
func (c *testControl) link(t *testing.T, host string, key *ecdsa.PrivateKey) (*websocket.Conn, message, error) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, strings.Replace(c.url, "https", "wss", 1)+"/v1/link",
		&websocket.DialOptions{HTTPClient: c.client})
	if err != nil {
		t.Fatal(err)
	}
	var challenge message
	if err := wsjson.Read(ctx, conn, &challenge); err != nil || challenge.Type != "challenge" || len(challenge.Nonce) != 32 {
		t.Fatalf("challenge %+v, %v", challenge, err)
	}
	digest := sha256.Sum256(append([]byte(linkContext), challenge.Nonce...))
	signature, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	if err := wsjson.Write(ctx, conn, message{Type: "auth", Host: host, Signature: signature}); err != nil {
		t.Fatal(err)
	}
	var welcome message
	err = wsjson.Read(ctx, conn, &welcome)
	return conn, welcome, err
}

func (c *testControl) waitFor(t *testing.T, what string, check func([]hostStatus) bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if check(c.srv.status()) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s: %+v", what, c.srv.status())
}

func TestJoinTokenIsSingleUseAndExpires(t *testing.T) {
	st, err := openState(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	pin := bytes.Repeat([]byte{7}, 32)
	now := time.Now()
	token, _, err := st.newToken(hostKind, pin, time.Hour, now)
	if err != nil {
		t.Fatal(err)
	}
	_, secret, carried, err := parseToken(token)
	if err != nil || !bytes.Equal(carried, pin) {
		t.Fatalf("parse: %v, pin %x", err, carried)
	}
	if ok, _ := st.useToken(secret, hostKind, now); !ok {
		t.Fatal("a new token was refused")
	}
	if ok, _ := st.useToken(secret, hostKind, now); ok {
		t.Fatal("a token worked twice")
	}
	late, _, _ := st.newToken(hostKind, pin, time.Hour, now)
	_, lateSecret, _, _ := parseToken(late)
	if ok, _ := st.useToken(lateSecret, hostKind, now.Add(time.Hour)); ok {
		t.Fatal("an expired token worked")
	}
	for _, junk := range []string{"", "pj1.", "pj1.abc.def", "xx1." + strings.Repeat("A", 43) + "." + strings.Repeat("A", 43)} {
		if _, _, _, err := parseToken(junk); err == nil {
			t.Errorf("parsed %q", junk)
		}
	}
}

func TestStateKeepsOnlyTokenHashesAndIsPrivate(t *testing.T) {
	dir := t.TempDir()
	st, _ := openState(dir)
	token, _, err := st.newToken(hostKind, bytes.Repeat([]byte{1}, 32), time.Hour, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	secret := strings.Split(strings.TrimPrefix(token, hostKind.tokenPrefix()), ".")[0]
	data, _ := os.ReadFile(filepath.Join(dir, "state.json"))
	if bytes.Contains(data, []byte(secret)) {
		t.Fatal("state.json holds the token's secret")
	}
	info, _ := os.Stat(filepath.Join(dir, "state.json"))
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("state.json mode %v", info.Mode().Perm())
	}
}

func TestAuthorityPinSurvivesARestartAndSignsTheServerCertificate(t *testing.T) {
	dir := t.TempDir()
	first, err := loadOrCreateAuthority(dir)
	if err != nil {
		t.Fatal(err)
	}
	second, err := loadOrCreateAuthority(dir)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(first.pin(), second.pin()) {
		t.Fatal("the CA changed across a restart")
	}
	for _, name := range []string{"ca.key", "ca.crt"} {
		if info, _ := os.Stat(filepath.Join(dir, name)); info.Mode().Perm() != 0o600 {
			t.Errorf("%s mode %v", name, info.Mode().Perm())
		}
	}
	cert, err := second.serverCertificate(currentReach([]string{"studio.tail1234.ts.net", "100.64.0.7"}))
	if err != nil {
		t.Fatal(err)
	}
	pool := x509.NewCertPool()
	pool.AddCert(first.cert)
	for _, name := range []string{"localhost", "studio.tail1234.ts.net", "100.64.0.7", "127.0.0.1"} {
		if _, err := cert.Leaf.Verify(x509.VerifyOptions{Roots: pool, DNSName: name}); err != nil {
			t.Errorf("%s: %v", name, err)
		}
	}
	if _, err := cert.Leaf.Verify(x509.VerifyOptions{Roots: pool, DNSName: "example.com"}); err == nil {
		t.Error("the certificate covers a name it wasn't given")
	}
}

func TestEnrollNeedsAValidUnusedToken(t *testing.T) {
	c := newTestControl(t)
	_, publicKey := newHostKey(t)
	token := c.token(t)
	if status, _ := c.enroll(t, "pj1.nope", "studio", publicKey); status != http.StatusUnauthorized {
		t.Fatalf("malformed token: %d", status)
	}
	status, response := c.enroll(t, token, "studio", publicKey)
	if status != http.StatusOK || !strings.HasPrefix(response.Host, "host-") {
		t.Fatalf("valid token: %d %+v", status, response)
	}
	if status, _ := c.enroll(t, token, "studio", publicKey); status != http.StatusUnauthorized {
		t.Fatalf("reused token: %d", status)
	}
	rsaLike := []byte("not a key")
	if status, _ := c.enroll(t, c.token(t), "studio", rsaLike); status != http.StatusBadRequest {
		t.Fatalf("bad key: %d", status)
	}
}

// A caller that loops on bad tokens can neither lock others out nor fill the disk with refusals.
func TestManyRefusalsDontStopEnrollmentAndOnlyAFewAreRecorded(t *testing.T) {
	c := newTestControl(t)
	_, publicKey := newHostKey(t)
	for i := 0; i < refusalRecordLimit+5; i++ {
		c.enroll(t, "pj1.wrong", "studio", publicKey)
	}
	if status, _ := c.enroll(t, c.token(t), "studio", publicKey); status != http.StatusOK {
		t.Fatalf("after %d refusals: %d", refusalRecordLimit+5, status)
	}
	audited, _ := os.ReadFile(filepath.Join(c.dir, "audit.log"))
	if n := strings.Count(string(audited), `"event":"enroll-refused"`); n != refusalRecordLimit {
		t.Fatalf("%d refusals recorded, not %d", n, refusalRecordLimit)
	}
}

func TestALinkReadsOnlySmallMessagesUntilItAuthenticates(t *testing.T) {
	c := newTestControl(t)
	key, publicKey := newHostKey(t)
	_, enrolled := c.enroll(t, c.token(t), "studio", publicKey)
	if _, _, err := c.link(t, strings.Repeat("h", authMessageLimit), key); websocket.CloseStatus(err) != websocket.StatusMessageTooBig {
		t.Fatalf("a large auth message: %v", err)
	}
	conn, _, err := c.link(t, enrolled.Host, key)
	if err != nil {
		t.Fatal(err)
	}
	reason := strings.Repeat("x", 2*authMessageLimit)
	wsjson.Write(context.Background(), conn, message{Type: "capacity", Slots: []slot{{Number: 1, State: "empty", Reason: reason}}})
	c.waitFor(t, "a large report once linked", func(list []hostStatus) bool {
		return len(list) == 1 && len(list[0].Slots) == 1 && list[0].Slots[0].Reason == reason
	})
}

func TestOneAddressCantHoldUpAnothersLinks(t *testing.T) {
	s := newServer(nil, nil, nil)
	for i := 0; i < pendingPerAddress; i++ {
		if !s.startPending("192.0.2.1") {
			t.Fatalf("link %d refused", i+1)
		}
	}
	if s.startPending("192.0.2.1") {
		t.Fatal("one address got more than its share")
	}
	if !s.startPending("192.0.2.2") {
		t.Fatal("another address was held up")
	}
	s.endPending("192.0.2.1")
	if !s.startPending("192.0.2.1") {
		t.Fatal("a link done authenticating still counts")
	}
}

func TestLinkAuthenticatesTheEnrolledKeyAndKeepsWhatTheHostReports(t *testing.T) {
	c := newTestControl(t)
	key, publicKey := newHostKey(t)
	_, enrolled := c.enroll(t, c.token(t), "studio", publicKey)
	conn, welcome, err := c.link(t, enrolled.Host, key)
	if err != nil || welcome.Type != "welcome" || welcome.Host != enrolled.Host {
		t.Fatalf("welcome %+v, %v", welcome, err)
	}
	ctx := context.Background()
	wsjson.Write(ctx, conn, message{Type: "hello", Name: "studio", Version: "0.1.0", MacOS: "27.2.1", Image: "build26", CPUs: 14, Memory: 36 << 30})
	wsjson.Write(ctx, conn, message{Type: "capacity", DiskFree: 500 << 30, Slots: []slot{{Number: 1, State: "warm", VM: "build26-slot1"}, {Number: 2, State: "assigned"}}})
	c.waitFor(t, "the host's report", func(list []hostStatus) bool {
		return len(list) == 1 && list[0].Online && list[0].Image == "build26" && len(list[0].Slots) == 2 &&
			list[0].CPUs == 14 && list[0].Memory == 36<<30 && list[0].DiskFree == 500<<30
	})
	if got := slotSummary(c.srv.status()[0].Slots); got != "1 warm, 1 assigned" {
		t.Errorf("slot summary %q", got)
	}
	conn.Close(websocket.StatusNormalClosure, "")
	c.waitFor(t, "the host to go offline", func(list []hostStatus) bool { return len(list) == 1 && !list[0].Online })
}

func TestStateKeepsWhenEachMemberWasLastSeen(t *testing.T) {
	dir := t.TempDir()
	st, _ := openState(dir)
	_, publicKey := newHostKey(t)
	t0 := time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC)
	member, err := st.enroll(hostKind, "studio", publicKey, t0)
	if err != nil {
		t.Fatal(err)
	}
	st.seen(hostKind, member.ID, t0)
	st.seen(hostKind, member.ID, t0.Add(30*time.Second)) // within the minute: not saved again
	if got := st.member(hostKind, member.ID).LastSeen; !got.Equal(t0) {
		t.Fatalf("last seen %v", got)
	}
	st.seen(hostKind, member.ID, t0.Add(2*time.Minute))
	reopened, _ := openState(dir)
	if got := reopened.member(hostKind, member.ID).LastSeen; !got.Equal(t0.Add(2 * time.Minute)) {
		t.Fatalf("last seen after a restart %v", got)
	}
}

func TestHostsMarksOneThatNeverLinkedOrWentQuiet(t *testing.T) {
	c := newTestControl(t)
	key, publicKey := newHostKey(t)
	_, enrolled := c.enroll(t, c.token(t), "studio", publicKey)
	if host := c.srv.status()[0]; !host.Stale || !host.LastSeen.IsZero() {
		t.Fatalf("a host that never linked: %+v", host)
	}
	conn, _, err := c.link(t, enrolled.Host, key)
	if err != nil {
		t.Fatal(err)
	}
	c.waitFor(t, "the host online", func(list []hostStatus) bool { return list[0].Online && !list[0].Stale })
	conn.Close(websocket.StatusNormalClosure, "")
	c.waitFor(t, "the host to go offline", func(list []hostStatus) bool { return !list[0].Online })
	if host := c.srv.status()[0]; host.Stale || host.LastSeen.IsZero() {
		t.Fatalf("a host offline a moment: %+v", host)
	}
	c.srv.now = func() time.Time { return time.Now().Add(staleDays*24*time.Hour + time.Hour) }
	if host := c.srv.status()[0]; !host.Stale {
		t.Fatalf("a host offline over %d days: %+v", staleDays, host)
	}
}

func TestLinkRefusesAnotherKeyOrAnUnknownHost(t *testing.T) {
	c := newTestControl(t)
	_, publicKey := newHostKey(t)
	_, enrolled := c.enroll(t, c.token(t), "studio", publicKey)
	impostor, _ := newHostKey(t)
	if _, _, err := c.link(t, enrolled.Host, impostor); websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("another key: %v", err)
	}
	if _, _, err := c.link(t, "host-0000000000000000", impostor); websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("unknown host: %v", err)
	}
	if c.srv.status()[0].Online {
		t.Fatal("a refused link counts as online")
	}
}

func TestRemovingAHostClosesItsLinkForGood(t *testing.T) {
	c := newTestControl(t)
	key, publicKey := newHostKey(t)
	_, enrolled := c.enroll(t, c.token(t), "studio", publicKey)
	conn, _, err := c.link(t, enrolled.Host, key)
	if err != nil {
		t.Fatal(err)
	}
	if response := c.srv.admin(adminRequest{Op: "remove-host", Host: "studio"}, nil); response.Removed != enrolled.Host {
		t.Fatalf("remove: %+v", response)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var m message
	if err := wsjson.Read(ctx, conn, &m); websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("the removed host's link: %v", err)
	}
	if _, _, err := c.link(t, enrolled.Host, key); websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("a removed host linked again: %v", err)
	}
}

func TestANewLinkFromTheSameHostReplacesTheOld(t *testing.T) {
	c := newTestControl(t)
	key, publicKey := newHostKey(t)
	_, enrolled := c.enroll(t, c.token(t), "studio", publicKey)
	old, _, err := c.link(t, enrolled.Host, key)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := c.link(t, enrolled.Host, key); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var m message
	if err := wsjson.Read(ctx, old, &m); websocket.CloseStatus(err) != websocket.StatusGoingAway {
		t.Fatalf("the old link: %v", err)
	}
	c.waitFor(t, "the new link to stay", func(list []hostStatus) bool { return len(list) == 1 && list[0].Online })
}

func TestAdminSocketMakesTokensAndListsHosts(t *testing.T) {
	// Unix socket paths are short, so not t.TempDir() on macOS.
	dir, err := os.MkdirTemp("/tmp", "pc")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	authority, _ := loadOrCreateAuthority(dir)
	st, _ := openState(dir)
	audit, _ := openAuditLog(filepath.Join(dir, "audit.log"))
	defer audit.close()
	srv := newServer(st, authority, audit)
	listener, err := srv.listenAdmin(adminSocketPath(dir), func() []string { return []string{"https://studio.local:7443"} })
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if info, _ := os.Stat(adminSocketPath(dir)); info.Mode().Perm() != 0o600 {
		t.Fatalf("admin socket mode %v", info.Mode().Perm())
	}
	response, err := askAdmin(dir, adminRequest{Op: "join-token"})
	if err != nil || !strings.HasPrefix(response.Token, hostKind.tokenPrefix()) || response.URLs[0] != "https://studio.local:7443" {
		t.Fatalf("join-token: %+v, %v", response, err)
	}
	if _, _, pin, _ := parseToken(response.Token); !bytes.Equal(pin, authority.pin()) {
		t.Fatal("the token doesn't carry this CA's pin")
	}
	if _, err := askAdmin(dir, adminRequest{Op: "join-token", TTL: 48 * time.Hour}); err == nil {
		t.Fatal("a 48-hour token was made")
	}
	if _, err := askAdmin(dir, adminRequest{Op: "remove-host", Host: "nobody"}); err == nil {
		t.Fatal("removed a host that doesn't exist")
	}
	audited, _ := os.ReadFile(filepath.Join(dir, "audit.log"))
	if !bytes.Contains(audited, []byte(`"event":"join-token-made"`)) || bytes.Contains(audited, []byte(response.Token)) {
		t.Fatalf("audit log: %s", audited)
	}
}

func TestURLsShowNamesAndIPv4ButNotEveryIPv6(t *testing.T) {
	r := reach{
		names:     []string{"studio.local", "localhost", "studio.tail1234.ts.net"},
		addresses: []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("10.0.0.5"), net.ParseIP("2601:645::1"), net.ParseIP("100.64.0.7")},
	}
	got := strings.Join(urlsFor(r, "7443"), " ")
	want := "https://studio.local:7443 https://studio.tail1234.ts.net:7443 https://10.0.0.5:7443 https://100.64.0.7:7443"
	if got != want {
		t.Errorf("got %s", got)
	}
	if got := urlsFor(reach{names: []string{"localhost"}, addresses: []net.IP{net.ParseIP("2601:645::1")}}, "7443"); len(got) != 1 || got[0] != "https://[2601:645::1]:7443" {
		t.Errorf("IPv6 only: %v", got)
	}
}

func TestCloseReasonsReadPlainly(t *testing.T) {
	if got := closeReason(fmt.Errorf("failed to read frame header: %w", io.EOF)); got != "closed without a goodbye" {
		t.Errorf("EOF: %q", got)
	}
}
