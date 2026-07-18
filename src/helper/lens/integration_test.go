//go:build integration

// Integration harness: drives the REAL compiled helper against a local fake
// Google — no network. Port of the former Node integration test (same
// fixtures, same scenarios A–I + close), PLUS the coverage the Node harness
// never had: the in-browser upload path (T2), an explicit detached-lifecycle
// assertion (T3), and the trusted-click regression test (T4).
//
//	go test -tags integration ./lens/
//
// Needs Chrome/Chromium (LENS_CHROME to point at one explicitly).
package lens

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/yuvaloren/lightroom-species-tagger/helper/cdp"
	"github.com/yuvaloren/lightroom-species-tagger/helper/chrome"
)

var helperBin string

func TestMain(m *testing.M) {
	// Build the real binary once; HELPER_BIN overrides (e.g. to test a
	// cross-compiled artifact or the exact bytes that will ship).
	if helperBin = os.Getenv("HELPER_BIN"); helperBin == "" {
		dir, err := os.MkdirTemp("", "lens-helper-it")
		if err != nil {
			panic(err)
		}
		defer os.RemoveAll(dir)
		helperBin = filepath.Join(dir, "lens-helper")
		if runtime.GOOS == "windows" {
			helperBin += ".exe"
		}
		cmd := exec.Command("go", "build", "-o", helperBin,
			"github.com/yuvaloren/lightroom-species-tagger/helper")
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			panic("building the helper: " + err.Error())
		}
	}
	os.Exit(m.Run())
}

// ---- the fake Google ---------------------------------------------------------

// upload records what the fake upload endpoint received (T2 assertions).
type upload struct {
	body    []byte // the encoded_image part's bytes
	ua      string
	secChUA string
}

type fakeGoogle struct {
	srv     *httptest.Server
	mu      sync.Mutex
	uploads []upload
}

// driver snippets that SIMULATE the human, verbatim from the Node harness.
func selectAndTag(id string) string {
	return "<script>setTimeout(function(){try{" +
		"var el=document.getElementById('" + id + "');" +
		"if(el){var r=document.createRange();r.selectNodeContents(el);var s=window.getSelection();s.removeAllRanges();s.addRange(r);}" +
		"var b=document.getElementById('__lens_tag');if(b)b.click();" +
		"}catch(e){}},1200);</script>"
}

const tagAIOverview = "<script>setTimeout(function(){try{" +
	"var el=[].slice.call(document.querySelectorAll('body *')).find(function(n){return n.children.length===0 && /Antennarius commerson/i.test(n.textContent||'');});" +
	"if(el){var r=document.createRange();r.selectNodeContents(el);var s=window.getSelection();s.removeAllRanges();s.addRange(r);}" +
	"var b=document.getElementById('__lens_tag');if(b)b.click();" +
	"}catch(e){}},1200);</script>"

const emptyTag = "<script>setTimeout(function(){try{" +
	"var s=window.getSelection();if(s)s.removeAllRanges();" +
	"var b=document.getElementById('__lens_tag');if(b)b.click();" +
	"}catch(e){}},1000);</script>"

const clickSkip = "<script>setTimeout(function(){try{var b=document.getElementById('__lens_skip');if(b)b.click();}catch(e){}},1200);</script>"

// blindTag simulates the exploit: a process on the assist window's fixed debug
// port blind-writes window.__stTag with a species name and NO per-photo nonce,
// forging a Tag the user never pressed. (Seen in the wild as a "stand-in"
// binary injecting a fixed name.) The helper must ignore it and keep waiting.
const blindTag = "<script>setTimeout(function(){try{window.__stTag='Quercus robur';}catch(e){}},300);</script>"

