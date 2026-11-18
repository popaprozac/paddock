package main

import (
	"context"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

// clientLink is a client's open connection: a person's CLI or an agent. A client can hold several
// at once, such as a command and an MCP session.
type clientLink struct {
	conn      *websocket.Conn
	remote    string
	connected time.Time
	writeMu   sync.Mutex // answers to requests on one link go out one at a time
	mu        sync.Mutex
	lastSeen  time.Time
}

// clientLink takes a client's WebSocket, has it prove it holds its enrolled key, then answers its
// requests, each with the request's ID, until the link closes.
func (s *server) clientLink(w http.ResponseWriter, r *http.Request) {
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
	client, err := s.authenticate(r.Context(), conn, clientKind)
	s.endPending()
	if err != nil {
		s.audit.record(auditEvent{Event: "client-link-refused", Client: client, Remote: r.RemoteAddr, Reason: err.Error()})
		conn.Close(websocket.StatusPolicyViolation, "not an enrolled client")
		return
	}
	member := s.state.member(clientKind, client)
	if member == nil { // removed since it authenticated
		conn.Close(websocket.StatusPolicyViolation, "this client was removed from the control plane")
		return
	}
	l := &clientLink{conn: conn, remote: r.RemoteAddr, connected: s.now(), lastSeen: s.now()}
	s.registerClient(client, l)
	defer s.unregisterClient(client, l)
	s.audit.record(auditEvent{Event: "client-link-opened", Client: client, Name: member.Name, Remote: r.RemoteAddr})
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	if err := l.write(ctx, message{Type: "welcome", Client: client}); err != nil {
		return
	}
	go s.keepAlive(ctx, conn)
	for {
		var m message
		if err := wsjson.Read(ctx, conn, &m); err != nil {
			s.audit.record(auditEvent{Event: "client-link-closed", Client: client, Remote: l.remote, Reason: closeReason(err)})
			return
		}
		l.mu.Lock()
		l.lastSeen = s.now()
		l.mu.Unlock()
		if m.Type != "request" || m.ID == "" {
			continue
		}
		s.answer(ctx, client, l, m)
	}
}

// answer runs one client request and sends its answers, the last marked done.
func (s *server) answer(ctx context.Context, client string, l *clientLink, request message) {
	reply := message{Type: "response", ID: request.ID, Done: true}
	switch request.Op {
	case "hosts":
		reply.Hosts = s.status()
	case "logout":
		// The client removes itself: its key is forgotten, and this and its other links close.
		if member, err := s.state.remove(clientKind, client); err == nil {
			s.audit.record(auditEvent{Event: "client-removed", Client: client, Name: member.Name, Reason: "logged out"})
			log.Printf("client %s (%s) logged out", member.Name, client)
		}
		_ = l.write(ctx, reply)
		s.disconnectClient(client, websocket.StatusNormalClosure, "logged out")
		return
	default:
		reply.Error = "unknown request " + request.Op
	}
	_ = l.write(ctx, reply)
}

func (l *clientLink) write(ctx context.Context, m message) error {
	l.writeMu.Lock()
	defer l.writeMu.Unlock()
	return wsjson.Write(ctx, l.conn, m)
}

func (s *server) registerClient(client string, l *clientLink) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.clientLinks[client] == nil {
		s.clientLinks[client] = map[*clientLink]bool{}
	}
	s.clientLinks[client][l] = true
}

func (s *server) unregisterClient(client string, l *clientLink) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.clientLinks[client], l)
	if len(s.clientLinks[client]) == 0 {
		delete(s.clientLinks, client)
	}
}

// disconnectClient closes every link the client has open, as when it is removed.
func (s *server) disconnectClient(client string, code websocket.StatusCode, reason string) {
	s.mu.Lock()
	var links []*clientLink
	for l := range s.clientLinks[client] {
		links = append(links, l)
	}
	s.mu.Unlock()
	for _, l := range links {
		go l.conn.Close(code, reason)
	}
}

// clientStatus is a client as `paddock-control clients` shows it.
type clientStatus struct {
	ID       string    `json:"id"`
	Name     string    `json:"name"`
	Enrolled time.Time `json:"enrolled"`
	Links    int       `json:"links"`
	LastSeen time.Time `json:"lastSeen,omitzero"`
}

func (s *server) clientStatus() []clientStatus {
	var list []clientStatus
	for _, member := range s.state.list(clientKind) {
		status := clientStatus{ID: member.ID, Name: member.Name, Enrolled: member.Enrolled}
		s.mu.Lock()
		for l := range s.clientLinks[member.ID] {
			status.Links++
			l.mu.Lock()
			if l.lastSeen.After(status.LastSeen) {
				status.LastSeen = l.lastSeen
			}
			l.mu.Unlock()
		}
		s.mu.Unlock()
		list = append(list, status)
	}
	return list
}
