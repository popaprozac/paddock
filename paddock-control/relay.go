package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"sort"
	"strings"
	"time"
)

// relayedOperations is what a client may ask of a VM it acquired, through the pool: serve's VM
// operations. task comes later, with its bundles carried as data.
var relayedOperations = map[string]bool{"release": true, "exec": true, "axtree": true, "input": true, "screenshot": true}

// waiter is an acquire waiting for a warm slot of its image, first come, first served.
type waiter struct {
	image    string
	assigned chan string // the host it was given, once there is one
}

// warmFree is how many warm slots a host has that no acquire on its way is counting on; the
// caller holds s.mu.
func (s *server) warmFree(host string, l *link) int {
	l.mu.Lock()
	warm := 0
	for _, slot := range l.slots {
		if slot.State == "warm" {
			warm++
		}
	}
	l.mu.Unlock()
	return warm - s.reserved[host]
}

// placeLocked picks the online host serving image with the most free warm slots, if any has one;
// the caller holds s.mu.
func (s *server) placeLocked(image string) (string, bool) {
	best, bestFree := "", 0
	for host, l := range s.links {
		l.mu.Lock()
		serves := l.hello.Image == image
		l.mu.Unlock()
		if !serves {
			continue
		}
		if free := s.warmFree(host, l); free > bestFree || (free == bestFree && free > 0 && host < best) {
			best, bestFree = host, free
		}
	}
	return best, bestFree > 0
}

// dispatchLocked gives warm slots to waiting acquires in the order they came; the caller holds
// s.mu. It runs whenever the pool changes: a slot report, a link opening or closing, an acquire
// finishing on its host.
func (s *server) dispatchLocked() {
	kept := s.waiters[:0]
	for _, w := range s.waiters {
		if host, ok := s.placeLocked(w.image); ok {
			s.reserved[host]++
			w.assigned <- host
			continue
		}
		kept = append(kept, w)
	}
	s.waiters = kept
}

func (s *server) poolChanged() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.dispatchLocked()
}

// onlineImages is the images online hosts serve, sorted.
func (s *server) onlineImages() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	seen := map[string]bool{}
	for _, l := range s.links {
		l.mu.Lock()
		if l.hello.Image != "" {
			seen[l.hello.Image] = true
		}
		l.mu.Unlock()
	}
	images := make([]string, 0, len(seen))
	for image := range seen {
		images = append(images, image)
	}
	sort.Strings(images)
	return images
}

// chooseImage is the image an acquire asked for, or the pool's only one; or why there's none.
func (s *server) chooseImage(asked string) (string, error) {
	images := s.onlineImages()
	if len(images) == 0 {
		return "", fmt.Errorf("no Mac in the pool is online")
	}
	if asked == "" {
		if len(images) > 1 {
			return "", fmt.Errorf("the pool serves %s: choose one with --image", strings.Join(images, ", "))
		}
		return images[0], nil
	}
	for _, image := range images {
		if image == asked {
			return asked, nil
		}
	}
	return "", fmt.Errorf("no online Mac in the pool serves '%s'; it serves %s", asked, strings.Join(images, ", "))
}

// waitForSlot returns a host with a warm slot of image reserved for this acquire, waiting its
// turn behind earlier ones; note tells the client it's waiting.
func (s *server) waitForSlot(ctx context.Context, image string, note func(string)) (string, error) {
	w := &waiter{image: image, assigned: make(chan string, 1)}
	s.mu.Lock()
	s.waiters = append(s.waiters, w)
	ahead := len(s.waiters) - 1
	s.dispatchLocked()
	s.mu.Unlock()
	select {
	case host := <-w.assigned:
		return host, nil
	default:
	}
	note(fmt.Sprintf("no warm VM of '%s' is free; waiting, %d ahead", image, ahead))
	select {
	case host := <-w.assigned:
		return host, nil
	case <-ctx.Done():
		s.mu.Lock()
		for i, other := range s.waiters {
			if other == w {
				s.waiters = append(s.waiters[:i], s.waiters[i+1:]...)
				break
			}
		}
		s.mu.Unlock()
		// Given a slot just as it gave up: hand the reservation back.
		select {
		case host := <-w.assigned:
			s.unreserve(host)
		default:
		}
		return "", ctx.Err()
	}
}

func (s *server) unreserve(host string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.reserved[host] > 0 {
		s.reserved[host]--
	}
	s.dispatchLocked()
}

// serveRequest is the part of a serve request line the control plane reads to route and check it.
type serveRequest map[string]any

func parseServe(line string) (serveRequest, error) {
	var request serveRequest
	if err := json.Unmarshal([]byte(line), &request); err != nil || request == nil {
		return nil, fmt.Errorf("that isn't one of serve's requests")
	}
	return request, nil
}

func (r serveRequest) str(key string) string {
	value, _ := r[key].(string)
	return value
}