func startFakeGoogle(t *testing.T) *fakeGoogle {
	t.Helper()
	f := &fakeGoogle{}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/warmup":
			w.Header().Set("content-type", "text/html; charset=utf-8")
			_, _ = io.WriteString(w, "<!doctype html><title>warmup</title>ok")
			return
		case r.URL.Path == "/v3/upload" && r.Method == "POST":
			// The REAL upload flow lands here: multipart POST, then a 303 to
			// the results page — the exact shape of Lens's public endpoint.
			if err := r.ParseMultipartForm(32 << 20); err != nil {
				http.Error(w, err.Error(), 400)
				return
			}
			file, _, err := r.FormFile("encoded_image")
			if err != nil {
				http.Error(w, "no encoded_image part", 400)
				return
			}
			body, _ := io.ReadAll(file)
			f.mu.Lock()
			f.uploads = append(f.uploads, upload{
				body:    body,
				ua:      r.Header.Get("User-Agent"),
				secChUA: r.Header.Get("Sec-CH-UA"),
			})
			f.mu.Unlock()
			w.Header().Set("Location", "/results?vsrid=test&tag=1")
			w.WriteHeader(http.StatusSeeOther)
			return
		}
		page := "results.html"
		if strings.Contains(r.URL.Path, "challenge") {
			page = "challenge.html"
		}
		html, err := os.ReadFile(filepath.Join("testdata", page))
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		inject := ""
		q := r.URL.Query()
		switch {
		case q.Get("tag") == "1":
			inject = tagAIOverview
		case q.Get("selid") != "":
			id := strings.Map(func(r rune) rune {
				if r == '_' || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
					return r
				}
				return -1
			}, q.Get("selid"))
			inject = selectAndTag(id)
		case q.Get("emptytag") == "1":
			inject = emptyTag
		case q.Get("blindtag") == "1":
			inject = blindTag
		case q.Get("skip") == "1":
			inject = clickSkip
		}
		out := string(html)
		if inject != "" {
			// before the LAST </body>, so an iframe's </body> can't capture it
			if i := strings.LastIndex(out, "</body>"); i >= 0 {
				out = out[:i] + inject + out[i:]
			} else {
				out += inject
			}
		}
		w.Header().Set("content-type", "text/html; charset=utf-8")
		_, _ = io.WriteString(w, out)
	}))
	t.Cleanup(f.srv.Close)
	return f
}

// ---- running the real helper --------------------------------------------------

func runHelper(t *testing.T, port int, cacheDir string, extra map[string]string, img string, killAfter time.Duration) map[string]any {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), killAfter)
	defer cancel()
	cmd := exec.CommandContext(ctx, helperBin, img)
	cmd.Env = append(os.Environ(),
		"LENS_TEST_HEADLESS=1",
		"LENS_DEBUG=1", // stderr shows in -v output — CI forensics
		fmt.Sprintf("LENS_TABS_PORT=%d", port),
		"LENS_CACHE_DIR="+cacheDir,
	)
	for k, v := range extra {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	_ = cmd.Run() // contract: exit 0 either way; the JSON is the truth
	if s := strings.TrimSpace(stderr.String()); s != "" {
		t.Logf("helper stderr: %s", s)
	}
	lines := []string{}
	for _, l := range strings.Split(strings.TrimSpace(stdout.String()), "\n") {
		if strings.TrimSpace(l) != "" {
			lines = append(lines, strings.TrimSpace(l))
		}
	}
	if len(lines) == 0 {
		t.Fatalf("helper produced no stdout; stderr: %s", stderr.String())
	}
	var res map[string]any
	if err := json.Unmarshal([]byte(lines[len(lines)-1]), &res); err != nil {
		t.Fatalf("helper stdout is not one JSON line: %q (stderr: %s)", stdout.String(), stderr.String())
	}
	return res
}

func closeWindow(t *testing.T, port int, cacheDir string) map[string]any {
	t.Helper()
	return runHelper(t, port, cacheDir, map[string]string{"LENS_ASSIST_CLOSE": "1"}, "x", 60*time.Second)
}

func portAnswers(port int) bool {
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 500*time.Millisecond)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}

// waitTrue polls a JS boolean expression until it evaluates truthy, or the
// context deadline hits — a deterministic wait-for-condition (not a fixed
// sleep) for page state that can lag on a slow runner.
func waitTrue(t *testing.T, ctx context.Context, client *cdp.Client, session, expr string) {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		ectx, cancel := context.WithTimeout(ctx, 3*time.Second)
		obj, err := client.Evaluate(ectx, session, expr, true)
		cancel()
		if err == nil && obj != nil && string(obj.Value) == "true" {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("condition never became true: %s", expr)
}

// newCacheDir hands each test an isolated LENS_CACHE_DIR and tears it down
// SAFELY: close the window, wait for the port to go dark, give Chrome a beat
// to finish flushing the profile, then best-effort remove. t.TempDir()'s
// fatal-on-error cleanup races Chrome's async shutdown writes (seen flaking
// on both darwin and linux); a leftover tmp dir is harmless, a red test run
// from a straggling profile write is not.
func newCacheDir(t *testing.T, port int) string {
	dir, err := os.MkdirTemp("", "lens-it-cache")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		closeWindow(t, port, dir)
		removeProfileDir(dir)
	})
	return dir
}

