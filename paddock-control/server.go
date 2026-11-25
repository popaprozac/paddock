package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

// What a host or client signs, ahead of the control plane's fresh random bytes, so the signature
// can't be taken for one made for anything else, or a host's for a client's.
const (
	linkContext   = "paddock-link-v1:"
	clientContext = "paddock-client-v1:"
)

const (
	enrollBodyLimit    = 16 << 10
	authMessageLimit   = 4 << 10 // until a link authenticates; its auth message is under 200 bytes
	linkMessageLimit   = 1 << 20
	authTimeout        = 10 * time.Second
	pingInterval       = 30 * time.Second // on clients' links
	hostSilence        = 90 * time.Second // a Mac reports its usage every 2 s, and its slots every 60 s
	pendingPerAddress  = 16
	refusalWindow      = time.Minute
	refusalRecordLimit = 10
	defaultTokenTTL    = time.Hour
	maxTokenTTL        = 24 * time.Hour
)

// message is every message on a host's or client's link, as one JSON object; which fields it has
// depends on its type.
type message struct {
	Type      string    `json:"type"`                // challenge, auth, welcome, hello, capacity, usage, lapsed, request, upload, cancel, response
	Nonce     []byte    `json:"nonce,omitempty"`     // challenge: 32 random bytes
	Host      string    `json:"host,omitempty"`      // a host's auth and welcome: its ID
	Client    string    `json:"client,omitempty"`    // a client's auth and welcome: its ID
	Signature []byte    `json:"signature,omitempty"` // auth: ECDSA over SHA-256 of the context + nonce, DER
	Name      string    `json:"name,omitempty"`      // hello: the host's name for people
	Version   string    `json:"version,omitempty"`   // hello: paddock's version on the host
	MacOS     string    `json:"macos,omitempty"`     // hello: the host's macOS version
	Image     string    `json:"image,omitempty"`     // hello: the golden image serve hands out clones of
	CPUs      int       `json:"cpus,omitempty"`      // hello: the host's cores
	Memory    uint64    `json:"memory,omitempty"`    // hello: the host's memory, in bytes
	DiskFree  uint64    `json:"diskFree,omitempty"`  // capacity: free space for VMs, in bytes
	Slots     []slot    `json:"slots,omitempty"`     // capacity and usage: every slot on the host
	Usage     *macUsage `json:"usage,omitempty"`     // usage: what the host uses now, sent every 2 s
	VM        string    `json:"vm,omitempty"`        // lapsed: the VM the host wiped, with why in Error

	ID      string       `json:"id,omitempty"`      // request and response: pairs them on one link
	Serve   string       `json:"serve,omitempty"`   // request to a host: one of serve's request lines
	Line    string       `json:"line,omitempty"`    // response from a host: one of serve's answer lines
	Data    []byte       `json:"data,omitempty"`    // response: a piece of a file, such as a screenshot, in order
	Note    string       `json:"note,omitempty"`    // response: news for the person waiting, such as no free VM
	Op      string       `json:"op,omitempty"`      // request: hosts or logout
	Hosts   []hostStatus `json:"hosts,omitempty"`   // response to hosts
	Waiting *int         `json:"waiting,omitempty"` // response to hosts: acquires waiting for a warm VM
	Error   string       `json:"error,omitempty"`   // response: why the request failed
	Done    bool         `json:"done,omitempty"`    // response: the request's last answer
}

// slot is one of serve's slots as its host reports it.
type slot struct {
	Number int      `json:"number"`
	State  string   `json:"state"`            // warm, assigned, preparing or empty
	VM     string   `json:"vm,omitempty"`     // the VM in it, if any
	Reason string   `json:"reason,omitempty"` // empty: why
	Age    int      `json:"age,omitempty"`    // usage: seconds the slot has been in this state
	Usage  *vmUsage `json:"usage,omitempty"`  // usage: what its VM costs the host
	Holder string   `json:"holder,omitempty"` // status: the client the control plane handed its VM to
}

// macUsage is what a host uses, measured on the host, as serve reports it every 2 s.
type macUsage struct {
	CPU         *float64 `json:"cpu,omitempty"` // percent of the whole Mac
	MemoryUsed  uint64   `json:"memoryUsed"`
	MemoryTotal uint64   `json:"memoryTotal"`
	Pressure    string   `json:"pressure"` // normal, warn or critical
	Thermal     string   `json:"thermal"`  // nominal, fair, serious or critical
	DiskFree    *uint64  `json:"diskFree,omitempty"`
}

