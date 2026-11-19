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
	answers, err := c.srv.forward(ctx, enrolled.Host, `{"op":"exec","vm":"golden-slot1","command":"uname"}`)
	if err != nil {
		t.Fatal(err)
	}
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
	if _, err := c.srv.forward(context.Background(), enrolled.Host, `{"op":"release"}`); err == nil {
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
	answers, err := c.srv.forward(ctx, enrolled.Host, `{"op":"acquire"}`)
	if err != nil {
		t.Fatal(err)
	}
	var request message
	wsjson.Read(ctx, conn, &request)
	conn.Close(websocket.StatusNormalClosure, "")
	got := collect(t, answers)
	if len(got) != 1 || got[0].Error == "" || !got[0].Done {
		t.Fatalf("answers after the link closed: %+v", got)
	}
}