func (r serveRequest) line() string {
	data, _ := json.Marshal(r)
	return string(data)
}

// relayAcquire places an acquire on a host with a warm slot of the image, waiting its turn if
// none is free, and records the VM as the client's.
func (s *server) relayAcquire(ctx context.Context, client string, l *clientLink, request message) {
	fail := func(err error) {
		_ = l.write(ctx, message{Type: "response", ID: request.ID, Error: err.Error(), Done: true})
	}
	forward := serveRequest{"op": "acquire"}
	if request.Serve != "" {
		asked, err := parseServe(request.Serve)
		if err != nil {
			fail(err)
			return
		}
		if allow, ok := asked["allow"]; ok {
			forward["allow"] = allow
		}
	}
	image, err := s.chooseImage(request.Image)
	if err != nil {
		fail(err)
		return
	}
	host, err := s.waitForSlot(ctx, image, func(note string) {
		_ = l.write(ctx, message{Type: "response", ID: request.ID, Note: note})
	})
	if err != nil {
		return // the client went away
	}
	defer s.unreserve(host)
	answers, cancel, err := s.forward(ctx, host, forward.line())
	if err != nil {
		fail(err)
		return
	}
	defer cancel()
	hostName := ""
	if member := s.state.member(hostKind, host); member != nil {
		hostName = member.Name
	}
	for answer := range answers {
		if answer.Error != "" {
			fail(fmt.Errorf("%s", answer.Error))
			return
		}
		got, err := parseServe(answer.Line)
		if err != nil {
			fail(err)
			return
		}
		if problem := got.str("error"); problem != "" {
			fail(fmt.Errorf("%s", problem))
			return
		}
		vm := got.str("vm")
		if vm == "" {
			continue
		}
		if err := s.state.addHandout(handout{VM: vm, Host: host, Client: client, Image: image, Since: s.now()}); err != nil {
			log.Printf("can't save a hand-out: %v", err)
		}
		s.audit.record(auditEvent{Event: "handed-out", Client: client, Host: host, VM: vm, Image: image})
		got["host"] = hostName
		_ = l.write(ctx, message{Type: "response", ID: request.ID, Line: got.line(), Done: true})
		return
	}
	fail(fmt.Errorf("%s didn't hand out a VM", host))
}

// relayVM passes a client's request for a VM it acquired to the VM's host, and the host's answers
// back. Anything that names a file on the host is dropped, and the host refuses it as well.
func (s *server) relayVM(ctx context.Context, client string, l *clientLink, request message) {
	fail := func(err error) {
		_ = l.write(ctx, message{Type: "response", ID: request.ID, Error: err.Error(), Done: true})
	}
	asked, err := parseServe(request.Serve)
	if err != nil {
		fail(err)
		return
	}
	op, vm := asked.str("op"), asked.str("vm")
	if !relayedOperations[op] {
		fail(fmt.Errorf("the pool doesn't relay '%s'", op))
		return
	}
	h := s.state.handout(vm)
	if h == nil || h.Client != client {
		fail(fmt.Errorf("'%s' isn't a VM you acquired from this pool", vm))
		return
	}
	delete(asked, "bundle")
	delete(asked, "result")
	s.audit.record(auditEvent{Event: "request", Client: client, Host: h.Host, VM: vm, Op: op})
	answers, cancel, err := s.forward(ctx, h.Host, asked.line())
	if err != nil {
		fail(fmt.Errorf("the Mac running '%s' isn't reachable: %v", vm, err))
		return
	}
	defer cancel()
	released := false
	for answer := range answers {
		if op == "release" && answer.Line != "" {
			if got, err := parseServe(answer.Line); err == nil && got.str("error") == "" {
				released = true
			}
		}
		reply := message{Type: "response", ID: request.ID, Line: answer.Line, Data: answer.Data, Error: answer.Error, Done: answer.Done}
		if err := l.write(ctx, reply); err != nil {
			return
		}
	}
	if released {
		if err := s.state.removeHandout(vm); err != nil {
			log.Printf("can't save a release: %v", err)
		}
		s.audit.record(auditEvent{Event: "released", Client: client, Host: h.Host, VM: vm})
	}
}

// releaseAll hands back every VM a client holds, as when it's removed or logs out, so a removed
// person keeps nothing.
func (s *server) releaseAll(client string) {
	for _, h := range s.state.handoutsWhere(func(h handout) bool { return h.Client == client }) {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		if answers, stop, err := s.forward(ctx, h.Host, serveRequest{"op": "release", "vm": h.VM}.line()); err == nil {
			for range answers {
			}
			stop()
		}
		cancel()
		_ = s.state.removeHandout(h.VM)
		s.audit.record(auditEvent{Event: "released", Client: client, Host: h.Host, VM: h.VM, Reason: "client removed"})
	}
}