// vmUsage is what one VM's process costs its host.
type vmUsage struct {
	CPU    *float64 `json:"cpu,omitempty"` // percent of one core
	Memory uint64   `json:"memory"`        // memory footprint, in bytes
}

// link is an authenticated host's open connection.
type link struct {
	conn      *websocket.Conn
	remote    string
	connected time.Time
	mu        sync.Mutex
	lastSeen  time.Time
	hello     message
	slots     []slot
	diskFree  uint64
	nextID    int
	pending   map[string]*pendingRequest // requests forwarded to the host, by ID, until done
	closed    bool
	busy      bool // answered an acquire busy: offered none until its next report
	usage     *macUsage
	slotUsage []slot // the slots as the last usage report had them, for their age and usage
}

// server is the control plane: enrollment and host links over HTTPS.
type server struct {
	state     *state
	authority *authority
	audit     *auditLog
	now       func() time.Time
	silence   time.Duration // how long a Mac may say nothing before its link is closed

	mu          sync.Mutex
	links       map[string]*link // by host ID, for hosts online now
	clientLinks map[string]map[*clientLink]bool
	waiters     []*waiter      // acquires waiting for a warm slot, oldest first
	reserved    map[string]int // by host: warm slots acquires on their way are counting on
	pending     map[string]int // links not yet authenticated, by remote address
	stopping    bool           // closeAll has run
	refusals    []time.Time    // refusals recorded in the last refusalWindow
	lapses      []lapse        // the last VMs their Macs wiped for going unused, oldest first

	maxIdle time.Duration // the longest an acquire may let its VM go unused
}

func newServer(st *state, authority *authority, audit *auditLog) *server {
	return &server{state: st, authority: authority, audit: audit, now: time.Now, silence: hostSilence, links: map[string]*link{},
		clientLinks: map[string]map[*clientLink]bool{}, reserved: map[string]int{}, pending: map[string]int{}, maxIdle: defaultMaxIdle}
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/enroll", s.enroll)
	mux.HandleFunc("GET /v1/link", s.link)
	mux.HandleFunc("GET /v1/client", s.clientLink)
	return mux
}

type enrollRequest struct {
	Token     string `json:"token"`
	Name      string `json:"name"`
	PublicKey []byte `json:"publicKey"`    // PKIX DER of the P-256 key
	As        kind   `json:"as,omitempty"` // host or client: what the caller means to be; host if left out
}

type enrollResponse struct {
	Host   string `json:"host,omitempty"`
	Client string `json:"client,omitempty"`
	Error  string `json:"error,omitempty"`
}

