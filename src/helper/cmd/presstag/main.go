// presstag — E2E driver: stand in for the human's Tag/Skip press by setting
// the overlay's page globals over the assist window's debug port, exactly the
// way the lens-live smoke does. This is TEST TOOLING (never shipped in the
// bundle): it lets an automated in-Lightroom E2E prove the run BLOCKS until a
// Tag arrives and then proceeds — the regression class where the assist loop
// stopped waiting for the user.
//
//	go run ./cmd/presstag -port 9334 -tag "Sula nebouxii"   # press Tag
//	go run ./cmd/presstag -port 9334 -skip                  # press Skip
//	go run ./cmd/presstag -port 9334 -peek                  # print page URLs
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/yuvaloren/lightroom-species-tagger/helper/cdp"
)

func die(msg string, err error) {
	if err != nil {
		fmt.Fprintf(os.Stderr, "presstag: %s: %v\n", msg, err)
	} else {
		fmt.Fprintf(os.Stderr, "presstag: %s\n", msg)
	}
	os.Exit(1)
}

func main() {
	port := flag.Int("port", 9334, "assist window debug port (LENS_TABS_PORT)")
	tag := flag.String("tag", "", "species name to press Tag with")
	skip := flag.Bool("skip", false, "press Skip instead")
	peek := flag.Bool("peek", false, "just list page targets")
	flag.Parse()
	if *tag == "" && !*skip && !*peek {
		die("pass -tag <name>, -skip, or -peek", nil)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// browser-level websocket from /json/version (same dial as the helper's own)
	resp, err := http.Get(fmt.Sprintf("http://127.0.0.1:%d/json/version", *port))
	if err != nil {
		die("no assist window on that port", err)
	}
	var v struct {
		WebSocketDebuggerURL string `json:"webSocketDebuggerUrl"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&v); err != nil || v.WebSocketDebuggerURL == "" {
		resp.Body.Close()
		die("no webSocketDebuggerUrl", err)
	}
	resp.Body.Close()
	client, err := cdp.Dial(ctx, v.WebSocketDebuggerURL)
	if err != nil {
		die("dial", err)
	}
	defer client.Close()

	targets, err := client.GetTargets(ctx)
	if err != nil {
		die("Target.getTargets", err)
	}
	if *peek {
		for _, t := range targets {
			if t.Type == "page" {
				fmt.Println(t.TargetID, t.URL)
			}
		}
		return
	}

	// the assist tab is the newest page target — session.go closes all others
	var pageID string
	for _, t := range targets {
		if t.Type == "page" {
			pageID = t.TargetID
		}
	}
	if pageID == "" {
		die("no page target (assist tab not open?)", nil)
	}
	session, err := client.AttachToTarget(ctx, pageID)
	if err != nil {
		die("attach", err)
	}
	// Drive the real overlay buttons, NOT window.__stTag directly: the helper
	// only honours a tag carrying the per-photo nonce, which lives inside the
	// overlay's click handler. So select the name and click #__lens_tag (or
	// click #__lens_skip) — the same path a human takes.
	expr := "(function(){var b=document.getElementById('__lens_skip');if(b)b.click();return !!b;})()"
	if *tag != "" {
		b, _ := json.Marshal(*tag)
		expr = "(function(){var n=" + string(b) + ";" +
			"var el=document.createElement('span');el.textContent=n;el.style.cssText='position:fixed;left:-9999px';document.body.appendChild(el);" +
			"var r=document.createRange();r.selectNodeContents(el);var s=window.getSelection();s.removeAllRanges();s.addRange(r);" +
			"var b=document.getElementById('__lens_tag');if(b)b.click();return !!b;})()"
	}
	obj, err := client.Evaluate(ctx, session, expr, true)
	if err != nil {
		die("evaluate", err)
	}
	if obj != nil && string(obj.Value) == "false" {
		die("overlay button not found on the page (is the assist bar up?)", nil)
	}
	what := "Skip"
	if *tag != "" {
		what = "Tag " + *tag
	}
	fmt.Println("pressed via overlay:", what)
}
