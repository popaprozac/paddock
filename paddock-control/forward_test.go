package main

import (
	"context"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

// collect reads a forwarded request's answers until they end.
func collect(t *testing.T, answers <-chan message) []message {
	t.Helper()
	var got []message
	timeout := time.After(5 * time.Second)
	for {
		select {
		case m, ok := <-answers:
			if !ok {
				return got
			}
			got = append(got, m)
		case <-timeout:
			t.Fatalf("answers didn't end; so far %+v", got)
		}
	}
}

func TestForwardSendsServesLineAndStreamsTheHostsAnswers(t *testing.T) {
	c := newTestControl(t)
	key, publicKey := newHostKey(t)
	_, enrolled := c.enroll(t, c.token(t), "studio", publicKey)
	conn, _, err := c.link(t, enrolled.Host, key)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()
	ctx, cancel := contextWithTimeout()
	defer cancel()
	answers, cancelForward, err := c.srv.forward(ctx, enrolled.Host, `{"op":"exec","vm":"golden-slot1","command":"uname"}`)
	if err != nil {
		t.Fatal(err)
	}
	defer cancelForward()
	var request message
	if err := wsjson.Read(ctx, conn, &request); err != nil {
		t.Fatal(err)
	}
	if request.Type != "request" || request.ID == "" || request.Serve != `{"op":"exec","vm":"golden-slot1","command":"uname"}` {
		t.Fatalf("request %+v", request)
	}
	wsjson.Write(ctx, conn, message{Type: "response", ID: request.ID, Line: `{"output":"Darwin"}`})
	wsjson.Write(ctx, conn, message{Type: "response", ID: "r999", Line: `{"output":"for no one"}`})
	wsjson.Write(ctx, conn, message{Type: "response", ID: request.ID, Line: `{"exit":0}`, Done: true})
	got := collect(t, answers)
	if len(got) != 2 || got[0].Line != `{"output":"Darwin"}` || got[1].Line != `{"exit":0}` || !got[1].Done {
		t.Fatalf("answers %+v", got)
	}
}

func TestForwardToAHostThatIsntOnlineFails(t *testing.T) {
	c := newTestControl(t)
	_, publicKey := newHostKey(t)
	_, enrolled := c.enroll(t, c.token(t), "studio", publicKey)
	if _, _, err := c.srv.forward(context.Background(), enrolled.Host, `{"op":"release"}`); err == nil {
		t.Fatal("forwarded to a host with no link")
	}
}

func TestALinkThatClosesEndsItsRequestsWithAnError(t *testing.T) {
	c := newTestControl(t)
	key, publicKey := newHostKey(t)
	_, enrolled := c.enroll(t, c.token(t), "studio", publicKey)
	conn, _, err := c.link(t, enrolled.Host, key)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := contextWithTimeout()
	defer cancel()
	answers, cancelForward, err := c.srv.forward(ctx, enrolled.Host, `{"op":"acquire"}`)
	if err != nil {
		t.Fatal(err)
	}
	defer cancelForward()
	var request message
	wsjson.Read(ctx, conn, &request)
	conn.Close(websocket.StatusNormalClosure, "")
	got := collect(t, answers)
	if len(got) != 1 || got[0].Error == "" || !got[0].Done {
		t.Fatalf("answers after the link closed: %+v", got)
	}
}

// A request whose reader went away must not hold up the host's other requests.
func TestAnAbandonedRequestDoesntBlockTheHostsLink(t *testing.T) {
	c := newTestControl(t)
	key, publicKey := newHostKey(t)
	_, enrolled := c.enroll(t, c.token(t), "studio", publicKey)
	conn, _, err := c.link(t, enrolled.Host, key)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()
	ctx, cancel := contextWithTimeout()
	defer cancel()
	_, abandon, err := c.srv.forward(ctx, enrolled.Host, `{"op":"axtree","vm":"v"}`)
	if err != nil {
		t.Fatal(err)
	}
	var first message
	wsjson.Read(ctx, conn, &first)
	abandon()
	// Far more answers than the buffer holds, for a request nobody reads any more.
	for i := 0; i < answersBuffer*2; i++ {
		wsjson.Write(ctx, conn, message{Type: "response", ID: first.ID, Line: `{"output":"x"}`})
	}
	answers, done, err := c.srv.forward(ctx, enrolled.Host, `{"op":"input","vm":"v"}`)
	if err != nil {
		t.Fatal(err)
	}
	defer done()
	var second message
	wsjson.Read(ctx, conn, &second)
	wsjson.Write(ctx, conn, message{Type: "response", ID: second.ID, Line: `{"exit":0}`, Done: true})
	if got := collect(t, answers); len(got) != 1 || got[0].Line != `{"exit":0}` {
		t.Fatalf("the next request's answers: %+v", got)
	}
}

// A client slow to read its answers still hears that the link closed, after the answers it was
// already sent, and doesn't wait for more.
func TestARequestWhoseAnswersAreBackedUpStillHearsTheLinkClose(t *testing.T) {
	p := &pendingRequest{answers: make(chan message, 1), gone: make(chan struct{})}
	p.answers <- message{Type: "response", Line: "first"}
	l := &link{pending: map[string]*pendingRequest{"r1": p}}
	go l.failPending()
	eventually(t, "the link to close", func() bool {
		l.mu.Lock()
		defer l.mu.Unlock()
		return l.closed
	})
	time.Sleep(50 * time.Millisecond) // failPending meets the full buffer before anyone reads
	got := collect(t, p.answers)
	if len(got) != 2 || got[0].Line != "first" || got[1].Error == "" || !got[1].Done {
		t.Fatalf("answers %+v", got)
	}
}
