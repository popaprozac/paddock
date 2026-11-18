package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

// linkContext is what a host signs, ahead of the control plane's fresh random bytes, so the
// signature can't be taken for one made for anything else.
const linkContext = "paddock-link-v1:"

const (
	enrollBodyLimit  = 16 << 10
	linkMessageLimit = 1 << 20
	authTimeout      = 10 * time.Second
	pingInterval     = 30 * time.Second
	pendingLinkLimit = 64
	enrollFailWindow = time.Minute
	enrollFailLimit  = 10
	defaultTokenTTL  = time.Hour
	maxTokenTTL      = 24 * time.Hour
)

// message is every message on a host's link, as one JSON object; which fields it has depends on
// its type.
type message struct {
	Type      string `json:"type"`                // challenge, auth, welcome, hello, capacity
	Nonce     []byte `json:"nonce,omitempty"`     // challenge: 32 random bytes
	Host      string `json:"host,omitempty"`      // auth and welcome: the host's ID
	Signature []byte `json:"signature,omitempty"` // auth: ECDSA over SHA-256 of linkContext + nonce, DER
	Name      string `json:"name,omitempty"`      // hello: the host's name for people
	Version   string `json:"version,omitempty"`   // hello: paddock's version on the host
	MacOS     string `json:"macos,omitempty"`     // hello: the host's macOS version
	Image     string `json:"image,omitempty"`     // hello: the golden image serve hands out clones of
	Slots     []slot `json:"slots,omitempty"`     // capacity: every slot on the host
}

// slot is one of serve's slots as its host reports it.
type slot struct {
	Number int    `json:"number"`
	State  string `json:"state"`            // warm, assigned, preparing or empty
	VM     string `json:"vm,omitempty"`     // the VM in it, if any
	Reason string `json:"reason,omitempty"` // empty: why
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
}

// server is the control plane: enrollment and host links over HTTPS.
type server struct {
	state     *state
	authority *authority
	audit     *auditLog
	now       func() time.Time

	mu           sync.Mutex
	links        map[string]*link // by host ID, for hosts online now
	pending      int              // links not yet authenticated
	enrollFailed []time.Time      // failed enrollments in the last enrollFailWindow
}

func newServer(st *state, authority *authority, audit *auditLog) *server {
	return &server{state: st, authority: authority, audit: audit, now: time.Now, links: map[string]*link{}}
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/enroll", s.enroll)
	mux.HandleFunc("GET /v1/link", s.link)
	return mux
}

type enrollRequest struct {
	Token     string `json:"token"`
	Name      string `json:"name"`
	PublicKey []byte `json:"publicKey"` // PKIX DER of the host's P-256 key
}

type enrollResponse struct {
	Host  string `json:"host,omitempty"`
	Error string `json:"error,omitempty"`
}

// enroll trades a join token for a host ID under the host's public key. Every refusal looks the
// same to the caller, and too many in a minute stop all enrollments for the rest of it.
func (s *server) enroll(w http.ResponseWriter, r *http.Request) {
	if !s.enrollAllowed() {
		writeJSON(w, http.StatusTooManyRequests, enrollResponse{Error: "too many failed enrollments; try again in a minute"})
		return
	}
	var request enrollRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, enrollBodyLimit)).Decode(&request); err != nil {
		writeJSON(w, http.StatusBadRequest, enrollResponse{Error: "the request isn't JSON"})
		return
	}
	refuse := func(reason string) {
		s.enrollFailure()
		s.audit.record(auditEvent{Event: "enroll-refused", Name: request.Name, Remote: r.RemoteAddr, Reason: reason})
		writeJSON(w, http.StatusUnauthorized, enrollResponse{Error: "the join token isn't valid, or was used or expired: make a new one with 'paddock-control join-token'"})
	}
	secret, _, err := parseJoinToken(request.Token)
	if err != nil {
		refuse("malformed token")
		return
	}
	if _, err := parseHostKey(request.PublicKey); err != nil {
		writeJSON(w, http.StatusBadRequest, enrollResponse{Error: err.Error()})
		return
	}
	if err := validateHostName(request.Name); err != nil {
		writeJSON(w, http.StatusBadRequest, enrollResponse{Error: err.Error()})
		return
	}
	ok, err := s.state.useJoinToken(secret, s.now())
	if err != nil {
		log.Printf("can't save state: %v", err)
		writeJSON(w, http.StatusInternalServerError, enrollResponse{Error: "the control plane can't save its state"})
		return
	}
	if !ok {
		refuse("unknown, used or expired token")
		return
	}
	host, err := s.state.enroll(request.Name, request.PublicKey, s.now())
	if err != nil {
		log.Printf("can't enroll %q: %v", request.Name, err)
		writeJSON(w, http.StatusInternalServerError, enrollResponse{Error: "the control plane can't save its state"})
		return
	}
	s.audit.record(auditEvent{Event: "enrolled", Host: host.ID, Name: host.Name, Remote: r.RemoteAddr})
	log.Printf("enrolled %s (%s) from %s", host.Name, host.ID, r.RemoteAddr)
	writeJSON(w, http.StatusOK, enrollResponse{Host: host.ID})
}

