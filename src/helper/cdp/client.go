// Package cdp is a minimal Chrome DevTools Protocol client: a WebSocket
// transport, a request/response multiplexer, and an event subscription
// registry. It speaks "flatten" mode — one browser-level socket, per-page
// calls routed by sessionId — which is all the Lens helper needs.
//
// Deliberately NOT chromedp/cdproto: the helper uses ~10 CDP methods (see
// methods.go), and hand-writing them keeps the shipped binary a few MB
// instead of ~15 (generated bindings for all ~50 CDP domains).
package cdp

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"sync"
	"sync/atomic"

	"github.com/coder/websocket"
)

// envelope is the CDP JSON frame, both directions. Responses carry ID+Result/
// Error; events carry Method+Params. SessionID routes per-page traffic in
// flatten mode.
type envelope struct {
	ID        int64           `json:"id,omitempty"`
	Method    string          `json:"method,omitempty"`
	Params    json.RawMessage `json:"params,omitempty"`
	SessionID string          `json:"sessionId,omitempty"`
	Result    json.RawMessage `json:"result,omitempty"`
	Error     *Error          `json:"error,omitempty"`
}

// Error is a CDP protocol-level error response.
type Error struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (e *Error) Error() string { return fmt.Sprintf("cdp: %s (code %d)", e.Message, e.Code) }

type response struct {
	result json.RawMessage
	err    error
}

// Sub is a live subscription to one CDP event method. Events arrive on C as
// raw params JSON. Close it when done; a slow consumer drops events rather
// than blocking the read loop (the events we use are low-rate).
type Sub struct {
	C      chan json.RawMessage
	id     int64
	client *Client
}

// Close unregisters the subscription.
func (s *Sub) Close() {
	s.client.subsMu.Lock()
	delete(s.client.subs, s.id)
	s.client.subsMu.Unlock()
}

type subscription struct {
	method  string
	session string // "" matches any session
	ch      chan json.RawMessage
}

// Client is a connected CDP browser endpoint.
type Client struct {
	conn   *websocket.Conn
	nextID atomic.Int64
	subID  atomic.Int64

	mu      sync.Mutex // guards pending + closed
	pending map[int64]chan response
	closed  bool
	readErr error

	subsMu sync.Mutex
	subs   map[int64]*subscription

	done chan struct{}
}

// Dial connects to a browser's webSocketDebuggerUrl and starts the read loop.
func Dial(ctx context.Context, wsURL string) (*Client, error) {
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		return nil, fmt.Errorf("cdp dial: %w", err)
	}
	// CDP result payloads (DOM dumps, large evaluates) can be big.
	conn.SetReadLimit(64 << 20)
	c := &Client{
		conn:    conn,
		pending: map[int64]chan response{},
		subs:    map[int64]*subscription{},
		done:    make(chan struct{}),
	}
	go c.readLoop()
	return c, nil
}

// Close tears the connection down. In-flight Calls return errors.
func (c *Client) Close() { _ = c.conn.Close(websocket.StatusNormalClosure, "done") }

func (c *Client) readLoop() {
	ctx := context.Background()
	for {
		_, data, err := c.conn.Read(ctx)
		if err != nil {
			c.failAll(err)
			return
		}
		trace("<-", data)
		var env envelope
		if json.Unmarshal(data, &env) != nil {
			continue // not a frame we understand; never kill the loop over it
		}
		if env.ID != 0 && env.Method == "" {
			c.mu.Lock()
			ch := c.pending[env.ID]
			delete(c.pending, env.ID)
			c.mu.Unlock()
			if ch != nil {
				var rerr error
				if env.Error != nil {
					rerr = env.Error
				}
				ch <- response{result: env.Result, err: rerr}
			}
			continue
		}
		if env.Method != "" {
			c.subsMu.Lock()
			for _, s := range c.subs {
				if s.method == env.Method && (s.session == "" || s.session == env.SessionID) {
					select {
					case s.ch <- env.Params:
					default: // drop rather than block the read loop
					}
				}
			}
			c.subsMu.Unlock()
		}
	}
}

func (c *Client) failAll(err error) {
	c.mu.Lock()
	c.closed = true
	c.readErr = err
	for id, ch := range c.pending {
		ch <- response{err: fmt.Errorf("cdp connection closed: %w", err)}
		delete(c.pending, id)
	}
	c.mu.Unlock()
	close(c.done)
}

// Done is closed when the connection dies.
func (c *Client) Done() <-chan struct{} { return c.done }

// Call sends one CDP request and decodes the result into out (out may be
// nil). sessionID "" targets the browser; otherwise the attached page.
func (c *Client) Call(ctx context.Context, sessionID, method string, params, out any) error {
	id := c.nextID.Add(1)
	env := envelope{ID: id, Method: method, SessionID: sessionID}
	if params != nil {
		raw, err := json.Marshal(params)
		if err != nil {
			return fmt.Errorf("cdp %s: marshal params: %w", method, err)
		}
		env.Params = raw
	}
	frame, err := json.Marshal(env)
	if err != nil {
		return err
	}

	ch := make(chan response, 1)
	c.mu.Lock()
	if c.closed {
		err := c.readErr
		c.mu.Unlock()
		return fmt.Errorf("cdp %s: connection closed: %w", method, err)
	}
	c.pending[id] = ch
	c.mu.Unlock()

	trace("->", frame)
	if err := c.conn.Write(ctx, websocket.MessageText, frame); err != nil {
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
		return fmt.Errorf("cdp %s: write: %w", method, err)
	}

	select {
	case <-ctx.Done():
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
		return fmt.Errorf("cdp %s: %w", method, ctx.Err())
	case r := <-ch:
		if r.err != nil {
			return fmt.Errorf("cdp %s: %w", method, r.err)
		}
		if out != nil && len(r.result) > 0 {
			if err := json.Unmarshal(r.result, out); err != nil {
				return fmt.Errorf("cdp %s: decode result: %w", method, err)
			}
		}
		return nil
	}
}

// Subscribe registers for an event method. session "" receives the event from
// any session (browser-level events carry no sessionId at all).
//
// The returned channel is buffered (64) and LOSSY by design: if it fills
// because the consumer is slow, the read loop DROPS further events for this
// sub rather than blocking (see readLoop). Every event we subscribe to is a
// one-shot signal we poll around (load fired, dom content fired), so a dropped
// duplicate is harmless and never blocking the socket is what matters. Do not
// use this for events where every delivery must be observed.
func (c *Client) Subscribe(method, session string) *Sub {
	id := c.subID.Add(1)
	sub := &subscription{method: method, session: session, ch: make(chan json.RawMessage, 64)}
	c.subsMu.Lock()
	c.subs[id] = sub
	c.subsMu.Unlock()
	return &Sub{C: sub.ch, id: id, client: c}
}

// trace dumps raw CDP frames to stderr when LENS_CDP_TRACE=1 — forensics for
// environment-specific protocol hangs (e.g. the macos-latest CI runner).
func trace(dir string, data []byte) {
	if os.Getenv("LENS_CDP_TRACE") == "1" {
		if len(data) > 2000 {
			data = data[:2000]
		}
		fmt.Fprintf(os.Stderr, "CDP %s %s\n", dir, data)
	}
}