// enroll trades a token for an ID under the caller's public key: a join token makes a host, a
// login token a client. Every refusal of a token looks the same to the caller. A token of the
// other kind is kept, with what to do instead.
func (s *server) enroll(w http.ResponseWriter, r *http.Request) {
	var request enrollRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, enrollBodyLimit)).Decode(&request); err != nil {
		writeJSON(w, http.StatusBadRequest, enrollResponse{Error: "the request isn't JSON"})
		return
	}
	wanted := request.As
	if wanted == "" {
		wanted = hostKind
	}
	if wanted != hostKind && wanted != clientKind {
		writeJSON(w, http.StatusBadRequest, enrollResponse{Error: `"as" is host or client`})
		return
	}
	// Before the token, so a refusal records a name of at most 64 characters.
	if err := validateName(request.Name); err != nil {
		writeJSON(w, http.StatusBadRequest, enrollResponse{Error: err.Error()})
		return
	}
	command := map[kind]string{hostKind: "paddock-control join-token", clientKind: "paddock-control login-token"}[wanted]
	refuse := func(reason string) {
		s.recordRefusal(auditEvent{Event: "enroll-refused", Name: request.Name, Remote: r.RemoteAddr, Reason: reason})
		writeJSON(w, http.StatusUnauthorized, enrollResponse{Error: "the token isn't valid, or was used or expired: make a new one with '" + command + "'"})
	}
	tokenKind, secret, _, err := parseToken(request.Token)
	if err != nil {
		refuse("malformed token")
		return
	}
	if tokenKind != wanted {
		writeJSON(w, http.StatusBadRequest, enrollResponse{Error: wrongKind(tokenKind)})
		return
	}
	if _, err := parseMemberKey(request.PublicKey); err != nil {
		writeJSON(w, http.StatusBadRequest, enrollResponse{Error: err.Error()})
		return
	}
	ok, err := s.state.useToken(secret, wanted, s.now())
	if errors.Is(err, errWrongKind) {
		writeJSON(w, http.StatusBadRequest, enrollResponse{Error: wrongKind(otherKind(wanted))})
		return
	}
	if err != nil {
		log.Printf("can't save state: %v", err)
		writeJSON(w, http.StatusInternalServerError, enrollResponse{Error: "the control plane can't save its state"})
		return
	}
	if !ok {
		refuse("unknown, used or expired token")
		return
	}
	member, err := s.state.enroll(wanted, request.Name, request.PublicKey, s.now())
	if err != nil {
		log.Printf("can't enroll %q: %v", request.Name, err)
		writeJSON(w, http.StatusInternalServerError, enrollResponse{Error: "the control plane can't save its state"})
		return
	}
	if wanted == clientKind {
		s.audit.record(auditEvent{Event: "client-enrolled", Client: member.ID, Name: member.Name, Remote: r.RemoteAddr})
		log.Printf("enrolled client %s (%s) from %s", member.Name, member.ID, r.RemoteAddr)
		writeJSON(w, http.StatusOK, enrollResponse{Client: member.ID})
		return
	}
	s.audit.record(auditEvent{Event: "enrolled", Host: member.ID, Name: member.Name, Remote: r.RemoteAddr})
	log.Printf("enrolled %s (%s) from %s", member.Name, member.ID, r.RemoteAddr)
	writeJSON(w, http.StatusOK, enrollResponse{Host: member.ID})
}

// wrongKind says what a token of kind k is for, to someone who used it for the other.
func wrongKind(k kind) string {
	if k == clientKind {
		return "that's a login token, for a person's CLI or an agent: use it with 'paddock login'; a Mac joins with a token from 'paddock-control join-token'"
	}
	return "that's a join token, for adding a Mac with 'paddock serve --join'; to log in, use a token from 'paddock-control login-token'"
}

func otherKind(k kind) kind {
	if k == hostKind {
		return clientKind
	}
	return hostKind
}