// removeProfileDir deletes a Chrome profile dir WITHOUT racing Chrome's async
// shutdown flush — no sleep-and-hope. On Unix an atomic rename retires the live
// dir in a single syscall (it can't race a concurrent writer and never rmdirs a
// dir still being written into — the no-race rule), then the moved copy is
// deleted best-effort. On Windows an open handle makes both rename and delete
// fail, and the CI runner is ephemeral, so we don't fight the OS — the temp dir
// goes with the runner.
func removeProfileDir(dir string) {
	if runtime.GOOS == "windows" {
		return
	}
	trash := dir + ".trash"
	if os.Rename(dir, trash) == nil {
		_ = os.RemoveAll(trash)
	}
}

func tmpImage(t *testing.T, content string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "lens-it.jpg")
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

// ---- T3: the ten scenarios, one reused window ----------------------------------

func TestScenarios(t *testing.T) {
	f := startFakeGoogle(t)
	const port = 9477
	cache := newCacheDir(t, port) // closes the window + tidies up, race-free
	img := tmpImage(t, "not-a-real-jpeg-just-needs-to-exist")
	base := f.srv.URL

	sel := func(page, selid, expect string) {
		t.Helper()
		r := runHelper(t, port, cache, map[string]string{
			"LENS_TEST_URL":            base + page + "?selid=" + selid,
			"LENS_INTERACTIVE_TIMEOUT": "15000",
		}, img, 150*time.Second)
		if r["ok"] != true || r["name"] != expect {
			t.Errorf("%s#%s: want ok+%q, got %v", page, selid, expect, r)
		}
		if _, scraped := r["strings"]; scraped {
			t.Errorf("%s#%s: scraped payload present: %v", page, selid, r)
		}
	}

	t.Run("A highlight+Tag returns only the selection", func(t *testing.T) {
		r := runHelper(t, port, cache, map[string]string{
			"LENS_TEST_URL":            base + "/results?tag=1",
			"LENS_ASSIST_POS":          "Photo 1 of 3",
			"LENS_INTERACTIVE_TIMEOUT": "15000",
		}, img, 150*time.Second)
		name, _ := r["name"].(string)
		if r["ok"] != true || !strings.Contains(strings.ToLower(name), "antennarius commerson") {
			t.Errorf("got %v", r)
		}
	})
	t.Run("B skip means cancelled, reusing the window", func(t *testing.T) {
		r := runHelper(t, port, cache, map[string]string{
			"LENS_TEST_URL":            base + "/results?skip=1",
			"LENS_INTERACTIVE_TIMEOUT": "15000",
		}, img, 150*time.Second)
		if r["ok"] != false || r["cancelled"] != true {
			t.Errorf("got %v", r)
		}
	})
	t.Run("C timeout is ok=false and NOT cancelled", func(t *testing.T) {
		r := runHelper(t, port, cache, map[string]string{
			"LENS_TEST_URL":            base + "/results",
			"LENS_INTERACTIVE_TIMEOUT": "2500",
		}, img, 150*time.Second)
		if r["ok"] != false || r["cancelled"] == true {
			t.Errorf("got %v", r)
		}
	})
	t.Run("E common name verbatim", func(t *testing.T) {
		sel("/results", "__t_common", "Giant frogfish")
	})
	t.Run("F combined name verbatim incl parenthetical", func(t *testing.T) {
		sel("/results", "__t_combined", "Giant frogfish (Antennarius commerson)")
	})
	t.Run("G curly quotes pass through raw", func(t *testing.T) {
		sel("/results", "__t_curly", "“Randall’s frogfish”")
	})
	t.Run("H empty-selection Tag nudges then times out", func(t *testing.T) {
		r := runHelper(t, port, cache, map[string]string{
			"LENS_TEST_URL":            base + "/results?emptytag=1",
			"LENS_INTERACTIVE_TIMEOUT": "2500",
		}, img, 150*time.Second)
		if r["ok"] != false || r["cancelled"] == true {
			t.Errorf("got %v", r)
		}
	})
	t.Run("I challenge page with iframe tags in the top frame", func(t *testing.T) {
		sel("/challenge", "__t_binomial", "Antennarius commerson")
	})
	t.Run("D close shuts the window down cleanly", func(t *testing.T) {
		if r := closeWindow(t, port, cache); r["ok"] != true {
			t.Errorf("got %v", r)
		}
	})
}

// ---- T2: the upload path the old harness never covered -------------------------

