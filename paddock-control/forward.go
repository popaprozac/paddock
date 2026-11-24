package main

import (
	"context"
	"fmt"
	"strconv"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// answersBuffer is how many of a request's answers wait for whoever forwarded it before the
// host's link stops reading: back-pressure on a fast host, not a limit on how many there are.
// shortcut: one slow reader holds up the other requests on that host's link; per-session
// connections (or the direct path) would lift that once pools are busy enough to notice.
const answersBuffer = 256

// pendingRequest is a request forwarded to a host, waiting for its answers.
type pendingRequest struct {
	answers chan message
	gone    chan struct{} // closed when whoever forwarded it stops reading
	once    sync.Once
}

// forward sends one of serve's request lines down a host's link and returns the host's answers as
// they come, the last marked done, and a cancel to call once done reading, early or not: after it,
// the host's further answers are dropped instead of holding up its link. A host that isn't online
// fails at once; a link that closes before the host is done ends the answers with an error.
func (s *server) forward(ctx context.Context, host, serveLine string) (<-chan message, func(), error) {
	f, err := s.send(ctx, host, serveLine)
	if err != nil {
		return nil, nil, err
	}
	return f.answers, f.cancel, nil
}

// forwarded is a request sent down a host's link: its answers, its cancel, and its ID there, for
// sending the host data that goes with it, such as a task's bundle.
type forwarded struct {
	answers <-chan message
	cancel  func()
	id      string
	link    *link
}

// upload sends the host a piece of the data that goes with the request, the last marked done.
func (f *forwarded) upload(ctx context.Context, data []byte, done bool) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	return f.link.write(message{Type: "upload", ID: f.id, Data: data, Done: done})
}

// hostWriteTimeout bounds one write down a host's link.
const hostWriteTimeout = 30 * time.Second

// errTooBig is a message over what serve reads in one, the same limit as the control plane's:
// sending it would close the Mac's link, and fail every request on it.
var errTooBig = fmt.Errorf("it's over %d MiB, the most a Mac reads in one message", linkMessageLimit>>20)

// write sends a message down the host's link. A write whose context ends partway closes the whole
// connection, so these never take a client's context, which ends when that client goes away.
func (l *link) write(m message) error {
	data, err := marshal(m)
	if err != nil {
		return err
	}
	if len(data) > linkMessageLimit {
		return errTooBig
	}
	ctx, cancel := context.WithTimeout(context.Background(), hostWriteTimeout)
	defer cancel()
	return l.conn.Write(ctx, websocket.MessageText, data)
}

func (s *server) send(ctx context.Context, host, serveLine string) (*forwarded, error) {
	s.mu.Lock()
	l := s.links[host]
	s.mu.Unlock()
	if l == nil {
		return nil, fmt.Errorf("%s isn't online", host)
	}
	p := &pendingRequest{answers: make(chan message, answersBuffer), gone: make(chan struct{})}
	l.mu.Lock()
	if l.closed {
		l.mu.Unlock()
		return nil, fmt.Errorf("%s's link just closed", host)
	}
	l.nextID++
	id := "r" + strconv.Itoa(l.nextID)
	if l.pending == nil {
		l.pending = map[string]*pendingRequest{}
	}
	l.pending[id] = p
	l.mu.Unlock()
	cancel := func() {
		p.once.Do(func() { close(p.gone) })
		l.mu.Lock()
		if l.pending[id] == p {
			delete(l.pending, id)
		}
		l.mu.Unlock()
	}
	if err := ctx.Err(); err != nil {
		cancel()
		return nil, err
	}
	if err := l.write(message{Type: "request", ID: id, Serve: serveLine}); err != nil {
		cancel()
		return nil, err
	}
	return &forwarded{answers: p.answers, cancel: cancel, id: id, link: l}, nil
}

// deliver hands a host's answer to the request it's for, and ends the request once it's done.
// Only the link's read loop calls it and failPending, so only they close a request's answers.
func (l *link) deliver(m message) {
	l.mu.Lock()
	p := l.pending[m.ID]
	if p != nil && m.Done {
		delete(l.pending, m.ID)
	}
	l.mu.Unlock()
	if p == nil {
		return
	}
	select {
	case p.answers <- m:
	case <-p.gone:
		return
	}
	if m.Done {
		close(p.answers)
	}
}

// failPending ends every request still waiting when the link closes.
func (l *link) failPending() {
	l.mu.Lock()
	l.closed = true
	pending := l.pending
	l.pending = nil
	l.mu.Unlock()
	for _, p := range pending {
		select {
		case p.answers <- message{Type: "response", Error: "the Mac's link closed before it answered", Done: true}:
		case <-p.gone:
		}
		close(p.answers)
	}
}
