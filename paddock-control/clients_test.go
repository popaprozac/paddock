package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

func (c *testControl) loginToken(t *testing.T) string {
	t.Helper()
	token, _, err := c.srv.state.newToken(clientKind, c.srv.authority.pin(), time.Hour, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return token
}

func (c *testControl) enrollAs(t *testing.T, as kind, token string, publicKey []byte) (int, enrollResponse) {
	t.Helper()
	body, _ := json.Marshal(enrollRequest{Token: token, Name: "zach on studio", PublicKey: publicKey, As: as})
	response, err := c.client.Post(c.url+"/v1/enroll", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	var decoded enrollResponse
	_ = json.NewDecoder(response.Body).Decode(&decoded)
	return response.StatusCode, decoded
}

// clientLinkAs opens a client link and answers its challenge as id, signing with key over context.
func (c *testControl) clientLinkAs(t *testing.T, id string, key *ecdsa.PrivateKey, context string) (*websocket.Conn, message, error) {
	t.Helper()
	ctx, cancel := contextWithTimeout()
	defer cancel()
	conn, _, err := websocket.Dial(ctx, strings.Replace(c.url, "https", "wss", 1)+"/v1/client",
		&websocket.DialOptions{HTTPClient: c.client})
	if err != nil {
		t.Fatal(err)
	}
	var challenge message
	if err := wsjson.Read(ctx, conn, &challenge); err != nil || challenge.Type != "challenge" {
		t.Fatalf("challenge %+v, %v", challenge, err)
	}
	digest := sha256.Sum256(append([]byte(context), challenge.Nonce...))
	signature, _ := ecdsa.SignASN1(rand.Reader, key, digest[:])
	wsjson.Write(ctx, conn, message{Type: "auth", Client: id, Signature: signature})
	var welcome message
	err = wsjson.Read(ctx, conn, &welcome)
	return conn, welcome, err
}

func contextWithTimeout() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), 5*time.Second)
}

func TestEachTokenEnrollsOnlyItsKindAndIsKeptWhenMisused(t *testing.T) {
	c := newTestControl(t)
	_, publicKey := newHostKey(t)
	login, join := c.loginToken(t), c.token(t)
	if !strings.HasPrefix(login, "pl1.") || !strings.HasPrefix(join, "pj1.") {
		t.Fatalf("prefixes: %q %q", login[:4], join[:4])
	}
	status, response := c.enrollAs(t, hostKind, login, publicKey)
	if status != http.StatusBadRequest || !strings.Contains(response.Error, "paddock login") {
		t.Fatalf("a login token as a host: %d %+v", status, response)
	}
	status, response = c.enrollAs(t, clientKind, join, publicKey)
	if status != http.StatusBadRequest || !strings.Contains(response.Error, "join token") {
		t.Fatalf("a join token as a client: %d %+v", status, response)
	}
	if status, response := c.enrollAs(t, clientKind, login, publicKey); status != http.StatusOK || !strings.HasPrefix(response.Client, "client-") {
		t.Fatalf("the login token, kept, as a client: %d %+v", status, response)
	}
	if status, response := c.enrollAs(t, hostKind, join, publicKey); status != http.StatusOK || !strings.HasPrefix(response.Host, "host-") {
		t.Fatalf("the join token, kept, as a host: %d %+v", status, response)
	}
}

