package main

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

// fakeHost is a linked host that answers forwarded requests the way serve does.
type fakeHost struct {
	id       string
	conn     *websocket.Conn
	mu       sync.Mutex
	requests []string
}

// startFakeHost enrolls and links a host serving image with warm warm slots, and answers
// acquire, exec, screenshot and release until the test ends.
func (c *testControl) startFakeHost(t *testing.T, image string, warm int) *fakeHost {
	t.Helper()
	key, publicKey := newHostKey(t)
	_, enrolled := c.enroll(t, c.token(t), "mac-"+image, publicKey)
	conn, _, err := c.link(t, enrolled.Host, key)
	if err != nil {
		t.Fatal(err)
	}
	h := &fakeHost{id: enrolled.Host, conn: conn}
	t.Cleanup(func() { conn.CloseNow() })
	ctx := context.Background()
	wsjson.Write(ctx, conn, message{Type: "hello", Image: image})
	h.report(warm)
	go func() {
		for {
			var m message
			if err := wsjson.Read(ctx, conn, &m); err != nil {
				return
			}
			if m.Type != "request" {
				continue
			}
			h.mu.Lock()
			h.requests = append(h.requests, m.Serve)
			h.mu.Unlock()
			var request map[string]any
			json.Unmarshal([]byte(m.Serve), &request)
			reply := func(line string, done bool) {
				wsjson.Write(ctx, conn, message{Type: "response", ID: m.ID, Line: line, Done: done})
			}
			switch request["op"] {
			case "acquire":
				reply(`{"vm":"`+image+`-slot1-abc","ip":"192.168.64.2"}`, true)
			case "exec":
				reply(`{"output":"hello"}`, false)
				reply(`{"exit":0}`, true)
			case "screenshot":
				wsjson.Write(ctx, conn, message{Type: "response", ID: m.ID, Data: []byte("PNG1")})
				wsjson.Write(ctx, conn, message{Type: "response", ID: m.ID, Data: []byte("PNG2")})
				reply(`{}`, true)
			case "release":
				reply(`{"vm":"`+request["vm"].(string)+`"}`, true)
			case "task":
				// The bundle arrives as uploads after the request; the result goes back as data.
				var bundle []byte
				for {
					var piece message
					if err := wsjson.Read(ctx, conn, &piece); err != nil {
						return
					}
					if piece.Type != "upload" || piece.ID != m.ID {
						continue
					}
					bundle = append(bundle, piece.Data...)
					if piece.Done {
						break
					}
				}
				reply(`{"output":"got `+string(bundle)+`"}`, false)
				wsjson.Write(ctx, conn, message{Type: "response", ID: m.ID, Data: []byte("NEW-COMMITS")})
				reply(`{"exit":0}`, true)
			default:
				reply(`{"error":"unexpected"}`, true)
			}
		}
	}()
	return h
}

func (h *fakeHost) report(warm int) {
	var slots []slot
	for i := 0; i < warm; i++ {
		slots = append(slots, slot{Number: i + 1, State: "warm"})
	}
	if len(slots) == 0 {
		slots = []slot{{Number: 1, State: "assigned"}}
	}
	wsjson.Write(context.Background(), h.conn, message{Type: "capacity", Slots: slots})
}

func (h *fakeHost) all() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]string(nil), h.requests...)
}

func (h *fakeHost) sawRequest(op string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, line := range h.requests {
		if strings.Contains(line, `"op":"`+op+`"`) {
			return true
		}
	}
	return false
}

// newClient enrolls a client and opens its link.
func (c *testControl) newClient(t *testing.T) (string, *websocket.Conn) {
	t.Helper()
	key, publicKey := newHostKey(t)
	_, client := c.enrollAs(t, clientKind, c.loginToken(t), publicKey)
	conn, _, err := c.clientLinkAs(t, client.Client, key, clientContext)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.CloseNow() })
	return client.Client, conn
}

