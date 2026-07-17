// Package lens orchestrates one assist run: connect to (or launch) the reused
// visible Chrome window, upload the photo to Google Lens INSIDE that browser
// session, inject the Tag/Skip bar, and poll for the user's highlighted name.
// Direct port of scripts/lens/lens-search.js — same env contract, same
// one-JSON-line stdout contract, same error strings.
package lens

import (
	"context"
	_ "embed"
	"encoding/json"
	"fmt"
	"net/http"
	neturl "net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/yuvaloren/lightroom-species-tagger/helper/cdp"
	"github.com/yuvaloren/lightroom-species-tagger/helper/chrome"
)

// overlayJS is the assistive control bar, byte-identical to the old
// scripts/lens/overlay-inject.js (single source of truth — the trusted-click
// regression test drives THIS copy). It declares assistOverlayInjector(pos)
// and ends with a CommonJS export, so injection wraps it in an IIFE with a
// local `module` shim.
//
//go:embed overlay_inject.js
var overlayJS string

// headlessTestFlags launch Chrome headless for the test suites ONLY. On CI
// hardware with no usable GPU the RENDERER crashes on graphics init — the
// macos-latest runner returned Inspector.detached "Render process gone." the
// instant a page attached, which made Page.enable hang until timeout (a real
// Mac with a GPU passes without any of this).
//
// --disable-gpu alone did NOT stop it there: it disables the GPU *process*, so
// the renderer falls back to a software path that still crashed on that
// runner. The working approach is the opposite — KEEP the GPU process but make
// it render through the bundled SwiftShader (software) backend via
// --use-gl=angle + --use-angle=swiftshader, so graphics init never touches
// Metal. The two are mutually exclusive (--disable-gpu would kill the very
// process SwiftShader runs in), so --disable-gpu is intentionally absent.
//
// Production never uses this path — the user's window is headed with a real
// GPU — so none of this can affect real use.
var headlessTestFlags = []string{
	"--headless=new",
	"--no-sandbox",
	"--disable-dev-shm-usage",
	"--use-gl=angle",
	"--use-angle=swiftshader",
}

// Config is the env contract, unchanged from the Node helper (plus
// LENS_TEST_UPLOAD_URL, which exists so the integration tests can exercise
// the REAL upload path against a local endpoint — the one flow LENS_TEST_URL
// skips entirely).
type Config struct {
	Img          string
	Pos          string // LENS_ASSIST_POS: "Photo 2 of 5"
	Close        bool   // LENS_ASSIST_CLOSE=1
	TabsPort     int    // LENS_TABS_PORT (default 9333)
	CacheDir     string // LENS_CACHE_DIR (default ~/.cache/speciestagger-lens)
	Timeout      time.Duration
	TestURL      string // LENS_TEST_URL: skip upload, go straight here
	TestUpload   string // LENS_TEST_UPLOAD_URL: real upload flow, fake endpoint
	TestHeadless bool   // LENS_TEST_HEADLESS=1 (the ONLY headless path; tests)
	Debug        bool
}

// FromEnv builds the config the way lens-search.js read process.env/argv.
func FromEnv(args []string) Config {
	cfg := Config{
		Pos:          strings.TrimSpace(os.Getenv("LENS_ASSIST_POS")),
		Close:        os.Getenv("LENS_ASSIST_CLOSE") == "1",
		TabsPort:     9333,
		Timeout:      180 * time.Second,
		TestURL:      os.Getenv("LENS_TEST_URL"),
		TestUpload:   os.Getenv("LENS_TEST_UPLOAD_URL"),
		TestHeadless: os.Getenv("LENS_TEST_HEADLESS") == "1",
		Debug:        os.Getenv("LENS_DEBUG") == "1",
	}
	if len(args) > 0 {
		cfg.Img = args[0]
	}
	if p, err := strconv.Atoi(os.Getenv("LENS_TABS_PORT")); err == nil && p > 0 {
		cfg.TabsPort = p
	}
	if ms, err := strconv.Atoi(os.Getenv("LENS_INTERACTIVE_TIMEOUT")); err == nil && ms > 0 {
		cfg.Timeout = time.Duration(ms) * time.Millisecond
	}
	cfg.CacheDir = os.Getenv("LENS_CACHE_DIR")
	if cfg.CacheDir == "" {
		home, _ := os.UserHomeDir()
		cfg.CacheDir = filepath.Join(home, ".cache", "speciestagger-lens")
	}
	return cfg
}

