package lens

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The stdout contract: field set, key order, and truth-table must match the
// Node helper exactly — the Lua side's interpretTagResult depends on it.
func TestResultEncoding(t *testing.T) {
	cases := []struct {
		res  Result
		want string
	}{
		{tagged("Octopus cyanea"), `{"ok":true,"name":"Octopus cyanea"}`},
		{skipped(), `{"ok":false,"cancelled":true}`},
		{fail("no species tagged (timed out waiting for a selection)"),
			`{"ok":false,"error":"no species tagged (timed out waiting for a selection)"}`},
		{Result{OK: true, Closed: true}, `{"ok":true,"closed":true}`},
		{aborted("the Chrome window was closed — run stopped"),
			`{"ok":false,"aborted":true,"error":"the Chrome window was closed — run stopped"}`},
	}
	for _, c := range cases {
		got, err := json.Marshal(c.res)
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != c.want {
			t.Errorf("got %s, want %s", got, c.want)
		}
	}
}

func TestFromEnvDefaults(t *testing.T) {
	for _, k := range []string{"LENS_ASSIST_POS", "LENS_ASSIST_CLOSE",
		"LENS_CACHE_DIR", "LENS_INTERACTIVE_TIMEOUT", "LENS_TEST_URL",
		"LENS_TEST_UPLOAD_URL", "LENS_TEST_HEADLESS", "LENS_DEBUG"} {
		t.Setenv(k, "")
	}
	cfg := FromEnv([]string{"/tmp/photo.jpg"})
	// The default wait is a long backstop, not a working timeout: the user ends a
	// run by tagging/skipping each photo or by CLOSING the window (which aborts).
	// A short default would abort a whole run just because someone pondered one
	// hard ID, so the timeout is generous (30 min) and window-close is the signal.
	if cfg.Img != "/tmp/photo.jpg" || cfg.Close ||
		cfg.Timeout != 1800*time.Second || cfg.TestHeadless || cfg.Debug {
		t.Errorf("defaults wrong: %+v", cfg)
	}
	if !strings.Contains(cfg.CacheDir, "speciestagger-lens") {
		t.Errorf("default cache dir wrong: %s", cfg.CacheDir)
	}
}

func TestFromEnvOverrides(t *testing.T) {
	t.Setenv("LENS_ASSIST_POS", "  Photo 2 of 5  ")
	t.Setenv("LENS_ASSIST_CLOSE", "1")
	t.Setenv("LENS_CACHE_DIR", "/tmp/st-cache")
	t.Setenv("LENS_INTERACTIVE_TIMEOUT", "2500")
	t.Setenv("LENS_TEST_HEADLESS", "1")
	cfg := FromEnv(nil)
	if cfg.Pos != "Photo 2 of 5" { // trimmed, like the JS .trim()
		t.Errorf("pos: %q", cfg.Pos)
	}
	if !cfg.Close || cfg.CacheDir != "/tmp/st-cache" ||
		cfg.Timeout != 2500*time.Millisecond || !cfg.TestHeadless {
		t.Errorf("overrides wrong: %+v", cfg)
	}
	// A garbage timeout falls back to the default (the long 30-min backstop).
	t.Setenv("LENS_INTERACTIVE_TIMEOUT", "banana")
	if cfg = FromEnv(nil); cfg.Timeout != 1800*time.Second {
		t.Errorf("garbage timeout not defaulted: %v", cfg.Timeout)
	}
}

// The injected overlay source must shim `module` (the embedded file ends in a
// CommonJS export that would throw in a browser), then invoke the injector
// with the counter text — the equivalent of evaluateOnNewDocument(fn, pos).
func TestOverlaySource(t *testing.T) {
	src := overlaySource("Photo 2 of 5", "abc123")
	for _, want := range []string{
		"var module={exports:{}}",
		"function assistOverlayInjector(pos, token)",
		`assistOverlayInjector("Photo 2 of 5","abc123");`,
	} {
		if !strings.Contains(src, want) {
			t.Errorf("overlay source missing %q", want)
		}
	}
	if src := overlaySource("", "tok"); !strings.Contains(src, `assistOverlayInjector(null,"tok");`) {
		t.Error("empty pos must inject null, not an empty string")
	}
	// The embedded copy is the real overlay, not a stub.
	if !strings.Contains(overlayJS, "__lens_tag") || !strings.Contains(overlayJS, "preventDefault") {
		t.Error("embedded overlay_inject.js is missing its load-bearing parts")
	}
}