// ask sends a request on a client link and returns its answers up to the one marked done.
func ask(t *testing.T, conn *websocket.Conn, request message) []message {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	request.Type = "request"
	if err := wsjson.Write(ctx, conn, request); err != nil {
		t.Fatal(err)
	}
	var answers []message
	for {
		var m message
		if err := wsjson.Read(ctx, conn, &m); err != nil {
			t.Fatalf("waiting for %s: %v; so far %+v", request.ID, err, answers)
		}
		if m.ID != request.ID {
			continue
		}
		answers = append(answers, m)
		if m.Done {
			return answers
		}
	}
}

func (c *testControl) waitUntilOnline(t *testing.T, image string) {
	c.waitFor(t, image+" online", func(list []hostStatus) bool {
		for _, h := range list {
			if h.Online && h.Image == image && len(h.Slots) > 0 {
				return true
			}
		}
		return false
	})
}

func TestAcquireGoesToAWarmHostAndTheVMIsTheClientsAlone(t *testing.T) {
	c := newTestControl(t)
	host := c.startFakeHost(t, "golden", 1)
	c.waitUntilOnline(t, "golden")
	alice, aliceConn := c.newClient(t)
	_, bobConn := c.newClient(t)

	got := ask(t, aliceConn, message{ID: "1", Op: "acquire", Serve: `{"op":"acquire","allow":["github.com"]}`})
	last := got[len(got)-1]
	if last.Error != "" || !strings.Contains(last.Line, `"vm":"golden-slot1-abc"`) || !strings.Contains(last.Line, `"host":"mac-golden"`) {
		t.Fatalf("acquire answers %+v", got)
	}
	if !host.sawRequest("acquire") || !strings.Contains(strings.Join(host.all(), " "), "github.com") {
		t.Fatalf("the host got %v", host.all())
	}
	if h := c.srv.state.handout("golden-slot1-abc"); h == nil || h.Client != alice || h.Host != host.id {
		t.Fatalf("hand-out %+v", h)
	}

	exec := `{"op":"exec","vm":"golden-slot1-abc","command":"uname"}`
	if got := ask(t, bobConn, message{ID: "2", Op: "exec", Serve: exec}); !strings.Contains(got[0].Error, "isn't a VM you acquired") {
		t.Fatalf("another client's exec: %+v", got)
	}
	got = ask(t, aliceConn, message{ID: "3", Op: "exec", Serve: exec})
	if len(got) != 2 || got[0].Line != `{"output":"hello"}` || got[1].Line != `{"exit":0}` {
		t.Fatalf("exec answers %+v", got)
	}

	got = ask(t, aliceConn, message{ID: "4", Op: "screenshot", Serve: `{"op":"screenshot","vm":"golden-slot1-abc","result":"/etc/hosts"}`})
	if len(got) != 3 || string(got[0].Data)+string(got[1].Data) != "PNG1PNG2" {
		t.Fatalf("screenshot answers %+v", got)
	}
	for _, line := range host.all() {
		if strings.Contains(line, "/etc/hosts") {
			t.Fatalf("a client's host path reached the host: %s", line)
		}
	}

	ask(t, aliceConn, message{ID: "5", Op: "release", Serve: `{"op":"release","vm":"golden-slot1-abc"}`})
	if c.srv.state.handout("golden-slot1-abc") != nil {
		t.Fatal("still handed out after release")
	}
}

func TestAcquireWaitsForAWarmSlotThenGetsIt(t *testing.T) {
	c := newTestControl(t)
	host := c.startFakeHost(t, "golden", 0)
	c.waitUntilOnline(t, "golden")
	_, conn := c.newClient(t)
	ctx, cancel := contextWithTimeout()
	defer cancel()
	wsjson.Write(ctx, conn, message{Type: "request", ID: "1", Op: "acquire"})
	var note message
	if err := wsjson.Read(ctx, conn, &note); err != nil || !strings.Contains(note.Note, "waiting") || note.Done {
		t.Fatalf("expected a waiting note, got %+v, %v", note, err)
	}
	host.report(1)
	var answer message
	if err := wsjson.Read(ctx, conn, &answer); err != nil || !strings.Contains(answer.Line, "golden-slot1-abc") || !answer.Done {
		t.Fatalf("after a slot went warm: %+v, %v", answer, err)
	}
}