// recordRefusal records a refused enrollment or link in the audit log, unless refusalRecordLimit
// already were in the last refusalWindow: a caller that loops on refusals can't fill the disk, and
// is refused all the same.
func (s *server) recordRefusal(event auditEvent) {
	s.mu.Lock()
	cutoff := s.now().Add(-refusalWindow)
	kept := s.refusals[:0]
	for _, t := range s.refusals {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	record := len(kept) < refusalRecordLimit
	if record {
		kept = append(kept, s.now())
	}
	s.refusals = kept
	s.mu.Unlock()
	if record {
		s.audit.record(event)
	}
}

// link takes a host's WebSocket, has it prove it holds its enrolled key by signing fresh random
// bytes, then keeps what it reports until the link closes. One link per host: a new one replaces
// the old.
func (s *server) link(w http.ResponseWriter, r *http.Request) {
	address := addressOf(r)
	if !s.startPending(address) {
		http.Error(w, "too many links from this address waiting to authenticate", http.StatusServiceUnavailable)
		return
	}
	conn, err := websocket.Accept(w, r, nil)
	if err != nil {
		s.endPending(address)
		return
	}
	host, err := s.authenticate(r.Context(), conn, hostKind)
	s.endPending(address)
	if err != nil {
		s.recordRefusal(auditEvent{Event: "link-refused", Host: host, Remote: r.RemoteAddr, Reason: err.Error()})
		conn.Close(websocket.StatusPolicyViolation, "not an enrolled host")
		return
	}
	// Welcome before any request can be forwarded: serve reads anything else first as a refusal.
	if err := wsjson.Write(r.Context(), conn, message{Type: "welcome", Host: host}); err != nil {
		return
	}
	l := &link{conn: conn, remote: r.RemoteAddr, connected: s.now(), lastSeen: s.now()}
	defer l.failPending() // registered, it may be sent requests, which must end with it
	if previous := s.register(host, l); previous != nil {
		// Close waits for the other end's answer, so not on this link's way in.
		go previous.conn.Close(websocket.StatusGoingAway, "replaced by a newer link from the same host")
	}
	// After registering: a removal before then found no link to close.
	enrolled := s.state.member(hostKind, host)
	if enrolled == nil {
		s.unregister(host, l, "removed from the control plane")
		conn.Close(websocket.StatusPolicyViolation, "this host was removed from the control plane")
		return
	}
	s.markSeen(hostKind, host)
	s.audit.record(auditEvent{Event: "link-opened", Host: host, Name: enrolled.Name, Remote: r.RemoteAddr})
	log.Printf("%s (%s) connected from %s", enrolled.Name, host, r.RemoteAddr)

	for {
		// A deadline, not a ping: a ping's answer is only read here, and this loop waits while a
		// client is slow to take its answers, so a ping would close the link for every client.
		var m message
		ctx, cancel := context.WithTimeout(r.Context(), s.silence)
		err := wsjson.Read(ctx, conn, &m)
		cancel()
		if errors.Is(err, context.DeadlineExceeded) {
			s.unregister(host, l, "nothing from the Mac for "+s.silence.String())
			return
		}
		if err != nil {
			s.unregister(host, l, closeReason(err))
			return
		}
		l.mu.Lock()
		l.lastSeen = s.now()
		switch m.Type {
		case "hello":
			l.hello = m
		case "capacity":
			l.slots, l.diskFree, l.busy = m.Slots, m.DiskFree, false
		case "usage":
			// Usage changes every report, so it never moves the queue: only capacity does.
			l.usage, l.slotUsage = m.Usage, m.Slots
		}
		l.mu.Unlock()
		switch m.Type {
		case "response":
			l.deliver(m)
		case "capacity":
			s.forgetMissing(host, m.Slots)
			s.poolChanged()
		case "lapsed":
			s.forgetLapsed(host, m.VM, m.Error)
		case "hello":
			s.poolChanged()
		}
	}
}

// authenticate sends a challenge and checks the host's or client's signature over it; it returns
// the ID, also on failure when the caller named one. Until then the link reads small messages only.
func (s *server) authenticate(ctx context.Context, conn *websocket.Conn, k kind) (string, error) {
	conn.SetReadLimit(authMessageLimit)
	ctx, cancel := context.WithTimeout(ctx, authTimeout)
	defer cancel()
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	if err := wsjson.Write(ctx, conn, message{Type: "challenge", Nonce: nonce}); err != nil {
		return "", err
	}
	var answer message
	if err := wsjson.Read(ctx, conn, &answer); err != nil {
		return "", err
	}
	id, context := answer.Host, linkContext
	if k == clientKind {
		id, context = answer.Client, clientContext
	}
	if answer.Type != "auth" || id == "" {
		return id, errors.New("no auth message")
	}
	member := s.state.member(k, id)
	if member == nil {
		return id, fmt.Errorf("unknown or removed %s", k)
	}
	key, err := parseMemberKey(member.PublicKey)
	if err != nil {
		return id, err
	}
	digest := sha256.Sum256(append([]byte(context), nonce...))
	if !ecdsa.VerifyASN1(key, digest[:], answer.Signature) {
		return id, errors.New("bad signature")
	}
	conn.SetReadLimit(linkMessageLimit)
	return id, nil
}

func (s *server) keepAlive(ctx context.Context, conn *websocket.Conn) {
	ticker := time.NewTicker(pingInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			pingCtx, cancel := context.WithTimeout(ctx, authTimeout)
			err := conn.Ping(pingCtx)
			cancel()
			if err != nil {
				conn.Close(websocket.StatusGoingAway, "no answer to ping")
				return
			}
		}
	}
}

// addressOf is the address a link waiting to authenticate counts against: the caller's, without
// its port, so one caller can't hold up everyone else's links.
func addressOf(r *http.Request) string {
	if host, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
		return host
	}
	return r.RemoteAddr
}

func (s *server) startPending(address string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.pending[address] >= pendingPerAddress {
		return false
	}
	s.pending[address]++
	return true
}

func (s *server) endPending(address string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.pending[address]--; s.pending[address] == 0 {
		delete(s.pending, address)
	}
}

// register makes l the host's link and returns the one it replaces, if any.
func (s *server) register(host string, l *link) *link {
	s.mu.Lock()
	defer s.mu.Unlock()
	previous := s.links[host]
	s.links[host] = l
	s.dispatchLocked()
	return previous
}