func TestUploadPath(t *testing.T) {
	f := startFakeGoogle(t)
	const port = 9478
	cache := newCacheDir(t, port)
	imgBytes := "definitely-the-photo-bytes-" + strings.Repeat("x", 4096)
	img := tmpImage(t, imgBytes)

	r := runHelper(t, port, cache, map[string]string{
		"LENS_TEST_UPLOAD_URL":     f.srv.URL + "/v3/upload",
		"LENS_INTERACTIVE_TIMEOUT": "15000",
	}, img, 180*time.Second)
	name, _ := r["name"].(string)
	if r["ok"] != true || !strings.Contains(strings.ToLower(name), "antennarius commerson") {
		t.Fatalf("upload flow did not land on a taggable results page: %v", r)
	}

	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.uploads) != 1 {
		t.Fatalf("expected exactly one upload, got %d", len(f.uploads))
	}
	up := f.uploads[0]
	if string(up.body) != imgBytes {
		t.Errorf("uploaded bytes differ from the temp image (%d vs %d bytes)", len(up.body), len(imgBytes))
	}

	// UA override must hold on the upload request itself: real Chrome major,
	// no HeadlessChrome leak. This is the surface real Google keys on.
	ver := chrome.DetectVersion(chrome.Find())
	if strings.Contains(up.ua, "HeadlessChrome") {
		t.Errorf("User-Agent leaks HeadlessChrome: %s", up.ua)
	}
	if !strings.Contains(up.ua, "Chrome/"+ver.Major+".") {
		t.Errorf("User-Agent major (%s) disagrees with installed Chrome %s", up.ua, ver.Major)
	}
	if up.secChUA != "" && !strings.Contains(up.secChUA, `v="`+ver.Major+`"`) {
		t.Errorf("Sec-CH-UA (%s) disagrees with installed Chrome major %s", up.secChUA, ver.Major)
	}
}

// ---- anti-hijack: a blind __stTag write is not a Tag ----------------------------

// The assist window's debug port is fixed and predictable, so any local process
// can connect and blind-write window.__stTag to forge a Tag the user never
// pressed — observed in the wild as a stand-in binary injecting a fixed species
// name, which made the plugin "auto-tag" every photo without ever pausing. The
// per-photo nonce must make such a write a no-op: the run keeps waiting and
// times out, and NEVER returns the injected name.
func TestBlindInjectionIgnored(t *testing.T) {
	f := startFakeGoogle(t)
	const port = 9481
	cache := newCacheDir(t, port)
	img := tmpImage(t, "not-a-real-jpeg-just-needs-to-exist")

	r := runHelper(t, port, cache, map[string]string{
		"LENS_TEST_URL":            f.srv.URL + "/results?blindtag=1",
		"LENS_INTERACTIVE_TIMEOUT": "4000",
	}, img, 150*time.Second)

	if r["ok"] != false || r["cancelled"] == true {
		t.Fatalf("blind window.__stTag injection was accepted as a Tag: %v", r)
	}
	if name, _ := r["name"].(string); strings.Contains(strings.ToLower(name), "quercus") {
		t.Fatalf("helper returned the injected (un-nonced) value: %v", r)
	}
}

// ---- T3: the detached-spawn lifecycle, stated as assertions ---------------------

func TestDetachedLifecycle(t *testing.T) {
	f := startFakeGoogle(t)
	const port = 9479
	cache := newCacheDir(t, port)
	img := tmpImage(t, "x")

	// Helper #1 launches Chrome, times out quickly, and exits...
	r := runHelper(t, port, cache, map[string]string{
		"LENS_TEST_URL":            f.srv.URL + "/results",
		"LENS_INTERACTIVE_TIMEOUT": "1500",
	}, img, 150*time.Second)
	if r["ok"] != false {
		t.Fatalf("scenario setup: %v", r)
	}
	// ...and the DETACHED Chrome must survive the helper's death. If this
	// fails, window reuse across photos is broken (the DETACHED_PROCESS /
	// Setsid risk this plan calls out — especially on Windows).
	if !portAnswers(port) {
		t.Fatal("Chrome died with the helper — detached spawn is broken on " + runtime.GOOS)
	}
	// Helper #2 reuses the same window (fast path: connect, not launch).
	start := time.Now()
	r = runHelper(t, port, cache, map[string]string{
		"LENS_TEST_URL":            f.srv.URL + "/results?skip=1",
		"LENS_INTERACTIVE_TIMEOUT": "15000",
	}, img, 150*time.Second)
	if r["cancelled"] != true {
		t.Fatalf("reuse run: %v", r)
	}
	if time.Since(start) > 15*time.Second {
		t.Errorf("reuse run took %v — did it relaunch instead of reconnect?", time.Since(start))
	}
	// Close ends the window; the port must go dark.
	if r := closeWindow(t, port, cache); r["ok"] != true {
		t.Fatalf("close: %v", r)
	}
	dead := false
	for i := 0; i < 20; i++ {
		if !portAnswers(port) {
			dead = true
			break
		}
		time.Sleep(250 * time.Millisecond)
	}
	if !dead {
		t.Error("window still answering after close")
	}
}

