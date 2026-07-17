package lens

import (
	"encoding/json"
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
	for _, k := range []string{"LENS_ASSIST_POS", "LENS_ASSIST_CLOSE", "LENS_TABS_PORT",
		"LENS_CACHE_DIR", "LENS_INTERACTIVE_TIMEOUT", "LENS_TEST_URL",
		"LENS_TEST_UPLOAD_URL", "LENS_TEST_HEADLESS", "LENS_DEBUG"} {
		t.Setenv(k, "")
	}
	cfg := FromEnv([]string{"/tmp/photo.jpg"})
	if cfg.Img != "/tmp/photo.jpg" || cfg.Close || cfg.TabsPort != 9333 ||
		cfg.Timeout != 180*time.Second || cfg.TestHeadless || cfg.Debug {
		t.Errorf("defaults wrong: %+v", cfg)
	}
	if !strings.Contains(cfg.CacheDir, "speciestagger-lens") {
		t.Errorf("default cache dir wrong: %s", cfg.CacheDir)
	}
}

func TestFromEnvOverrides(t *testing.T) {
	t.Setenv("LENS_ASSIST_POS", "  Photo 2 of 5  ")
	t.Setenv("LENS_ASSIST_CLOSE", "1")
	t.Setenv("LENS_TABS_PORT", "9477")
	t.Setenv("LENS_CACHE_DIR", "/tmp/st-cache")
	t.Setenv("LENS_INTERACTIVE_TIMEOUT", "2500")
	t.Setenv("LENS_TEST_HEADLESS", "1")
	cfg := FromEnv(nil)
	if cfg.Pos != "Photo 2 of 5" { // trimmed, like the JS .trim()
		t.Errorf("pos: %q", cfg.Pos)
	}
	if !cfg.Close || cfg.TabsPort != 9477 || cfg.CacheDir != "/tmp/st-cache" ||
		cfg.Timeout != 2500*time.Millisecond || !cfg.TestHeadless {
		t.Errorf("overrides wrong: %+v", cfg)
	}
	// A garbage timeout falls back to the default, like parseInt(...) || 180000.
	t.Setenv("LENS_INTERACTIVE_TIMEOUT", "banana")
	if cfg = FromEnv(nil); cfg.Timeout != 180*time.Second {
		t.Errorf("garbage timeout not defaulted: %v", cfg.Timeout)
	}
}

// The injected overlay source must shim `module` (the embedded file ends in a
// CommonJS export that would throw in a browser), then invoke the injector
// with the counter text — the equivalent of evaluateOnNewDocument(fn, pos).
func TestOverlaySource(t *testing.T) {
	src := overlaySource("Photo 2 of 5")
	for _, want := range []string{
		"var module={exports:{}}",
		"function assistOverlayInjector(pos)",
		`assistOverlayInjector("Photo 2 of 5");`,
	} {
		if !strings.Contains(src, want) {
			t.Errorf("overlay source missing %q", want)
		}
	}
	if src := overlaySource(""); !strings.Contains(src, "assistOverlayInjector(null);") {
		t.Error("empty pos must inject null, not an empty string")
	}
	// The embedded copy is the real overlay, not a stub.
	if !strings.Contains(overlayJS, "__lens_tag") || !strings.Contains(overlayJS, "preventDefault") {
		t.Error("embedded overlay_inject.js is missing its load-bearing parts")
	}
}