func (s *server) enrollAllowed() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	cutoff := s.now().Add(-enrollFailWindow)
	kept := s.enrollFailed[:0]
	for _, t := range s.enrollFailed {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	s.enrollFailed = kept
	return len(kept) < enrollFailLimit
}

func (s *server) enrollFailure() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.enrollFailed = append(s.enrollFailed, s.now())
}

// link takes a host's WebSocket, has it prove it holds its enrolled key by signing fresh random
// bytes, then keeps what it reports until the link closes. One link per host: a new one replaces
// the old.
func (s *server) link(w http.ResponseWriter, r *http.Request) {
	if !s.startPending() {
		http.Error(w, "too many links waiting to authenticate", http.StatusServiceUnavailable)
		return
	}
	conn, err := websocket.Accept(w, r, nil)
	if err != nil {
		s.endPending()
		return
	}
	conn.SetReadLimit(linkMessageLimit)
	host, err := s.authenticate(r.Context(), conn)
	s.endPending()
	if err != nil {
		s.audit.record(auditEvent{Event: "link-refused", Host: host, Remote: r.RemoteAddr, Reason: err.Error()})
		conn.Close(websocket.StatusPolicyViolation, "not an enrolled host")
		return
	}
	enrolled := s.state.host(host)
	if enrolled == nil { // removed since it authenticated
		conn.Close(websocket.StatusPolicyViolation, "this host was removed from the control plane")
		return
	}
	l := &link{conn: conn, remote: r.RemoteAddr, connected: s.now(), lastSeen: s.now()}
	if previous := s.register(host, l); previous != nil {
		// Close waits for the other end's answer, so not on this link's way in.
		go previous.conn.Close(websocket.StatusGoingAway, "replaced by a newer link from the same host")
	}
	s.audit.record(auditEvent{Event: "link-opened", Host: host, Name: enrolled.Name, Remote: r.RemoteAddr})
	log.Printf("%s (%s) connected from %s", enrolled.Name, host, r.RemoteAddr)
	if err := wsjson.Write(r.Context(), conn, message{Type: "welcome", Host: host}); err != nil {
		s.unregister(host, l, "write failed")
		return
	}

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	go s.keepAlive(ctx, conn)
	for {
		var m message
		if err := wsjson.Read(ctx, conn, &m); err != nil {
			s.unregister(host, l, closeReason(err))
			return
		}
		l.mu.Lock()
		l.lastSeen = s.now()
		switch m.Type {
		case "hello":
			l.hello = m
		case "capacity":
			l.slots = m.Slots
		}
		l.mu.Unlock()
	}
}

// authenticate sends a challenge and checks the host's signature over it; it returns the host's
// ID, also on failure when the host named one.
func (s *server) authenticate(ctx context.Context, conn *websocket.Conn) (string, error) {
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
	if answer.Type != "auth" || answer.Host == "" {
		return answer.Host, errors.New("no auth message")
	}
	enrolled := s.state.host(answer.Host)
	if enrolled == nil {
		return answer.Host, errors.New("unknown or removed host")
	}
	key, err := parseHostKey(enrolled.PublicKey)
	if err != nil {
		return answer.Host, err
	}
	digest := sha256.Sum256(append([]byte(linkContext), nonce...))
	if !ecdsa.VerifyASN1(key, digest[:], answer.Signature) {
		return answer.Host, errors.New("bad signature")
	}
	return answer.Host, nil
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

func (s *server) startPending() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.pending >= pendingLinkLimit {
		return false
	}
	s.pending++
	return true
}

func (s *server) endPending() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pending--
}

// register makes l the host's link and returns the one it replaces, if any.
func (s *server) register(host string, l *link) *link {
	s.mu.Lock()
	defer s.mu.Unlock()
	previous := s.links[host]
	s.links[host] = l
	return previous
}

// unregister forgets l, unless a newer link has already replaced it.
func (s *server) unregister(host string, l *link, reason string) {
	s.mu.Lock()
	current := s.links[host] == l
	if current {
		delete(s.links, host)
	}
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

// hostStatus is a host as `paddock-control hosts` shows it.
type hostStatus struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Enrolled  time.Time `json:"enrolled"`
	Online    bool      `json:"online"`
	Remote    string    `json:"remote,omitempty"`
	Connected time.Time `json:"connected,omitzero"`
	LastSeen  time.Time `json:"lastSeen,omitzero"`
	Version   string    `json:"version,omitempty"`
	MacOS     string    `json:"macos,omitempty"`
	Image     string    `json:"image,omitempty"`
	Slots     []slot    `json:"slots,omitempty"`
}

func (s *server) status() []hostStatus {
	var list []hostStatus
	for _, host := range s.state.hosts() {
		status := hostStatus{ID: host.ID, Name: host.Name, Enrolled: host.Enrolled}
		s.mu.Lock()
		l := s.links[host.ID]
		s.mu.Unlock()
		if l != nil {
			l.mu.Lock()
			status.Online, status.Remote, status.Connected, status.LastSeen = true, l.remote, l.connected, l.lastSeen
			status.Version, status.MacOS, status.Image, status.Slots = l.hello.Version, l.hello.MacOS, l.hello.Image, l.slots
			l.mu.Unlock()
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
	return err.Error()
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
