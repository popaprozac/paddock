package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"sort"
	"strings"
	"time"
)

// relayedOperations is what a client may ask of a VM it acquired, through the pool: serve's VM
// operations, task's bundles carried as data both ways, and a view's input and frames.
var relayedOperations = map[string]bool{"release": true, "exec": true, "axtree": true, "input": true, "screenshot": true, "task": true, "view": true}

// maxTransfer is the most one request may send to a host, such as a task's bundle, so one can't
// fill a Mac's disk.
const maxTransfer = 1 << 30

// waiter is an acquire waiting for a warm slot of its image, first come, first served.
type waiter struct {
	image    string
	assigned chan string // the host it was given, once there is one
}

// warmFree is how many warm slots a host has that no acquire on its way is counting on; the
// caller holds s.mu.
func (s *server) warmFree(host string, l *link) int {
	l.mu.Lock()
	if l.busy {
		l.mu.Unlock()
		return 0
	}
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
// turn behind earlier ones, or ahead of them all when it's back after a busy host; note tells the
// client it's waiting.
func (s *server) waitForSlot(ctx context.Context, image string, front bool, note func(string)) (string, error) {
	w := &waiter{image: image, assigned: make(chan string, 1)}
	s.mu.Lock()
	ahead := 0
	if front {
		s.waiters = append([]*waiter{w}, s.waiters...)
	} else {
		ahead = len(s.waiters)
		s.waiters = append(s.waiters, w)
	}
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
	data, _ := marshal(r)
	return string(data)
}

// marshal is json.Marshal without HTML escaping, which made each '<', '>' or '&' six bytes, and
// seven once the line was quoted in a message: a command full of them outgrew the Mac's limit.
func marshal(v any) ([]byte, error) {
	var b bytes.Buffer
	encoder := json.NewEncoder(&b)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(b.Bytes(), []byte("\n")), nil
}

// sendFailed is why a request for vm didn't reach the VM's Mac.
func sendFailed(vm string, err error) error {
	if errors.Is(err, errTooBig) {
		return fmt.Errorf("the request is too big: %w", err)
	}
	return fmt.Errorf("the Mac running '%s' isn't reachable: %v", vm, err)
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
	note := func(note string) {
		_ = l.write(ctx, message{Type: "response", ID: request.ID, Note: note})
	}
	var host string
	var got serveRequest
	for busy := false; ; {
		if host, err = s.waitForSlot(ctx, image, busy, note); err != nil {
			return // the client went away
		}
		if got, busy, err = s.acquireOn(ctx, host, forward); err != nil {
			fail(err)
			return
		}
		if !busy {
			break
		}
	}
	vm := got.str("vm")
	if err := s.state.addHandout(handout{VM: vm, Host: host, Client: client, Image: image, Since: s.now()}); errors.Is(err, errHandedOut) {
		s.audit.record(auditEvent{Event: "acquire-refused", Client: client, Host: host, VM: vm, Reason: "the Mac handed out a VM that " + err.Error()})
		fail(fmt.Errorf("the Mac handed out '%s', which %v", vm, err))
		return
	} else if err != nil {
		log.Printf("can't save a hand-out: %v", err)
	}
	s.audit.record(auditEvent{Event: "handed-out", Client: client, Host: host, VM: vm, Image: image})
	if member := s.state.member(hostKind, host); member != nil {
		got["host"] = member.Name
	}
	// A client that left while its acquire was on its way would never know to release the VM.
	if ctx.Err() != nil || l.write(ctx, message{Type: "response", ID: request.ID, Line: got.line(), Done: true}) != nil {
		s.releaseOn(client, host, vm, "the client left before its VM reached it")
	}
}

// acquireOn asks host's serve for a warm VM, with a slot reserved for it. Busy means the host had
// none free after all: its last report is up to a second old, and a person at that Mac may have
// taken the slot. The host is then offered no acquire until it reports again.
func (s *server) acquireOn(ctx context.Context, host string, forward serveRequest) (serveRequest, bool, error) {
	defer s.unreserve(host)
	answers, cancel, err := s.forward(ctx, host, forward.line())
	if err != nil {
		return nil, false, err
	}
	defer cancel()
	for answer := range answers {
		if answer.Error != "" {
			return nil, false, fmt.Errorf("%s", answer.Error)
		}
		got, err := parseServe(answer.Line)
		if err != nil {
			return nil, false, err
		}
		if got["busy"] == true {
			s.markHost(host, func(l *link) { l.busy = true })
			return nil, true, nil
		}
		if problem := got.str("error"); problem != "" {
			return nil, false, fmt.Errorf("%s", problem)
		}
		if vm := got.str("vm"); vm != "" {
			// Until the host's next report says so, the slot it handed out isn't free.
			s.markHost(host, func(l *link) { l.markAssigned(vm) })
			return got, false, nil
		}
	}
	return nil, false, fmt.Errorf("%s didn't hand out a VM", host)
}

// markHost changes what the control plane knows of an online host until the host reports again.
func (s *server) markHost(host string, change func(*link)) {
	s.mu.Lock()
	l := s.links[host]
	s.mu.Unlock()
	if l == nil {
		return
	}
	l.mu.Lock()
	change(l)
	l.mu.Unlock()
}

// markAssigned marks the slot that held vm, or failing that the first warm one, as handed out;
// the caller holds l.mu. A report sent after the hand-out names vm's slot assigned already, and
// another warm slot is still free.
func (l *link) markAssigned(vm string) {
	first := -1
	for i, slot := range l.slots {
		if slot.VM == vm {
			if slot.State == "warm" {
				l.slots[i].State = "assigned"
			}
			return
		}
		if first < 0 && slot.State == "warm" {
			first = i
		}
	}
	if first >= 0 {
		l.slots[first].State = "assigned"
	}
}

// relayVM passes a client's request for a VM it acquired to the VM's host, and the host's answers
// back. Anything that names a file on the host is dropped, and the host refuses it as well.
func (s *server) relayVM(ctx context.Context, client string, l *clientLink, request message) {
	fail := func(err error) {
		_ = l.write(ctx, message{Type: "response", ID: request.ID, Error: err.Error(), Done: true})
	}
	asked, h, err := s.ownedRequest(client, request)
	if err != nil {
		fail(err)
		return
	}
	op, vm := asked.str("op"), asked.str("vm")
	s.audit.record(auditEvent{Event: "request", Client: client, Host: h.Host, VM: vm, Op: op})
	answers, cancel, err := s.forward(ctx, h.Host, asked.line())
	if err != nil {
		fail(sendFailed(vm, err))
		return
	}
	defer cancel()
	released := false
	pass(ctx, l, request.ID, answers, func(answer message) {
		if op == "release" && answer.Line != "" {
			if got, err := parseServe(answer.Line); err == nil && got.str("error") == "" {
				released = true
			}
		}
	})
	if released {
		removed, err := s.state.removeHandout(vm)
		if err != nil {
			log.Printf("can't save a release: %v", err)
		}
		if removed {
			s.audit.record(auditEvent{Event: "released", Client: client, Host: h.Host, VM: vm})
		}
	}
}

// pass sends a host's answers on to the client, each seen by look first, until they end or the
// client goes away.
func pass(ctx context.Context, l *clientLink, id string, answers <-chan message, look func(message)) {
	for answer := range answers {
		look(answer)
		reply := message{Type: "response", ID: id, Line: answer.Line, Data: answer.Data, Error: answer.Error, Done: answer.Done}
		if err := l.write(ctx, reply); err != nil {
			return
		}
	}
}

// ownedRequest reads a client's request for a VM, checks it's the operation the request is routed
// as and the VM is the client's, and drops any path naming a file on the host; it returns the
// request and the VM's hand-out.
func (s *server) ownedRequest(client string, request message) (serveRequest, *handout, error) {
	asked, err := parseServe(request.Serve)
	if err != nil {
		return nil, nil, err
	}
	op, vm := asked.str("op"), asked.str("vm")
	if !relayedOperations[op] {
		return nil, nil, fmt.Errorf("the pool doesn't relay '%s'", op)
	}
	if op != request.Op {
		return nil, nil, fmt.Errorf("the request is for '%s' but carries '%s'", request.Op, op)
	}
	h := s.state.handout(vm)
	if h == nil || h.Client != client {
		return nil, nil, fmt.Errorf("'%s' isn't a VM you acquired from this pool", vm)
	}
	delete(asked, "bundle")
	delete(asked, "result")
	return asked, h, nil
}

// relayTask runs a task in a VM the client acquired: the client's bundle goes to the VM's host in
// pieces as they come, and the host's answers, with the bundle of new commits as data, come back.
func (s *server) relayTask(ctx context.Context, client string, l *clientLink, request message, uploads *upload) {
	defer l.dropUpload(request.ID, uploads)
	fail := func(err error) {
		_ = l.write(ctx, message{Type: "response", ID: request.ID, Error: err.Error(), Done: true})
	}
	asked, h, err := s.ownedRequest(client, request)
	if err != nil {
		fail(err)
		return
	}
	s.audit.record(auditEvent{Event: "request", Client: client, Host: h.Host, VM: h.VM, Op: "task"})
	f, err := s.send(ctx, h.Host, asked.line())
	if err != nil {
		fail(sendFailed(h.VM, err))
		return
	}
	defer f.cancel()
	uploaded := make(chan error, 1)
	go func() {
		total := 0
		for {
			select {
			case piece, open := <-uploads.pieces:
				if !open { // closed after the last piece
					uploaded <- nil
					return
				}
				total += len(piece.Data)
				if total > maxTransfer {
					uploaded <- fmt.Errorf("the bundle is over %d GB, the most a task takes", maxTransfer>>30)
					return
				}
				if err := f.upload(ctx, piece.Data, piece.Done); err != nil {
					uploaded <- err
					return
				}
			case <-ctx.Done(): // the client left mid-upload: nothing closes uploads then
				uploaded <- ctx.Err()
				return
			}
		}
	}()
	if err := <-uploaded; err != nil {
		// The Mac holds part of the bundle: have it drop that, not wait for the rest.
		_ = f.link.write(message{Type: "cancel", ID: f.id})
		fail(err)
		return
	}
	pass(ctx, l, request.ID, f.answers, func(message) {})
}

// relayStream runs a request whose client keeps sending while the host answers, such as a view of
// a VM: the client's uploads go to the host as they come, the host's answers come back as they
// come, and a client that leaves has the request cancelled on the Mac, which stops it.
func (s *server) relayStream(ctx context.Context, client string, l *clientLink, request message, uploads *upload) {
	defer l.dropUpload(request.ID, uploads)
	fail := func(err error) {
		_ = l.write(ctx, message{Type: "response", ID: request.ID, Error: err.Error(), Done: true})
	}
	asked, h, err := s.ownedRequest(client, request)
	if err != nil {
		fail(err)
		return
	}
	s.audit.record(auditEvent{Event: "request", Client: client, Host: h.Host, VM: h.VM, Op: request.Op})
	f, err := s.send(ctx, h.Host, asked.line())
	if err != nil {
		fail(sendFailed(h.VM, err))
		return
	}
	defer f.cancel()
	finished := make(chan struct{})
	defer close(finished)
	go func() {
		for {
			select {
			case piece, open := <-uploads.pieces:
				if !open { // closed after the client's last piece
					return
				}
				if err := f.upload(ctx, piece.Data, piece.Done); err != nil {
					return
				}
			case <-finished:
				return
			}
		}
	}()
	// Not pass: a quiet view sends nothing for a while, so this also watches for the client leaving.
	for {
		select {
		case answer, open := <-f.answers:
			if !open {
				return
			}
			reply := message{Type: "response", ID: request.ID, Line: answer.Line, Data: answer.Data, Error: answer.Error, Done: answer.Done}
			if err := l.write(ctx, reply); err == nil {
				continue
			}
		case <-ctx.Done():
		}
		// The client left with the request still running: tell the Mac to stop it.
		_ = f.link.write(message{Type: "cancel", ID: f.id})
		return
	}
}

// releaseAll hands back every VM a client holds, as when it's removed or logs out, so a removed
// person keeps nothing.
func (s *server) releaseAll(client string) {
	for _, h := range s.state.handoutsWhere(func(h handout) bool { return h.Client == client }) {
		s.releaseOn(client, h.Host, h.VM, "client removed")
	}
}

// forgetMissing forgets host's hand-outs whose VM its report names in no slot: its serve stopped
// or restarted, which deletes them. A VM still in a slot stays, even warm, as in a report sent
// just before the hand-out; serve names every clone anew, so a restart leaves no old name. Of the
// VMs it still has, the releases it didn't answer are sent again.
func (s *server) forgetMissing(host string, slots []slot) {
	reported := map[string]bool{}
	for _, slot := range slots {
		reported[slot.VM] = true
	}
	for _, h := range s.state.handoutsWhere(func(h handout) bool { return h.Host == host && !reported[h.VM] }) {
		removed, err := s.state.removeHandout(h.VM)
		if err != nil {
			log.Printf("can't save a release: %v", err)
		}
		if removed {
			s.audit.record(auditEvent{Event: "released", Client: h.Client, Host: host, VM: h.VM, Reason: "the Mac no longer has it"})
		}
	}
	for _, h := range s.state.handoutsWhere(func(h handout) bool { return h.Host == host && reported[h.VM] && h.Releasing != "" }) {
		go s.releaseOn(h.Client, host, h.VM, h.Releasing) // its answer comes through the read loop that called this
	}
}

// releaseOn hands a VM back to its host and, once the host answers, forgets its hand-out,
// recording why. Until then the hand-out is kept as being released, and forgetMissing tries again.
func (s *server) releaseOn(client, host, vm, reason string) {
	if err := s.state.markReleasing(vm, reason); err != nil {
		log.Printf("can't save a release: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	answered := false
	if answers, stop, err := s.forward(ctx, host, serveRequest{"op": "release", "vm": vm}.line()); err == nil {
		for answer := range answers {
			answered = answered || answer.Line != ""
		}
		stop()
	}
	if !answered {
		log.Printf("%s didn't answer the release of %s: sending it again when it reports", host, vm)
		return
	}
	if removed, _ := s.state.removeHandout(vm); removed {
		s.audit.record(auditEvent{Event: "released", Client: client, Host: host, VM: vm, Reason: reason})
	}
}