func TestAcquireNamesTheImagesThePoolServes(t *testing.T) {
	c := newTestControl(t)
	c.startFakeHost(t, "golden", 1)
	c.startFakeHost(t, "ci", 1)
	c.waitUntilOnline(t, "golden")
	c.waitUntilOnline(t, "ci")
	_, conn := c.newClient(t)
	if got := ask(t, conn, message{ID: "1", Op: "acquire", Image: "xcode"}); !strings.Contains(got[0].Error, "ci, golden") {
		t.Fatalf("an image nobody serves: %+v", got)
	}
	if got := ask(t, conn, message{ID: "2", Op: "acquire"}); !strings.Contains(got[0].Error, "--image") {
		t.Fatalf("no image with two in the pool: %+v", got)
	}
	if got := ask(t, conn, message{ID: "3", Op: "acquire", Image: "ci"}); !strings.Contains(got[len(got)-1].Line, "ci-slot1-abc") {
		t.Fatalf("acquire --image ci: %+v", got)
	}
}

func TestRemovingAClientReleasesItsVMs(t *testing.T) {
	c := newTestControl(t)
	host := c.startFakeHost(t, "golden", 1)
	c.waitUntilOnline(t, "golden")
	client, conn := c.newClient(t)
	ask(t, conn, message{ID: "1", Op: "acquire"})
	c.srv.admin(adminRequest{Op: "remove-client", Host: client}, nil)
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) && (c.srv.state.handout("golden-slot1-abc") != nil || !host.sawRequest("release")) {
		time.Sleep(10 * time.Millisecond)
	}
	if c.srv.state.handout("golden-slot1-abc") != nil || !host.sawRequest("release") {
		t.Fatalf("the removed client's VM wasn't released: %v", host.all())
	}
}

func TestATasksBundleGoesUpAndItsResultComesBack(t *testing.T) {
	c := newTestControl(t)
	host := c.startFakeHost(t, "golden", 1)
	c.waitUntilOnline(t, "golden")
	_, conn := c.newClient(t)
	ask(t, conn, message{ID: "1", Op: "acquire"})
	ctx, cancel := contextWithTimeout()
	defer cancel()
	task := `{"op":"task","vm":"golden-slot1-abc","command":"make","bundle":"/etc/hosts","result":"/etc/passwd"}`
	wsjson.Write(ctx, conn, message{Type: "request", ID: "2", Op: "task", Serve: task})
	wsjson.Write(ctx, conn, message{Type: "upload", ID: "2", Data: []byte("BUN")})
	wsjson.Write(ctx, conn, message{Type: "upload", ID: "2", Data: []byte("DLE"), Done: true})
	var answers []message
	for {
		var m message
		if err := wsjson.Read(ctx, conn, &m); err != nil {
			t.Fatalf("task answers: %v; so far %+v", err, answers)
		}
		answers = append(answers, m)
		if m.Done {
			break
		}
	}
	if len(answers) != 3 || answers[0].Line != `{"output":"got BUNDLE"}` || string(answers[1].Data) != "NEW-COMMITS" {
		t.Fatalf("task answers %+v", answers)
	}
	for _, line := range host.all() {
		if strings.Contains(line, "/etc/") {
			t.Fatalf("a client's path reached the host: %s", line)
		}
	}
}

func TestARequestMustCarryTheOperationItsRoutedAs(t *testing.T) {
	c := newTestControl(t)
	c.startFakeHost(t, "golden", 1)
	c.waitUntilOnline(t, "golden")
	_, conn := c.newClient(t)
	ask(t, conn, message{ID: "1", Op: "acquire"})
	got := ask(t, conn, message{ID: "2", Op: "exec", Serve: `{"op":"task","vm":"golden-slot1-abc","command":"make"}`})
	if !strings.Contains(got[0].Error, "carries 'task'") {
		t.Fatalf("a task sent as exec: %+v", got)
	}
}