func TestAClientLinkAnswersHostsWithThePool(t *testing.T) {
	c := newTestControl(t)
	hostKey, hostPublic := newHostKey(t)
	_, host := c.enroll(t, c.token(t), "studio", hostPublic)
	hostConn, _, err := c.link(t, host.Host, hostKey)
	if err != nil {
		t.Fatal(err)
	}
	defer hostConn.CloseNow()
	wsjson.Write(context.Background(), hostConn, message{Type: "hello", Image: "golden"})
	c.waitFor(t, "the host's hello", func(list []hostStatus) bool { return len(list) == 1 && list[0].Image == "golden" })

	key, publicKey := newHostKey(t)
	_, client := c.enrollAs(t, clientKind, c.loginToken(t), publicKey)
	conn, welcome, err := c.clientLinkAs(t, client.Client, key, clientContext)
	if err != nil || welcome.Type != "welcome" || welcome.Client != client.Client {
		t.Fatalf("welcome %+v, %v", welcome, err)
	}
	defer conn.CloseNow()
	ctx, cancel := contextWithTimeout()
	defer cancel()
	wsjson.Write(ctx, conn, message{Type: "request", ID: "1", Op: "hosts"})
	var reply message
	if err := wsjson.Read(ctx, conn, &reply); err != nil {
		t.Fatal(err)
	}
	if reply.ID != "1" || !reply.Done || len(reply.Hosts) != 1 || !reply.Hosts[0].Online || reply.Hosts[0].Image != "golden" {
		t.Fatalf("hosts reply %+v", reply)
	}
	wsjson.Write(ctx, conn, message{Type: "request", ID: "2", Op: "rm -rf"})
	if err := wsjson.Read(ctx, conn, &reply); err != nil || reply.ID != "2" || !strings.Contains(reply.Error, "unknown request") {
		t.Fatalf("unknown request: %+v, %v", reply, err)
	}
	if list := c.srv.clientStatus(); len(list) != 1 || list[0].Links != 1 {
		t.Fatalf("clients: %+v", list)
	}
}

func TestAClientLinkTakesOnlyAClientsKeyAndContext(t *testing.T) {
	c := newTestControl(t)
	hostKey, hostPublic := newHostKey(t)
	_, host := c.enroll(t, c.token(t), "studio", hostPublic)
	key, publicKey := newHostKey(t)
	_, client := c.enrollAs(t, clientKind, c.loginToken(t), publicKey)
	impostor, _ := newHostKey(t)
	for name, try := range map[string]func() error{
		"another key":              func() error { _, _, err := c.clientLinkAs(t, client.Client, impostor, clientContext); return err },
		"a host's ID and key":      func() error { _, _, err := c.clientLinkAs(t, host.Host, hostKey, clientContext); return err },
		"a host's signing context": func() error { _, _, err := c.clientLinkAs(t, client.Client, key, linkContext); return err },
	} {
		if err := try(); websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
			t.Errorf("%s: %v", name, err)
		}
	}
}

func TestLogoutRemovesTheClient(t *testing.T) {
	c := newTestControl(t)
	key, publicKey := newHostKey(t)
	_, client := c.enrollAs(t, clientKind, c.loginToken(t), publicKey)
	conn, _, err := c.clientLinkAs(t, client.Client, key, clientContext)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := contextWithTimeout()
	defer cancel()
	wsjson.Write(ctx, conn, message{Type: "request", ID: "1", Op: "logout"})
	var reply message
	if err := wsjson.Read(ctx, conn, &reply); err != nil || !reply.Done || reply.Error != "" {
		t.Fatalf("logout reply %+v, %v", reply, err)
	}
	if err := wsjson.Read(ctx, conn, &reply); websocket.CloseStatus(err) != websocket.StatusNormalClosure {
		t.Fatalf("after logout: %v", err)
	}
	if list := c.srv.state.list(clientKind); len(list) != 0 {
		t.Fatalf("still enrolled: %+v", list)
	}
	if _, _, err := c.clientLinkAs(t, client.Client, key, clientContext); websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("linked after logout: %v", err)
	}
}

func TestRemovingAClientClosesAllItsLinks(t *testing.T) {
	c := newTestControl(t)
	key, publicKey := newHostKey(t)
	_, client := c.enrollAs(t, clientKind, c.loginToken(t), publicKey)
	first, _, _ := c.clientLinkAs(t, client.Client, key, clientContext)
	second, _, _ := c.clientLinkAs(t, client.Client, key, clientContext)
	if response := c.srv.admin(adminRequest{Op: "remove-client", Host: "zach on studio"}, nil); response.Removed != client.Client {
		t.Fatalf("remove: %+v", response)
	}
	ctx, cancel := contextWithTimeout()
	defer cancel()
	for _, conn := range []*websocket.Conn{first, second} {
		var m message
		if err := wsjson.Read(ctx, conn, &m); websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
			t.Errorf("a removed client's link: %v", err)
		}
	}
}
