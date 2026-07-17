package cdp

import (
	"context"
	"encoding/json"
	"fmt"
)

// Only the methods lens-search.js actually used, as typed wrappers.

// GetTargets lists the browser's targets (pages, workers, …).
func (c *Client) GetTargets(ctx context.Context) ([]TargetInfo, error) {
	var out struct {
		TargetInfos []TargetInfo `json:"targetInfos"`
	}
	err := c.Call(ctx, "", "Target.getTargets", nil, &out)
	return out.TargetInfos, err
}

// CreateTarget opens a new page (tab) and returns its targetId.
func (c *Client) CreateTarget(ctx context.Context, url string) (string, error) {
	var out struct {
		TargetID string `json:"targetId"`
	}
	err := c.Call(ctx, "", "Target.createTarget", map[string]any{"url": url}, &out)
	return out.TargetID, err
}

// AttachToTarget attaches in flatten mode and returns the sessionId used to
// route every subsequent per-page call.
func (c *Client) AttachToTarget(ctx context.Context, targetID string) (string, error) {
	var out struct {
		SessionID string `json:"sessionId"`
	}
	err := c.Call(ctx, "", "Target.attachToTarget",
		map[string]any{"targetId": targetID, "flatten": true}, &out)
	return out.SessionID, err
}

// CloseTarget closes a page.
func (c *Client) CloseTarget(ctx context.Context, targetID string) error {
	return c.Call(ctx, "", "Target.closeTarget", map[string]any{"targetId": targetID}, nil)
}

// EnablePageRuntime turns on the Page + Runtime domains for a session.
func (c *Client) EnablePageRuntime(ctx context.Context, session string) error {
	if err := c.Call(ctx, session, "Page.enable", nil, nil); err != nil {
		return err
	}
	return c.Call(ctx, session, "Runtime.enable", nil, nil)
}

// SetUserAgentOverride applies the UA string + Client Hints metadata.
func (c *Client) SetUserAgentOverride(ctx context.Context, session, ua string, md *UAMetadata) error {
	return c.Call(ctx, session, "Emulation.setUserAgentOverride",
		map[string]any{"userAgent": ua, "userAgentMetadata": md}, nil)
}

// SetViewport sizes the page (headless test mode only — mirrors the old
// page.setViewport(1280, 1200)).
func (c *Client) SetViewport(ctx context.Context, session string, w, h int) error {
	return c.Call(ctx, session, "Emulation.setDeviceMetricsOverride",
		map[string]any{"width": w, "height": h, "deviceScaleFactor": 0, "mobile": false}, nil)
}

// AddScriptOnNewDocument injects source on every future document in the page.
func (c *Client) AddScriptOnNewDocument(ctx context.Context, session, source string) error {
	return c.Call(ctx, session, "Page.addScriptToEvaluateOnNewDocument",
		map[string]any{"source": source}, nil)
}

// Navigate starts a navigation; completion is observed via events.
func (c *Client) Navigate(ctx context.Context, session, url string) error {
	var out struct {
		ErrorText string `json:"errorText"`
	}
	if err := c.Call(ctx, session, "Page.navigate", map[string]any{"url": url}, &out); err != nil {
		return err
	}
	if out.ErrorText != "" {
		return fmt.Errorf("navigate %s: %s", url, out.ErrorText)
	}
	return nil
}

// Evaluate runs an expression. With byValue the JSON value lands in the
// returned RemoteObject.Value; without it you get an ObjectID handle.
// A page-side exception comes back as an error.
func (c *Client) Evaluate(ctx context.Context, session, expr string, byValue bool) (*RemoteObject, error) {
	var out struct {
		Result           RemoteObject    `json:"result"`
		ExceptionDetails json.RawMessage `json:"exceptionDetails"`
	}
	err := c.Call(ctx, session, "Runtime.evaluate",
		map[string]any{"expression": expr, "returnByValue": byValue}, &out)
	if err != nil {
		return nil, err
	}
	if len(out.ExceptionDetails) > 0 {
		return nil, fmt.Errorf("evaluate threw: %s", compactException(out.ExceptionDetails))
	}
	return &out.Result, nil
}

func compactException(raw json.RawMessage) string {
	var d struct {
		Text      string `json:"text"`
		Exception *struct {
			Description string `json:"description"`
		} `json:"exception"`
	}
	if json.Unmarshal(raw, &d) == nil {
		if d.Exception != nil && d.Exception.Description != "" {
			return d.Exception.Description
		}
		if d.Text != "" {
			return d.Text
		}
	}
	return string(raw)
}

// SetFileInputFiles puts local files on an <input type=file>, addressed by
// the RemoteObject handle from Evaluate (CDP also accepts nodeId /
// backendNodeId; the objectId path needs no DOM domain at all).
func (c *Client) SetFileInputFiles(ctx context.Context, session, objectID string, files []string) error {
	return c.Call(ctx, session, "DOM.setFileInputFiles",
		map[string]any{"files": files, "objectId": objectID}, nil)
}

// DispatchMouseEvent sends a trusted mouse event (test harness only — this is
// what puppeteer's page.mouse compiles to).
func (c *Client) DispatchMouseEvent(ctx context.Context, session, typ string, x, y float64, button string, clickCount int) error {
	return c.Call(ctx, session, "Input.dispatchMouseEvent",
		map[string]any{"type": typ, "x": x, "y": y, "button": button, "clickCount": clickCount}, nil)
}

// BrowserClose asks the browser to shut down cleanly (the LENS_ASSIST_CLOSE
// path — Chrome records a Normal exit, so no restore-pages bubble).
func (c *Client) BrowserClose(ctx context.Context) error {
	return c.Call(ctx, "", "Browser.close", nil, nil)
}