// unregister forgets l, unless a newer link has already replaced it.
func (s *server) unregister(host string, l *link, reason string) {
	s.markSeen(hostKind, host)
	s.mu.Lock()
	current := s.links[host] == l
	if current {
		delete(s.links, host)
	}
	if s.stopping {
		reason = "the control plane is stopping"
	}
	s.dispatchLocked()
	s.mu.Unlock()
	if current {
		s.audit.record(auditEvent{Event: "link-closed", Host: host, Remote: l.remote, Reason: reason})
		log.Printf("%s disconnected: %s", host, reason)
	}
}

// disconnect closes the host's link, as when it is removed.
func (s *server) disconnect(host string) {
	s.mu.Lock()
	l := s.links[host]
	s.mu.Unlock()
	if l != nil {
		go l.conn.Close(websocket.StatusPolicyViolation, "this host was removed from the control plane")
	}
}

// markSeen keeps when a host or client was last linked, so the lists can mark the ones left behind.
func (s *server) markSeen(k kind, id string) {
	if err := s.state.seen(k, id, s.now()); err != nil {
		log.Printf("can't keep when %s was last seen: %v", id, err)
	}
}

// staleDays is how long a host or client may go without linking before the lists mark it stale,
// as one re-provisioned or given up on. One that never linked is stale at once.
const staleDays = 7

// stale says whether a host or client that isn't linked now looks left behind.
func stale(lastSeen, now time.Time) bool {
	return lastSeen.IsZero() || now.Sub(lastSeen) > staleDays*24*time.Hour
}

// hostStatus is a host as `paddock-control hosts` shows it.
type hostStatus struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Enrolled  time.Time `json:"enrolled"`
	Online    bool      `json:"online"`
	Stale     bool      `json:"stale,omitempty"` // offline, and never linked or not for staleDays
	Remote    string    `json:"remote,omitempty"`
	Connected time.Time `json:"connected,omitzero"`
	LastSeen  time.Time `json:"lastSeen,omitzero"`
	Version   string    `json:"version,omitempty"`
	MacOS     string    `json:"macos,omitempty"`
	Image     string    `json:"image,omitempty"`
	CPUs      int       `json:"cpus,omitempty"`
	Memory    uint64    `json:"memory,omitempty"`
	DiskFree  uint64    `json:"diskFree,omitempty"`
	Slots     []slot    `json:"slots,omitempty"`
	Usage     *macUsage `json:"usage,omitempty"`
}

func (s *server) status() []hostStatus {
	var list []hostStatus
	for _, host := range s.state.list(hostKind) {
		status := hostStatus{ID: host.ID, Name: host.Name, Enrolled: host.Enrolled, LastSeen: host.LastSeen}
		s.mu.Lock()
		l := s.links[host.ID]
		s.mu.Unlock()
		status.Stale = l == nil && stale(host.LastSeen, s.now())
		if l != nil {
			l.mu.Lock()
			status.Online, status.Remote, status.Connected, status.LastSeen = true, l.remote, l.connected, l.lastSeen
			status.Version, status.MacOS, status.Image = l.hello.Version, l.hello.MacOS, l.hello.Image
			status.CPUs, status.Memory, status.DiskFree, status.Usage = l.hello.CPUs, l.hello.Memory, l.diskFree, l.usage
			// A copy: the link's slots change in place when the control plane hands one out.
			status.Slots = append([]slot(nil), l.slots...)
			for i, slot := range status.Slots {
				for _, used := range l.slotUsage {
					if used.Number != slot.Number || used.VM != slot.VM {
						continue
					}
					status.Slots[i].Usage = used.Usage
					if used.State == slot.State { // just handed out, the age is the old state's
						status.Slots[i].Age = used.Age
					}
				}
			}
			l.mu.Unlock()
			for i, slot := range status.Slots {
				if slot.VM == "" {
					continue
				}
				if h := s.state.handout(slot.VM); h != nil {
					if member := s.state.member(clientKind, h.Client); member != nil {
						status.Slots[i].Holder = member.Name
					}
				}
			}
		}
		list = append(list, status)
	}
	return list
}

func closeReason(err error) string {
	if status := websocket.CloseStatus(err); status != -1 {
		return "closed: " + status.String()
	}
	if errors.Is(err, context.Canceled) {
		return "control plane stopping"
	}
	if errors.Is(err, io.EOF) {
		return "closed without a goodbye" // a CLI command that exits as soon as it's done, or a dropped network
	}
	return err.Error()
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
