package cdp

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// stubBrowser is a fake CDP endpoint: every incoming request frame is handed
// to handle, which can send any number of frames back (responses, events, in
// any order — that's the point) or drop() the connection outright.
func stubBrowser(t *testing.T, handle func(req envelope, send func(any), drop func())) string {
	t.Helper()
	var mu sync.Mutex
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		ctx := context.Background()
		send := func(v any) {
			data, _ := json.Marshal(v)
			mu.Lock()
			_ = conn.Write(ctx, websocket.MessageText, data)
			mu.Unlock()
		}
		drop := func() { _ = conn.CloseNow() }
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var req envelope
			if json.Unmarshal(data, &req) != nil {
				continue
			}
			handle(req, send, drop)
		}
	}))
	t.Cleanup(srv.Close)
	return "ws" + strings.TrimPrefix(srv.URL, "http")
}

func dial(t *testing.T, url string) *Client {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, err := Dial(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Close)
	return c
}

func TestCallRoundTrip(t *testing.T) {
	url := stubBrowser(t, func(req envelope, send func(any), _ func()) {
		send(map[string]any{"id": req.ID, "result": map[string]any{"echoed": req.Method}})
	})
	c := dial(t, url)
	var out struct {
		Echoed string `json:"echoed"`
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := c.Call(ctx, "", "Fake.method", map[string]any{"a": 1}, &out); err != nil {
		t.Fatal(err)
	}
	if out.Echoed != "Fake.method" {
		t.Errorf("got %q", out.Echoed)
	}
}

// Responses arriving out of order must land on the right callers — this is
// the demuxer's whole job.
func TestOutOfOrderResponses(t *testing.T) {
	var mu sync.Mutex
	held := []envelope{}
	url := stubBrowser(t, func(req envelope, send func(any), _ func()) {
		mu.Lock()
		held = append(held, req)
		ready := len(held) == 2
		var a, b envelope
		if ready {
			a, b = held[0], held[1]
		}
		mu.Unlock()
		if ready {
			// answer the SECOND request first
			send(map[string]any{"id": b.ID, "result": map[string]any{"who": b.Method}})
			send(map[string]any{"id": a.ID, "result": map[string]any{"who": a.Method}})
		}
	})
	c := dial(t, url)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var wg sync.WaitGroup
	results := make([]string, 2)
	for i, method := range []string{"First.call", "Second.call"} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			var out struct {
				Who string `json:"who"`
			}
			if err := c.Call(ctx, "", method, nil, &out); err != nil {
				t.Errorf("%s: %v", method, err)
				return
			}
			results[i] = out.Who
		}()
		time.Sleep(50 * time.Millisecond) // deterministic arrival order at the stub
	}
	wg.Wait()
	if results[0] != "First.call" || results[1] != "Second.call" {
		t.Errorf("responses crossed: %v", results)
	}
}

// Events interleaved with responses reach subscribers; sessionId routing
// keeps another session's events out; a closed Sub stops delivery.
func TestEventsAndSessionRouting(t *testing.T) {
	url := stubBrowser(t, func(req envelope, send func(any), _ func()) {
		// one event for session s1, one for s2, then the response
		send(map[string]any{"method": "Page.thing", "sessionId": "s1", "params": map[string]any{"n": 1}})
		send(map[string]any{"method": "Page.thing", "sessionId": "s2", "params": map[string]any{"n": 2}})
		send(map[string]any{"id": req.ID, "result": map[string]any{}})
	})
	c := dial(t, url)
	s1 := c.Subscribe("Page.thing", "s1")
	defer s1.Close()
	all := c.Subscribe("Page.thing", "")
	defer all.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := c.Call(ctx, "", "Poke.it", nil, nil); err != nil {
		t.Fatal(err)
	}

	getN := func(raw json.RawMessage) int {
		var p struct {
			N int `json:"n"`
		}
		_ = json.Unmarshal(raw, &p)
		return p.N
	}
	select {
	case ev := <-s1.C:
		if getN(ev) != 1 {
			t.Errorf("s1 got the wrong event: %s", ev)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("s1 event never arrived")
	}
	select {
	case ev := <-s1.C:
		t.Errorf("s1 received a foreign session's event: %s", ev)
	case <-time.After(200 * time.Millisecond):
	}
	// the catch-all sub sees both
	seen := 0
	for seen < 2 {
		select {
		case <-all.C:
			seen++
		case <-time.After(2 * time.Second):
			t.Fatalf("catch-all sub saw %d of 2 events", seen)
		}
	}
}

// A protocol error response surfaces as a Go error with the CDP message.
func TestProtocolError(t *testing.T) {
	url := stubBrowser(t, func(req envelope, send func(any), _ func()) {
		send(map[string]any{"id": req.ID, "error": map[string]any{"code": -32000, "message": "nope"}})
	})
	c := dial(t, url)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	err := c.Call(ctx, "", "Bad.call", nil, nil)
	if err == nil || !strings.Contains(err.Error(), "nope") {
		t.Errorf("want the CDP error message, got %v", err)
	}
}

// A context deadline unblocks the caller and cleans up the pending slot.
func TestCallTimeout(t *testing.T) {
	url := stubBrowser(t, func(req envelope, send func(any), _ func()) { /* never answer */ })
	c := dial(t, url)
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	if err := c.Call(ctx, "", "Never.answers", nil, nil); err == nil {
		t.Fatal("expected a timeout error")
	}
	c.mu.Lock()
	n := len(c.pending)
	c.mu.Unlock()
	if n != 0 {
		t.Errorf("pending map leaked %d entries", n)
	}
}

// When the server drops the connection, in-flight calls error out instead of
// hanging forever, and Done() closes.
func TestConnectionDrop(t *testing.T) {
	url := stubBrowser(t, func(req envelope, send func(any), drop func()) {
		drop() // slam the TCP connection shut with the call still pending
	})
	c := dial(t, url)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := c.Call(ctx, "", "Doomed.call", nil, nil); err == nil {
		t.Fatal("expected an error from the dropped connection")
	}
	select {
	case <-c.Done():
	case <-time.After(2 * time.Second):
		t.Fatal("Done() never closed after the drop")
	}
}