// Result is the single stdout line. Field set and truth-table match the Node
// helper exactly (the Lua side's interpretTagResult depends on it).
type Result struct {
	OK        bool   `json:"ok"`
	Name      string `json:"name,omitempty"`
	Cancelled bool   `json:"cancelled,omitempty"`
	Closed    bool   `json:"closed,omitempty"`
	Error     string `json:"error,omitempty"`
}

func fail(msg string) Result { return Result{OK: false, Error: msg} }
func skipped() Result        { return Result{OK: false, Cancelled: true} }
func tagged(n string) Result { return Result{OK: true, Name: n} }

func (c Config) dbg(a ...any) {
	if c.Debug {
		fmt.Fprintln(os.Stderr, append([]any{"DEBUG"}, a...)...)
	}
}

// Run executes one helper invocation and returns the Result to print.
func Run(cfg Config) Result {
	ctx := context.Background()

	// Close command: connect to the reuse window and shut it down cleanly.
	if cfg.Close {
		if client, _ := connect(ctx, cfg.TabsPort); client != nil {
			cctx, cancel := context.WithTimeout(ctx, 30*time.Second)
			_ = client.BrowserClose(cctx)
			cancel()
			client.Close()
		}
		return Result{OK: true, Closed: true}
	}

	if cfg.Img == "" || (cfg.TestURL == "" && !fileExists(cfg.Img)) {
		return fail("image not found: " + cfg.Img)
	}

	client, err := connectOrLaunch(ctx, cfg)
	if err != nil {
		return fail("assist failed: " + err.Error())
	}
	defer client.Close() // disconnect only — never kills the reused window

	session, err := newPage(ctx, client, cfg)
	if err != nil {
		return fail("assist failed: " + err.Error())
	}
	if err := prepPage(ctx, client, session, cfg); err != nil {
		return fail("assist failed: " + err.Error())
	}

	if cfg.TestURL != "" {
		// Test mode: skip the upload, drive the overlay against a local page.
		goTo(ctx, client, session, cfg.TestURL, 45*time.Second)
	} else if err := uploadInBrowser(ctx, client, session, cfg); err != nil {
		return fail(err.Error())
	}

	outcome, name := waitForTag(ctx, client, session, cfg)
	cfg.dbg("assist outcome:", outcome, name)
	switch outcome {
	case "tag":
		return tagged(name)
	case "skip":
		return skipped()
	default:
		return fail("no species tagged (timed out waiting for a selection)")
	}
}

func fileExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}

