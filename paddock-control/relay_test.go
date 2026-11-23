package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

// fakeHost is a linked host that answers forwarded requests the way serve does.
type fakeHost struct {
	id        string
	conn      *websocket.Conn
	mu        sync.Mutex
	requests  []string
	acquired  int
	busy      bool          // answers acquires as a Mac with no warm VM free does
	hold      chan struct{} // if set, acquires are answered once it's closed
	cancelled []string      // the tasks the control plane told it to drop, by request ID
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
				h.mu.Lock()
				busy, hold := h.busy, h.hold
				h.acquired++
				vm := image + "-slot1-abc"
				if h.acquired > 1 {
					vm += strconv.Itoa(h.acquired)
				}
				h.mu.Unlock()
				if busy {
					reply(`{"error":"no warm VM is free on this Mac","busy":true}`, true)
					continue
				}
				go func() {
					if hold != nil {
						<-hold
					}
					reply(`{"vm":"`+vm+`","ip":"192.168.64.2"}`, true)
				}()
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
				cancelled := false
				for {
					var piece message
					if err := wsjson.Read(ctx, conn, &piece); err != nil {
						return
					}
					if piece.Type == "cancel" && piece.ID == m.ID {
						h.mu.Lock()
						h.cancelled = append(h.cancelled, m.ID)
						h.mu.Unlock()
						cancelled = true
						break
					}
					if piece.Type != "upload" || piece.ID != m.ID {
						continue
					}
					bundle = append(bundle, piece.Data...)
					if piece.Done {
						break
					}
				}
				if cancelled {
					continue
				}
				reply(`{"output":"got `+string(bundle)+`"}`, false)
				wsjson.Write(ctx, conn, message{Type: "response", ID: m.ID, Data: []byte("NEW-COMMITS")})
				reply(`{"exit":0}`, true)
			case "view":
				// A view's input arrives as uploads while it answers: each one answered at once, the
				// last ending it; a cancel ends it too.
				for {
					var piece message
					if err := wsjson.Read(ctx, conn, &piece); err != nil {
						return
					}
					if piece.Type == "cancel" && piece.ID == m.ID {
						h.mu.Lock()
						h.cancelled = append(h.cancelled, m.ID)
						h.mu.Unlock()
						break
					}
					if piece.Type != "upload" || piece.ID != m.ID {
						continue
					}
					reply(`{"got":"`+string(piece.Data)+`"}`, false)
					if piece.Done {
						reply(`{"ended":true}`, true)
						break
					}
				}
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

// eventually fails the test unless check comes true within 5 s.
func eventually(t *testing.T, what string, check func() bool) {
	t.Helper()
	for deadline := time.Now().Add(5 * time.Second); !check(); time.Sleep(10 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
	}
}

// A host reports its slots up to a second late, so a slot just handed out isn't offered again
// before the host says what's in it.
func TestASlotJustHandedOutIsntOfferedAgain(t *testing.T) {
	c := newTestControl(t)
	host := c.startFakeHost(t, "golden", 1)
	c.waitUntilOnline(t, "golden")
	_, conn := c.newClient(t)
	ask(t, conn, message{ID: "1", Op: "acquire"})
	ctx, cancel := contextWithTimeout()
	defer cancel()
	wsjson.Write(ctx, conn, message{Type: "request", ID: "2", Op: "acquire"})
	var note message
	if err := wsjson.Read(ctx, conn, &note); err != nil || !strings.Contains(note.Note, "waiting") {
		t.Fatalf("the second acquire: %+v, %v; the host got %v", note, err, host.all())
	}
	host.report(1)
	var answer message
	if err := wsjson.Read(ctx, conn, &answer); err != nil || !strings.Contains(answer.Line, "golden-slot1-abc2") {
		t.Fatalf("after the host reported a warm slot: %+v, %v", answer, err)
	}
}

// A Mac with no warm VM free after all, as when a person there took it, answers busy; the acquire
// goes back to the front of the queue and another Mac's warm VM serves it.
func TestABusyMacSendsTheAcquireToAnother(t *testing.T) {
	c := newTestControl(t)
	busy := c.startFakeHost(t, "golden", 2)
	busy.mu.Lock()
	busy.busy = true
	busy.mu.Unlock()
	free := c.startFakeHost(t, "golden", 1)
	c.waitFor(t, "both hosts warm", func(list []hostStatus) bool {
		warm := 0
		for _, h := range list {
			if h.Online && len(h.Slots) > 0 {
				warm++
			}
		}
		return warm == 2
	})
	_, conn := c.newClient(t)
	got := ask(t, conn, message{ID: "1", Op: "acquire"})
	if last := got[len(got)-1]; last.Error != "" || !strings.Contains(last.Line, "golden-slot1-abc") {
		t.Fatalf("acquire answers %+v", got)
	}
	if !busy.sawRequest("acquire") {
		t.Fatal("the Mac with the most warm slots wasn't asked first")
	}
	if h := c.srv.state.handout("golden-slot1-abc"); h == nil || h.Host != free.id {
		t.Fatalf("hand-out %+v, want it on %s", h, free.id)
	}
}

// A VM that reaches the control plane after its client left goes back to its Mac, rather than
// staying handed out to someone who never learned its name.
func TestAVMWhoseClientLeftIsReleased(t *testing.T) {
	c := newTestControl(t)
	host := c.startFakeHost(t, "golden", 1)
	hold := make(chan struct{})
	host.mu.Lock()
	host.hold = hold
	host.mu.Unlock()
	c.waitUntilOnline(t, "golden")
	client, conn := c.newClient(t)
	ctx, cancel := contextWithTimeout()
	defer cancel()
	wsjson.Write(ctx, conn, message{Type: "request", ID: "1", Op: "acquire"})
	eventually(t, "the host to get the acquire", func() bool { return host.sawRequest("acquire") })
	conn.Close(websocket.StatusNormalClosure, "")
	eventually(t, "the client's link to close", func() bool {
		c.srv.mu.Lock()
		defer c.srv.mu.Unlock()
		return len(c.srv.clientLinks[client]) == 0
	})
	close(hold)
	eventually(t, "the VM to go back", func() bool {
		return host.sawRequest("release") && c.srv.state.handout("golden-slot1-abc") == nil
	})
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

// A Mac whose serve stopped or restarted no longer has the VMs it handed out, so a report that
// names a hand-out's VM in no slot forgets it. One that still names it, even as warm, as a report
// sent just before the hand-out does, keeps it.
func TestAHandOutIsForgottenWhenItsMacNoLongerReportsTheVM(t *testing.T) {
	c := newTestControl(t)
	host := c.startFakeHost(t, "golden", 2)
	c.waitUntilOnline(t, "golden")
	client, conn := c.newClient(t)
	ask(t, conn, message{ID: "1", Op: "acquire"})
	ask(t, conn, message{ID: "2", Op: "acquire"})
	ctx := context.Background()
	wsjson.Write(ctx, host.conn, message{Type: "capacity", Slots: []slot{
		{Number: 1, State: "warm", VM: "golden-slot1-abc"}, {Number: 2, State: "assigned", VM: "golden-slot1-abc2"}}})
	wsjson.Write(ctx, host.conn, message{Type: "capacity", Slots: []slot{
		{Number: 1, State: "assigned", VM: "golden-slot1-abc"}, {Number: 2, State: "warm", VM: "golden-slot2-new"}}})
	released := `"event":"released","host":"` + host.id + `","client":"` + client +
		`","vm":"golden-slot1-abc2","reason":"the Mac no longer has it"`
	eventually(t, "the VM the Mac no longer has to be released", func() bool {
		audited, _ := os.ReadFile(filepath.Join(c.dir, "audit.log"))
		return strings.Contains(string(audited), released)
	})
	if c.srv.state.handout("golden-slot1-abc2") != nil {
		t.Fatal("the VM the Mac no longer has is still handed out")
	}
	if c.srv.state.handout("golden-slot1-abc") == nil {
		t.Fatal("a VM the Mac still reports was forgotten")
	}
	// A release that lost the race to that report records nothing more.
	c.srv.releaseOn(client, host.id, "golden-slot1-abc2", "client removed")
	audited, _ := os.ReadFile(filepath.Join(c.dir, "audit.log"))
	if n := strings.Count(string(audited), `"event":"released"`); n != 1 {
		t.Fatalf("%d released events for one hand-out:\n%s", n, audited)
	}
}

// Of the paths racing to end a hand-out, only the one that removes it gets told so.
func TestAHandOutIsRemovedOnce(t *testing.T) {
	st, err := openState(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := st.addHandout(handout{VM: "golden-slot1-abc", Host: "host", Client: "client"}); err != nil {
		t.Fatal(err)
	}
	first, err1 := st.removeHandout("golden-slot1-abc")
	second, err2 := st.removeHandout("golden-slot1-abc")
	if !first || second || err1 != nil || err2 != nil {
		t.Fatalf("removals: %v (%v), then %v (%v); want true, then false", first, err1, second, err2)
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

// What a host uses reaches logged-in clients, with who holds each VM, and moves nothing in the
// queue: a usage report doesn't clear a busy mark the way a capacity report does.
func TestUsageReachesClientsWithWhoHoldsEachVM(t *testing.T) {
	c := newTestControl(t)
	host := c.startFakeHost(t, "golden", 0)
	ctx, cancel := contextWithTimeout()
	defer cancel()
	wsjson.Write(ctx, host.conn, message{Type: "capacity", Slots: []slot{
		{Number: 1, State: "warm", VM: "golden-slot1-abc"}, {Number: 2, State: "warm", VM: "golden-slot2-xyz"}}})
	c.waitUntilOnline(t, "golden")
	eventually(t, "two warm slots", func() bool {
		list := c.srv.status()
		return len(list) == 1 && len(list[0].Slots) == 2 && list[0].Slots[1].State == "warm"
	})
	_, conn := c.newClient(t)
	ask(t, conn, message{ID: "1", Op: "acquire"})
	c.srv.markHost(host.id, func(l *link) { l.busy = true })
	cpu, vmCPU, disk := 23.5, 112.0, uint64(500<<30)
	wsjson.Write(ctx, host.conn, message{Type: "usage",
		Usage: &macUsage{CPU: &cpu, MemoryUsed: 20 << 30, MemoryTotal: 36 << 30, Pressure: "warn", Thermal: "fair", DiskFree: &disk},
		Slots: []slot{
			{Number: 1, State: "assigned", VM: "golden-slot1-abc", Age: 12, Usage: &vmUsage{CPU: &vmCPU, Memory: 13 << 30}},
			{Number: 2, State: "warm", VM: "golden-slot2-xyz", Age: 40, Usage: &vmUsage{Memory: 9 << 30}},
		}})
	eventually(t, "the usage report", func() bool { return c.srv.status()[0].Usage != nil })

	got := ask(t, conn, message{ID: "2", Op: "hosts"})
	reply := got[len(got)-1]
	if len(reply.Hosts) != 1 || reply.Waiting == nil || *reply.Waiting != 0 {
		t.Fatalf("hosts reply %+v", reply)
	}
	h := reply.Hosts[0]
	if h.Usage == nil || *h.Usage.CPU != 23.5 || h.Usage.Pressure != "warn" || h.Usage.Thermal != "fair" {
		t.Fatalf("host usage %+v", h.Usage)
	}
	held, warm := h.Slots[0], h.Slots[1]
	if held.State != "assigned" || held.Holder != "zach on studio" || held.Age != 12 || held.Usage == nil || *held.Usage.CPU != 112 {
		t.Fatalf("the held slot %+v", held)
	}
	if warm.Holder != "" || warm.Age != 40 || warm.Usage == nil || warm.Usage.CPU != nil || warm.Usage.Memory != 9<<30 {
		t.Fatalf("the warm slot %+v", warm)
	}
	c.srv.mu.Lock()
	l := c.srv.links[host.id]
	c.srv.mu.Unlock()
	l.mu.Lock()
	busy := l.busy
	l.mu.Unlock()
	if !busy {
		t.Fatal("a usage report cleared the host's busy mark")
	}
}

// A client that leaves partway through a task's upload leaves the Mac holding part of a bundle:
// the control plane tells the Mac to drop it rather than wait for the rest.
func TestATaskWhoseClientLeavesMidUploadIsCancelledOnTheMac(t *testing.T) {
	c := newTestControl(t)
	host := c.startFakeHost(t, "golden", 1)
	c.waitUntilOnline(t, "golden")
	_, conn := c.newClient(t)
	ask(t, conn, message{ID: "1", Op: "acquire"})
	ctx, cancel := contextWithTimeout()
	defer cancel()
	wsjson.Write(ctx, conn, message{Type: "request", ID: "2", Op: "task", Serve: `{"op":"task","vm":"golden-slot1-abc","command":"true"}`})
	wsjson.Write(ctx, conn, message{Type: "upload", ID: "2", Data: []byte("PART")})
	eventually(t, "the host to get the task", func() bool { return host.sawRequest("task") })
	conn.Close(websocket.StatusNormalClosure, "")
	eventually(t, "the host to be told to drop the upload", func() bool {
		host.mu.Lock()
		defer host.mu.Unlock()
		return len(host.cancelled) == 1
	})
}

// readAnswer reads the client link until the next answer to id.
func readAnswer(t *testing.T, ctx context.Context, conn *websocket.Conn, id string) message {
	t.Helper()
	for {
		var m message
		if err := wsjson.Read(ctx, conn, &m); err != nil {
			t.Fatalf("waiting for an answer to %s: %v", id, err)
		}
		if m.ID == id {
			return m
		}
	}
}

// A view's input reaches the Mac while it runs, and the Mac's answers come back before the input
// is over: each upload is answered before the next is sent.
func TestAViewCarriesInputUpAndAnswersBackWhileItRuns(t *testing.T) {
	c := newTestControl(t)
	c.startFakeHost(t, "golden", 1)
	c.waitUntilOnline(t, "golden")
	_, conn := c.newClient(t)
	ask(t, conn, message{ID: "1", Op: "acquire"})
	ctx, cancel := contextWithTimeout()
	defer cancel()
	wsjson.Write(ctx, conn, message{Type: "request", ID: "2", Op: "view", Serve: `{"op":"view","vm":"golden-slot1-abc"}`})
	wsjson.Write(ctx, conn, message{Type: "upload", ID: "2", Data: []byte("A")})
	if got := readAnswer(t, ctx, conn, "2"); got.Line != `{"got":"A"}` || got.Done {
		t.Fatalf("first answer %+v", got)
	}
	wsjson.Write(ctx, conn, message{Type: "upload", ID: "2", Data: []byte("B"), Done: true})
	if got := readAnswer(t, ctx, conn, "2"); got.Line != `{"got":"B"}` || got.Done {
		t.Fatalf("second answer %+v", got)
	}
	if got := readAnswer(t, ctx, conn, "2"); got.Line != `{"ended":true}` || !got.Done {
		t.Fatalf("last answer %+v", got)
	}
}

// A client that leaves while its view runs has the view stopped on the Mac.
func TestAViewWhoseClientLeavesIsCancelledOnTheMac(t *testing.T) {
	c := newTestControl(t)
	host := c.startFakeHost(t, "golden", 1)
	c.waitUntilOnline(t, "golden")
	_, conn := c.newClient(t)
	ask(t, conn, message{ID: "1", Op: "acquire"})
	ctx, cancel := contextWithTimeout()
	defer cancel()
	wsjson.Write(ctx, conn, message{Type: "request", ID: "2", Op: "view", Serve: `{"op":"view","vm":"golden-slot1-abc"}`})
	wsjson.Write(ctx, conn, message{Type: "upload", ID: "2", Data: []byte("A")})
	readAnswer(t, ctx, conn, "2")
	conn.Close(websocket.StatusNormalClosure, "")
	eventually(t, "the host to be told to stop the view", func() bool {
		host.mu.Lock()
		defer host.mu.Unlock()
		return len(host.cancelled) == 1
	})
}

// Only the client holding a VM can view it.
func TestAViewOfSomeoneElsesVMIsRefused(t *testing.T) {
	c := newTestControl(t)
	host := c.startFakeHost(t, "golden", 1)
	c.waitUntilOnline(t, "golden")
	_, owner := c.newClient(t)
	ask(t, owner, message{ID: "1", Op: "acquire"})
	_, other := c.newClient(t)
	got := ask(t, other, message{ID: "1", Op: "view", Serve: `{"op":"view","vm":"golden-slot1-abc"}`})
	if !strings.Contains(got[0].Error, "isn't a VM you acquired") || host.sawRequest("view") {
		t.Fatalf("another client's view %+v", got)
	}
}

// A release the Mac never got, as one sent while it was offline, is kept and sent again once the
// Mac reports the VM.
func TestAReleaseTheMacDidntGetIsSentAgainWhenItReports(t *testing.T) {
	c := newTestControl(t)
	key, publicKey := newHostKey(t)
	_, enrolled := c.enroll(t, c.token(t), "studio", publicKey)
	vm := "golden-slot1-abc"
	if err := c.srv.state.addHandout(handout{VM: vm, Host: enrolled.Host, Client: "client-gone", Since: time.Now()}); err != nil {
		t.Fatal(err)
	}
	c.srv.releaseAll("client-gone")
	if h := c.srv.state.handout(vm); h == nil || h.Releasing != "client removed" {
		t.Fatalf("after a release to an offline Mac: %+v", h)
	}

	conn, _, err := c.link(t, enrolled.Host, key)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.CloseNow() })
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	wsjson.Write(ctx, conn, message{Type: "capacity", Slots: []slot{{Number: 1, State: "assigned", VM: vm}}})
	var request message
	if err := wsjson.Read(ctx, conn, &request); err != nil || request.Serve != `{"op":"release","vm":"`+vm+`"}` {
		t.Fatalf("request %+v, %v", request, err)
	}
	if c.srv.state.handout(vm) == nil {
		t.Fatal("the hand-out was forgotten before the Mac answered")
	}
	wsjson.Write(ctx, conn, message{Type: "response", ID: request.ID, Line: `{"vm":"` + vm + `"}`, Done: true})
	eventually(t, "the hand-out to be forgotten", func() bool { return c.srv.state.handout(vm) == nil })
	audited, _ := os.ReadFile(filepath.Join(c.dir, "audit.log"))
	if !strings.Contains(string(audited), `"event":"released","host":"`+enrolled.Host+`","client":"client-gone","vm":"`+vm+`","reason":"client removed"`) {
		t.Fatalf("audit log:\n%s", audited)
	}
}