// ---- T4: the trusted-click regression test (port of overlay-selection.test.js) --

// A REAL mouse press on the Tag button must not collapse the user's text
// selection: mousedown moves focus and clears the selection before onclick
// reads it, unless the overlay cancels the mousedown default. This shipped
// broken once — a programmatic .click() (scenarios above) can't catch it;
// only a trusted, CDP-dispatched click does.
func TestTrustedClickPreservesSelection(t *testing.T) {
	const port = 9480
	const name = "Conolophus pallidus"
	cache := newCacheDir(t, port)
	profile := filepath.Join(cache, "chrome-profile-assist")
	if err := os.MkdirAll(profile, 0o755); err != nil {
		t.Fatal(err)
	}
	launch := append([]string{
		fmt.Sprintf("--remote-debugging-port=%d", port),
		"--user-data-dir=" + profile,
		"--no-first-run", "--no-default-browser-check", "--lang=en-US",
	}, headlessTestFlags...)
	launch = append(launch, "about:blank")
	if err := chrome.SpawnDetached(chrome.Find(), launch); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	var client *cdp.Client
	for i := 0; i < 100; i++ {
		time.Sleep(100 * time.Millisecond)
		if c, err := connect(ctx, port); err == nil {
			client = c
			break
		}
	}
	if client == nil {
		t.Fatal("could not reach the test Chrome")
	}
	defer func() {
		cctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		_ = client.BrowserClose(cctx)
		cancel()
		client.Close()
	}()

	session, err := newPage(ctx, client, Config{Debug: true})
	if err != nil {
		t.Fatal(err)
	}
	cctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	if err := client.Navigate(cctx, session,
		"data:text/html,<h2 id=sp>"+name+"</h2><p>some other, unrelated body text</p>"); err != nil {
		t.Fatal(err)
	}
	// Wait deterministically for document.body (data: nav can lag on a slow
	// runner), then inject the REAL embedded overlay (the bytes the helper
	// ships), then wait for its button to exist — no fixed sleep to race.
	waitTrue(t, cctx, client, session, "!!document.body")
	const tok = "trustednonce"
	if _, err := client.Evaluate(cctx, session, overlaySource("", tok), true); err != nil {
		t.Fatal(err)
	}
	waitTrue(t, cctx, client, session, "!!document.getElementById('__lens_tag')")

	// 1. mechanism: the Tag button cancels its mousedown default.
	obj, err := client.Evaluate(cctx, session, `(function(){
		var b = document.getElementById('__lens_tag');
		return !b.dispatchEvent(new MouseEvent('mousedown', {bubbles:true, cancelable:true}));
	})()`, true)
	if err != nil {
		t.Fatal(err)
	}
	if string(obj.Value) != "true" {
		t.Error("mousedown default NOT prevented — a real click will eat the selection")
	}

	// 2. functional: select the name, then a trusted CDP click on Tag.
	if _, err := client.Evaluate(cctx, session, `(function(){
		var el = document.getElementById('sp');
		var r = document.createRange(); r.selectNodeContents(el);
		var s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
	})()`, true); err != nil {
		t.Fatal(err)
	}
	obj, err = client.Evaluate(cctx, session,
		`JSON.stringify(document.getElementById('__lens_tag').getBoundingClientRect())`, true)
	if err != nil {
		t.Fatal(err)
	}
	var rectJSON string
	_ = json.Unmarshal(obj.Value, &rectJSON)
	var rect struct{ X, Y, Width, Height float64 }
	if err := json.Unmarshal([]byte(rectJSON), &rect); err != nil {
		t.Fatalf("rect: %v (%s)", err, rectJSON)
	}
	cx, cy := rect.X+rect.Width/2, rect.Y+rect.Height/2
	if err := client.DispatchMouseEvent(cctx, session, "mousePressed", cx, cy, "left", 1); err != nil {
		t.Fatal(err)
	}
	if err := client.DispatchMouseEvent(cctx, session, "mouseReleased", cx, cy, "left", 1); err != nil {
		t.Fatal(err)
	}
	obj, err = client.Evaluate(cctx, session, "window.__stTag || null", true)
	if err != nil {
		t.Fatal(err)
	}
	var tag string
	_ = json.Unmarshal(obj.Value, &tag)
	// the overlay now writes "<nonce>|<name>" so a blind write can't forge a Tag
	if want := tok + "|" + name; tag != want {
		t.Errorf("trusted click lost the selection: __stTag=%q, want %q", tag, want)
	}
}