// connect tries the browser endpoint on port; nil client when nothing answers.
func connect(ctx context.Context, port int) (*cdp.Client, error) {
	hctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(hctx, "GET",
		fmt.Sprintf("http://127.0.0.1:%d/json/version", port), nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var v struct {
		WebSocketDebuggerURL string `json:"webSocketDebuggerUrl"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&v); err != nil || v.WebSocketDebuggerURL == "" {
		return nil, fmt.Errorf("no webSocketDebuggerUrl on port %d", port)
	}
	dctx, dcancel := context.WithTimeout(ctx, 15*time.Second)
	defer dcancel()
	return cdp.Dial(dctx, v.WebSocketDebuggerURL)
}

// connectOrLaunch mirrors connectWindow(true): reuse the window on TABS_PORT,
// or launch a detached one and poll it up (100 × 100 ms).
func connectOrLaunch(ctx context.Context, cfg Config) (*cdp.Client, error) {
	if client, _ := connect(ctx, cfg.TabsPort); client != nil {
		return client, nil
	}
	profile := filepath.Join(cfg.CacheDir, "chrome-profile-assist")
	_ = os.MkdirAll(profile, 0o755)
	chrome.MarkProfileClean(profile) // never nag about a previous unclean exit
	chromePath := chrome.Find()
	args := []string{
		"--remote-debugging-port=" + strconv.Itoa(cfg.TabsPort),
		"--user-data-dir=" + profile,
		"--no-first-run", "--no-default-browser-check", "--lang=en-US",
	}
	if cfg.TestHeadless {
		args = append(args, headlessTestFlags...)
	} else {
		args = append(args, "--window-size=1280,960")
	}
	args = append(args, "about:blank")
	if err := chrome.SpawnDetached(chromePath, args); err != nil {
		return nil, fmt.Errorf("could not start the assist Chrome window (port %d): %s", cfg.TabsPort, err)
	}
	for i := 0; i < 100; i++ {
		time.Sleep(100 * time.Millisecond)
		if client, _ := connect(ctx, cfg.TabsPort); client != nil {
			return client, nil
		}
	}
	return nil, fmt.Errorf("could not start the assist Chrome window (port %d)", cfg.TabsPort)
}

// newPage opens a fresh tab for this photo and closes the others, so there is
// a single visible tab and the overlay's addScriptToEvaluateOnNewDocument
// can't accumulate across photos.
func newPage(ctx context.Context, client *cdp.Client, cfg Config) (string, error) {
	// Generous budget: this guards against a hung browser, not slowness —
	// puppeteer's default protocol timeout was 180 s, and CI's shared mac
	// runners have shown 15 s to be too tight for real page creation.
	cctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	targetID, err := client.CreateTarget(cctx, "about:blank")
	if err != nil {
		return "", err
	}
	cfg.dbg("created target:", targetID)
	session, err := client.AttachToTarget(cctx, targetID)
	if err != nil {
		return "", err
	}
	cfg.dbg("attached session:", session)
	if err := client.EnablePageRuntime(cctx, session); err != nil {
		return "", err
	}
	targets, err := client.GetTargets(cctx)
	if err == nil {
		for _, t := range targets {
			if t.Type == "page" && t.TargetID != targetID {
				_ = client.CloseTarget(cctx, t.TargetID) // best-effort, like p.close().catch
			}
		}
	}
	return session, nil
}

func prepPage(ctx context.Context, client *cdp.Client, session string, cfg Config) error {
	cctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	ver := chrome.DetectVersion(chrome.Find())
	ua, md := UserAgentFor(goos(), goarch(), ver)
	if err := client.SetUserAgentOverride(cctx, session, ua, md); err != nil {
		return err
	}
	if cfg.TestHeadless {
		if err := client.SetViewport(cctx, session, 1280, 1200); err != nil {
			return err
		}
	}
	return client.AddScriptOnNewDocument(cctx, session, overlaySource(cfg.Pos))
}

// overlaySource wraps the embedded overlay file in an IIFE with a `module`
// shim (the file ends in a CommonJS export) and invokes it with pos — the
// exact equivalent of page.evaluateOnNewDocument(assistOverlayInjector, pos).
func overlaySource(pos string) string {
	posJSON := "null"
	if pos != "" {
		b, _ := json.Marshal(pos)
		posJSON = string(b)
	}
	return "(function(){var module={exports:{}};\n" + overlayJS + "\nassistOverlayInjector(" + posJSON + ");})();"
}

// goTo navigates and waits (bounded) for DOMContentLoaded; navigation errors
// and timeouts are swallowed exactly like the JS `.catch(() => {})` — the
// caller decides success from the page state, not the navigation promise.
func goTo(ctx context.Context, client *cdp.Client, session, url string, timeout time.Duration) {
	sub := client.Subscribe("Page.domContentEventFired", session)
	defer sub.Close()
	nctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	err := client.Navigate(nctx, session, url)
	cancel()
	if err != nil {
		return
	}
	select {
	case <-sub.C:
	case <-time.After(timeout):
	case <-client.Done():
	}
}

var vsridRe = regexp.MustCompile(`[?&]vsrid=`)

// uploadInBrowser uploads the image INSIDE the visible Chrome — the same
// session that then views the results. Build our OWN tiny form (createElement
// only, never innerHTML) posting to the public endpoint the website uses, put
// the file on it via CDP, and submit as a top-level navigation. No scraping —
// we still read only the user's selection afterwards.
func uploadInBrowser(ctx context.Context, client *cdp.Client, session string, cfg Config) error {
	// Warm up on google.com in the persistent profile so the upload runs
	// inside an ordinary session (cookies are .google.com-wide). No fabricated
	// consent cookie: a consent screen is handled by the user in the visible
	// window and the profile remembers it thereafter. In test-upload mode the
	// warm-up goes to the fake server's origin instead, so the FULL flow —
	// navigate, build form, attach file, submit, nav-wait, vsrid check — runs
	// hermetically.
	warm := "https://www.google.com/"
	if cfg.TestUpload != "" {
		if u, err := neturl.Parse(cfg.TestUpload); err == nil {
			u.Path, u.RawQuery = "/warmup", ""
			warm = u.String()
		}
	}
	goTo(ctx, client, session, warm, 45*time.Second)

	cctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	action := "'https://lens.google.com/v3/upload?ep=gsbubb&authuser=0&hl=en&st='+Date.now()"
	if cfg.TestUpload != "" {
		b, _ := json.Marshal(cfg.TestUpload)
		action = string(b)
	}
	buildForm := `(function(){
  var f = document.createElement('form');
  f.id = '__stUploadForm';
  f.method = 'POST';
  f.enctype = 'multipart/form-data';
  f.action = ` + action + `;
  var i = document.createElement('input');
  i.type = 'file';
  i.name = 'encoded_image';
  i.id = '__stUploadFile';
  f.appendChild(i);
  document.documentElement.appendChild(f);
})()`
	if _, err := client.Evaluate(cctx, session, buildForm, true); err != nil {
		return fmt.Errorf("could not build the Lens upload form")
	}
	input, err := client.Evaluate(cctx, session, "document.getElementById('__stUploadFile')", false)
	if err != nil || input.ObjectID == "" {
		return fmt.Errorf("could not build the Lens upload form")
	}
	abs, err := filepath.Abs(cfg.Img)
	if err != nil {
		abs = cfg.Img
	}
	if err := client.SetFileInputFiles(cctx, session, input.ObjectID, []string{abs}); err != nil {
		return fmt.Errorf("could not build the Lens upload form")
	}

	// Submit + wait for the results navigation (mirrors the JS Promise.all of
	// waitForNavigation(domcontentloaded, 60s).catch + form.submit()).
	sub := client.Subscribe("Page.domContentEventFired", session)
	if _, err := client.Evaluate(cctx, session,
		"document.getElementById('__stUploadForm').submit()", true); err != nil {
		sub.Close()
		return fmt.Errorf("could not build the Lens upload form")
	}
	select {
	case <-sub.C:
	case <-time.After(60 * time.Second):
	case <-client.Done():
	}
	sub.Close()

	landed := currentURL(ctx, client, session, cfg)
	cfg.dbg("in-browser upload landed on:", landed)
	if !vsridRe.MatchString(landed) {
		return fmt.Errorf("upload rejected (no results URL) — landed on %s", landed)
	}
	return nil
}

// currentURL reads location.href, retrying briefly across the mid-navigation
// window where the execution context is being swapped out.
func currentURL(ctx context.Context, client *cdp.Client, session string, cfg Config) string {
	for i := 0; i < 10; i++ {
		cctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		obj, err := client.Evaluate(cctx, session, "location.href", true)
		cancel()
		if err == nil && obj != nil {
			var href string
			if json.Unmarshal(obj.Value, &href) == nil && href != "" {
				return href
			}
		}
		time.Sleep(300 * time.Millisecond)
	}
	return ""
}

// waitForTag polls the page for the user's Tag (window.__stTag) or Skip
// (window.__stSkip), or times out. Polling page globals — not exposeFunction —
// is what lets the helper reconnect to a reused window across photos.
func waitForTag(ctx context.Context, client *cdp.Client, session string, cfg Config) (string, string) {
	deadline := time.Now().Add(cfg.Timeout)
	for time.Now().Before(deadline) {
		cctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		obj, err := client.Evaluate(cctx, session,
			"({tag: window.__stTag || null, skip: !!window.__stSkip})", true)
		cancel()
		if err == nil && obj != nil {
			var s struct {
				Tag  *string `json:"tag"`
				Skip bool    `json:"skip"`
			}
			if json.Unmarshal(obj.Value, &s) == nil {
				if s.Tag != nil && strings.TrimSpace(*s.Tag) != "" {
					return "tag", strings.TrimSpace(*s.Tag)
				}
				if s.Skip {
					return "skip", ""
				}
			}
		}
		// mid-navigation evaluate errors: just try again, like the JS catch
		select {
		case <-client.Done():
			return "timeout", ""
		case <-time.After(300 * time.Millisecond):
		}
	}
	return "timeout", ""
}