// readDevToolsActivePort is how every invocation finds the reused window —
// Chrome picks its own port and records it here. Partial files (Chrome's write
// is not atomic) and garbage must read as "not ready", never as a bogus port.
func TestReadDevToolsActivePort(t *testing.T) {
	dir := t.TempDir()
	write := func(content string) {
		if err := os.WriteFile(filepath.Join(dir, "DevToolsActivePort"), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := readDevToolsActivePort(dir); err == nil {
		t.Error("missing file must error")
	}
	write("38401\n/devtools/browser/uuid-here\n")
	if p, err := readDevToolsActivePort(dir); err != nil || p != 38401 {
		t.Errorf("valid file: got (%d,%v)", p, err)
	}
	write("38401") // mid-write: port line only, no ws line yet
	if _, err := readDevToolsActivePort(dir); err == nil {
		t.Error("partial (one-line) file must error")
	}
	write("banana\n/devtools/browser/x\n")
	if _, err := readDevToolsActivePort(dir); err == nil {
		t.Error("garbage port must error")
	}
	write("0\n/devtools/browser/x\n")
	if _, err := readDevToolsActivePort(dir); err == nil {
		t.Error("port 0 must error")
	}
	write("38402\r\n/devtools/browser/x\r\n") // CRLF (windows)
	if p, err := readDevToolsActivePort(dir); err != nil || p != 38402 {
		t.Errorf("CRLF file: got (%d,%v)", p, err)
	}
}

// acceptTag is the anti-hijack gate: a Tag counts only when it carries THIS
// photo's nonce. A blind write to window.__stTag from another process on the
// fixed debug port (observed: a stand-in injecting a fixed species name), or a
// stale value from a previous photo, must be rejected. Pure — no browser.
func TestAcceptTag(t *testing.T) {
	const nonce = "9f3ac1"
	ptr := func(s string) *string { return &s }
	cases := []struct {
		name     string
		raw      *string
		nonce    string
		wantName string
		wantOK   bool
	}{
		{"genuine tagged press", ptr(nonce + "|Sula nebouxii"), nonce, "Sula nebouxii", true},
		{"trims surrounding space", ptr(nonce + "|  Sula nebouxii  "), nonce, "Sula nebouxii", true},
		{"name may contain a pipe", ptr(nonce + "|a|b"), nonce, "a|b", true},
		{"blind injection (no nonce) is rejected", ptr("Quercus robur"), nonce, "", false},
		{"wrong nonce is rejected", ptr("deadbeef|Quercus robur"), nonce, "", false},
		{"stale value from a prior photo is rejected", ptr("oldnonce|Old name"), nonce, "", false},
		{"empty name is rejected", ptr(nonce + "|   "), nonce, "", false},
		{"nil (nothing pressed) is rejected", nil, nonce, "", false},
		{"empty nonce never accepts (fail-closed)", ptr("|anything"), "", "", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, ok := acceptTag(c.raw, c.nonce)
			if got != c.wantName || ok != c.wantOK {
				t.Errorf("acceptTag(%v,%q) = (%q,%v), want (%q,%v)", c.raw, c.nonce, got, ok, c.wantName, c.wantOK)
			}
		})
	}
}

// newNonce must be unguessable and unique per call, or the anti-hijack gate is
// worthless.
func TestNewNonce(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 1000; i++ {
		n := newNonce()
		if len(n) != 32 {
			t.Fatalf("nonce %q is not 32 hex chars", n)
		}
		if seen[n] {
			t.Fatalf("nonce collision: %q", n)
		}
		seen[n] = true
	}
}
