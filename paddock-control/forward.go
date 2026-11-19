package main

import (
	"context"
	"fmt"
	"strconv"

	"github.com/coder/websocket/wsjson"
)

// answersBuffer is how many of a request's answers wait for whoever forwarded it before the
// host's link stops reading: back-pressure on a fast host, not a limit on how many there are.
const answersBuffer = 256

// forward sends one of serve's request lines down a host's link and returns the host's answers as
// they come, the last marked done. A host that isn't online fails at once; a link that closes
// before the host is done ends the answers with an error.
func (s *server) forward(ctx context.Context, host, serveLine string) (<-chan message, error) {
	s.mu.Lock()
	l := s.links[host]
	s.mu.Unlock()
	if l == nil {
		return nil, fmt.Errorf("%s isn't online", host)
	}
	answers := make(chan message, answersBuffer)
	l.mu.Lock()
	if l.closed {
		l.mu.Unlock()
		return nil, fmt.Errorf("%s's link just closed", host)
	}
	l.nextID++
	id := "r" + strconv.Itoa(l.nextID)
	if l.pending == nil {
		l.pending = map[string]chan message{}
	}
	l.pending[id] = answers
	l.mu.Unlock()
	if err := wsjson.Write(ctx, l.conn, message{Type: "request", ID: id, Serve: serveLine}); err != nil {
		l.mu.Lock()
		if _, ok := l.pending[id]; ok {
			delete(l.pending, id)
			close(answers)
		}
		l.mu.Unlock()
		return nil, err
	}
	return answers, nil
}

// deliver hands a host's answer to the request it's for, and ends the request once it's done.
// Only the link's read loop calls it, so only it closes a request's channel, apart from forward
// when its request never went out.
func (l *link) deliver(m message) {
	l.mu.Lock()
	answers := l.pending[m.ID]
	if answers != nil && m.Done {
		delete(l.pending, m.ID)
	}
	l.mu.Unlock()
	if answers == nil {
		return
	}
	answers <- m
	if m.Done {
		close(answers)
	}
}

// failPending ends every request still waiting when the link closes.
func (l *link) failPending() {
	l.mu.Lock()
	l.closed = true
	pending := l.pending
	l.pending = nil
	l.mu.Unlock()
	for _, answers := range pending {
		select {
		case answers <- message{Type: "response", Error: "the Mac's link closed before it answered", Done: true}:
		default:
		}
		close(answers)
	}
}
