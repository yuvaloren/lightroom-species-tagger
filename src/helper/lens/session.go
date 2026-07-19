// Package lens orchestrates one assist run: connect to (or launch) the reused
// visible Chrome window, upload the photo to Google Lens INSIDE that browser
// session, inject the Tag/Skip bar, and poll for the user's highlighted name.
// Direct port of the former Node lens helper — same env contract, same
// one-JSON-line stdout contract, same error strings.
package lens

import (
	"context"
	"crypto/rand"
	_ "embed"
	"encoding/hex"
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
// overlay_inject.js (single source of truth — the trusted-click
// regression test drives THIS copy). It declares assistOverlayInjector(pos)
// and ends with a CommonJS export, so injection wraps it in an IIFE with a
// local `module` shim.
//
//go:embed overlay_inject.js
var overlayJS string

// headlessTestFlags launch Chrome headless for the test suites ONLY — the
// standard CI-headless set (no GPU, no /dev/shm dependence, no sandbox).
// Production never uses this path; the user's window is headed with a real GPU.
var headlessTestFlags = []string{
	"--headless=new",
	"--no-sandbox",
	"--disable-gpu",
	"--disable-dev-shm-usage",
}

// Config is the env contract, unchanged from the Node helper (plus
// LENS_TEST_UPLOAD_URL, which exists so the integration tests can exercise
// the REAL upload path against a local endpoint — the one flow LENS_TEST_URL
// skips entirely).
type Config struct {
	Img   string
	Pos   string // LENS_ASSIST_POS: "Photo 2 of 5"
	Close bool   // LENS_ASSIST_CLOSE=1
	// CacheDir is the rendezvous for the reused window: Chrome picks its OWN
	// debug port (--remote-debugging-port=0) and records it in
	// <CacheDir>/chrome-profile-assist/DevToolsActivePort; every invocation
	// discovers the window from that file. No fixed port: a well-known port
	// can be squatted (blocking the launch) or spoofed (a fake window).
	CacheDir string // LENS_CACHE_DIR (default ~/.cache/speciestagger-lens)
	// Timeout bounds the interactive wait for the user's Tag/Skip. 0 (the
	// production default) means wait INDEFINITELY — a run can sit unattended for
	// hours and must never abort on a timer. LENS_INTERACTIVE_TIMEOUT sets a
	// positive bound; the test suites use it to keep "never decides" cases short.
	Timeout      time.Duration
	TestURL      string // LENS_TEST_URL: skip upload, go straight here
	TestUpload   string // LENS_TEST_UPLOAD_URL: real upload flow, fake endpoint
	TestHeadless bool   // LENS_TEST_HEADLESS=1 (the ONLY headless path; tests)
	Debug        bool
}

// FromEnv builds the config the way lens-search.js read process.env/argv.
func FromEnv(args []string) Config {
	cfg := Config{
		Pos:   strings.TrimSpace(os.Getenv("LENS_ASSIST_POS")),
		Close: os.Getenv("LENS_ASSIST_CLOSE") == "1",
		// No interactive timeout by default (0 = wait indefinitely): a run ends
		// when the user tags/skips every photo or CLOSES the window (which aborts).
		// A run may be left unattended for hours, so it must never give up on a
		// timer. LENS_INTERACTIVE_TIMEOUT (below) sets a positive bound if wanted.
		Timeout:      0,
		TestURL:      os.Getenv("LENS_TEST_URL"),
		TestUpload:   os.Getenv("LENS_TEST_UPLOAD_URL"),
		TestHeadless: os.Getenv("LENS_TEST_HEADLESS") == "1",
		Debug:        os.Getenv("LENS_DEBUG") == "1",
	}
	if len(args) > 0 {
		cfg.Img = args[0]
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
	// Aborted marks a run that STOPPED because no decision was made on this photo
	// — the user closed the Chrome window, or the (long) wait timed out. Distinct
	// from Cancelled (a Skip, which advances) and from Closed (the close command's
	// own success). The Lua side turns this into LENS_ABORTED and halts the run.
	Aborted bool   `json:"aborted,omitempty"`
	Error   string `json:"error,omitempty"`
}

func fail(msg string) Result    { return Result{OK: false, Error: msg} }
func skipped() Result           { return Result{OK: false, Cancelled: true} }
func aborted(msg string) Result { return Result{OK: false, Aborted: true, Error: msg} }
func tagged(n string) Result    { return Result{OK: true, Name: n} }

func (c Config) dbg(a ...any) {
	if c.Debug {
		fmt.Fprintln(os.Stderr, append([]any{"DEBUG"}, a...)...)
	}
}

// Run executes one helper invocation and returns the Result to print.
func Run(cfg Config) Result {
	ctx := context.Background()

	// Close command: discover the reuse window from the profile and shut it
	// down cleanly. No window (no file, dead port) means nothing to close.
	if cfg.Close {
		if port, err := readDevToolsActivePort(profileDir(cfg)); err == nil {
			if client, _ := connect(ctx, port); client != nil {
				cctx, cancel := context.WithTimeout(ctx, 30*time.Second)
				_ = client.BrowserClose(cctx)
				cancel()
				client.Close()
			}
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

	session, targetID, err := newPage(ctx, client, cfg)
	if err != nil {
		return fail("assist failed: " + err.Error())
	}
	// Per-photo nonce: the overlay tags as "<nonce>|<name>", and waitForTag
	// accepts a Tag only when the nonce matches. The assist window's debug port
	// is fixed and predictable, so a local process can connect and blind-write
	// window.__stTag to forge a Tag (seen in the wild); without the nonce that
	// forged value would be accepted and the plugin would "auto-tag" without ever
	// waiting for the user. The nonce is minted here and injected into the page,
	// so a blind writer can't produce it.
	nonce := newNonce()
	if err := prepPage(ctx, client, session, cfg, nonce); err != nil {
		return fail("assist failed: " + err.Error())
	}

	if cfg.TestURL != "" {
		// Test mode: skip the upload, drive the overlay against a local page.
		goTo(ctx, client, session, cfg.TestURL, 45*time.Second)
	} else if err := uploadInBrowser(ctx, client, session, cfg); err != nil {
		return fail(err.Error())
	}

	outcome, name := waitForTag(ctx, client, session, targetID, cfg, nonce)
	cfg.dbg("assist outcome:", outcome, name)
	switch outcome {
	case "tag":
		return tagged(name)
	case "skip":
		return skipped()
	case "closed":
		// The user closed the Chrome window mid-run: abort, don't advance.
		return aborted("the Chrome window was closed — run stopped")
	default: // "timeout"
		return aborted("timed out waiting for a selection — run stopped")
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

// profileDir is the reused assist window's user-data-dir — the rendezvous
// every invocation shares.
func profileDir(cfg Config) string {
	return filepath.Join(cfg.CacheDir, "chrome-profile-assist")
}

// readDevToolsActivePort parses <profile>/DevToolsActivePort, the file Chrome
// writes once its DevTools server is listening: line 1 is the port, line 2 the
// browser websocket path. Chrome's write is not atomic, so a partial file (no
// second line yet) is an error — callers poll until it parses. Pure enough to
// unit-test with a temp dir.
func readDevToolsActivePort(profile string) (int, error) {
	raw, err := os.ReadFile(filepath.Join(profile, "DevToolsActivePort"))
	if err != nil {
		return 0, err
	}
	lines := strings.Split(strings.ReplaceAll(string(raw), "\r\n", "\n"), "\n")
	if len(lines) < 2 || strings.TrimSpace(lines[1]) == "" {
		return 0, fmt.Errorf("DevToolsActivePort incomplete (mid-write?)")
	}
	port, err := strconv.Atoi(strings.TrimSpace(lines[0]))
	if err != nil || port <= 0 {
		return 0, fmt.Errorf("DevToolsActivePort has no valid port: %q", lines[0])
	}
	return port, nil
}

// connectOrLaunch reuses the assist window recorded in the profile's
// DevToolsActivePort file, or launches a detached one and polls the file up
// (100 × 100 ms). Chrome picks its own free port (--remote-debugging-port=0):
// a fixed well-known port could be squatted by another process — blocking the
// launch entirely — or spoofed; with port 0 neither is possible and concurrent
// runs (two catalogs, two users) can't collide.
func connectOrLaunch(ctx context.Context, cfg Config) (*cdp.Client, error) {
	profile := profileDir(cfg)
	if port, err := readDevToolsActivePort(profile); err == nil {
		if client, _ := connect(ctx, port); client != nil {
			return client, nil
		}
		// stale file from a dead Chrome: fall through to a fresh launch
	}
	_ = os.MkdirAll(profile, 0o755)
	// Remove the stale port file BEFORE spawning so the poll below can only
	// ever see the file the NEW Chrome writes — never a dead leftover.
	_ = os.Remove(filepath.Join(profile, "DevToolsActivePort"))
	chrome.MarkProfileClean(profile) // never nag about a previous unclean exit
	chromePath := chrome.Find()
	args := []string{
		"--remote-debugging-port=0",
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
		return nil, fmt.Errorf("could not start the assist Chrome window: %s", err)
	}
	for i := 0; i < 100; i++ {
		time.Sleep(100 * time.Millisecond)
		port, err := readDevToolsActivePort(profile)
		if err != nil {
			continue // not written (or mid-write) yet
		}
		if client, _ := connect(ctx, port); client != nil {
			return client, nil
		}
	}
	return nil, fmt.Errorf("could not start the assist Chrome window (no DevToolsActivePort)")
}

// newPage opens a fresh tab for this photo and closes the others, so there is
// a single visible tab and the overlay's addScriptToEvaluateOnNewDocument
// can't accumulate across photos.
func newPage(ctx context.Context, client *cdp.Client, cfg Config) (session, targetID string, err error) {
	// Generous budget: this guards against a hung browser, not slowness —
	// puppeteer's default protocol timeout was 180 s, and CI's shared mac
	// runners have shown 15 s to be too tight for real page creation.
	cctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	targetID, err = client.CreateTarget(cctx, "about:blank")
	if err != nil {
		return "", "", err
	}
	cfg.dbg("created target:", targetID)
	session, err = client.AttachToTarget(cctx, targetID)
	if err != nil {
		return "", "", err
	}
	cfg.dbg("attached session:", session)
	if err := client.EnablePageRuntime(cctx, session); err != nil {
		return "", "", err
	}
	targets, err := client.GetTargets(cctx)
	if err == nil {
		for _, t := range targets {
			if t.Type == "page" && t.TargetID != targetID {
				_ = client.CloseTarget(cctx, t.TargetID) // best-effort, like p.close().catch
			}
		}
	}
	return session, targetID, nil
}

// newNonce returns a fresh unguessable per-photo token. crypto/rand can't fail
// in practice on the platforms we ship; if it ever did, a zero token would make
// the overlay's tag ("|<name>") never match a non-empty nonce and the wait would
// simply time out — fail-closed, never a spurious tag.
func newNonce() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

func prepPage(ctx context.Context, client *cdp.Client, session string, cfg Config, nonce string) error {
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
	return client.AddScriptOnNewDocument(cctx, session, overlaySource(cfg.Pos, nonce))
}

// overlaySource wraps the embedded overlay file in an IIFE with a `module`
// shim (the file ends in a CommonJS export) and invokes it with pos + the
// per-photo nonce — the exact equivalent of
// page.evaluateOnNewDocument(assistOverlayInjector, pos, token).
func overlaySource(pos, token string) string {
	posJSON := "null"
	if pos != "" {
		b, _ := json.Marshal(pos)
		posJSON = string(b)
	}
	tokJSON, _ := json.Marshal(token)
	return "(function(){var module={exports:{}};\n" + overlayJS +
		"\nassistOverlayInjector(" + posJSON + "," + string(tokJSON) + ");})();"
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
	// Don't gate on the results URL. Google may interpose a consent or human-
	// verification page that the USER clears in the visible window before the
	// real results load (common from a rate-limited IP). Bailing here exits the
	// helper and tears down the overlay, so the Tag/Skip bar never appears once
	// the results finally arrive. Stay connected instead: the overlay is
	// registered on every new document, so it re-injects on whatever page the
	// user reaches, and waitForTag polls there. A genuinely stuck upload simply
	// ends when the user closes the window — the same abort path as any other
	// non-decision.
	if !vsridRe.MatchString(landed) {
		cfg.dbg("no results URL yet (verification/consent interstitial?); waiting for the user")
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
// (window.__stSkip), detects the user closing the Chrome window, or times out.
// Polling page globals — not exposeFunction — is what lets the helper reconnect
// to a reused window across photos.
//
// The overlay writes "<nonce>|<name>" for a Tag and the nonce for a Skip; a
// value that doesn't carry THIS photo's nonce is a blind/stale write (the fixed
// debug port lets any local process forge one) and is ignored, so the wait
// continues until a genuine tokened press.
//
// Close detection has two signals. Closing the whole window kills the
// browser-level socket, so client.Done() fires ("closed"). Closing just the
// assist tab (or the window in a build that keeps the browser process alive)
// leaves the socket up but removes the page target, so a GetTargets that lists
// NO page target means the user closed it — confirmed twice in a row so a single
// transient read can never false-abort a live run. Either way the outcome is
// "closed", which aborts the whole run rather than silently advancing.
//
// cfg.Timeout <= 0 means wait INDEFINITELY (the production default): the run is
// never abandoned on a timer, only on a Tag/Skip or a window close. A positive
// timeout bounds the wait — the test suites set one so a "never decides" page
// can't hang the suite; production never does.
func waitForTag(ctx context.Context, client *cdp.Client, session, targetID string, cfg Config, nonce string) (string, string) {
	var deadline time.Time
	bounded := cfg.Timeout > 0
	if bounded {
		deadline = time.Now().Add(cfg.Timeout)
	}
	pageGone := 0
	for !bounded || time.Now().Before(deadline) {
		select {
		case <-client.Done(): // the browser went away — user closed the window
			return "closed", ""
		default:
		}

		cctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		obj, err := client.Evaluate(cctx, session,
			"({tag: window.__stTag || null, skip: window.__stSkip || null, bar: !!document.getElementById('__lens_assist')})", true)
		cancel()
		if err == nil && obj != nil {
			var s struct {
				Tag  *string `json:"tag"`
				Skip *string `json:"skip"`
				Bar  bool    `json:"bar"`
			}
			if json.Unmarshal(obj.Value, &s) == nil {
				if name, ok := acceptTag(s.Tag, nonce); ok {
					return "tag", name
				}
				if s.Skip != nil && *s.Skip == nonce {
					return "skip", ""
				}
				if !s.Bar {
					// The Tag/Skip bar is ALWAYS present, no matter what the page
					// does. Google Lens is an SPA that re-renders after load and can
					// wipe DOM-appended nodes; the overlay's on-new-document
					// injection only covers full document loads. So whenever the bar
					// is gone we put it straight back — the injector self-guards, so
					// this is a no-op once it's there.
					ictx, icancel := context.WithTimeout(ctx, 10*time.Second)
					_, _ = client.Evaluate(ictx, session, overlaySource(cfg.Pos, nonce), true)
					icancel()
				}
			}
		}

		// Tab-close detection: our assist target vanishing from GetTargets means
		// the user closed the assist window/tab. Two consecutive confirmations
		// guard against a transient read during navigation (a GetTargets error is
		// inconclusive, not a miss). An Evaluate error alone is NOT enough — it
		// also happens mid-navigation — so we corroborate with the target list.
		if err != nil {
			if assistPageGone(ctx, client, targetID) {
				pageGone++
				if pageGone >= 2 {
					return "closed", ""
				}
			} else {
				pageGone = 0
			}
		} else {
			pageGone = 0
		}

		// mid-navigation evaluate errors: just try again, like the JS catch
		select {
		case <-client.Done():
			return "closed", ""
		case <-time.After(300 * time.Millisecond):
		}
	}
	return "timeout", ""
}

// targetLister is the slice of the CDP client the close-detector needs — just
// Target.getTargets. A narrow interface so assistPageGone is unit-tested without
// a browser (see session_test.go).
type targetLister interface {
	GetTargets(ctx context.Context) ([]cdp.TargetInfo, error)
}

// assistPageGone reports whether OUR assist page target (the one we created and
// injected the overlay into) is no longer listed — the user closed the assist
// window or tab. We track our SPECIFIC targetID rather than "are there zero page
// targets" because neither older signal is reliable:
//   - client.Done() (browser-socket death) never fires on macOS: closing the
//     last Chrome window leaves the browser process alive (verified against real
//     macOS Chrome 2026-07-19).
//   - "no page target at all" is defeated by any stray page target — a Google
//     Lens popup, an extension page, a hosted CI runner's blank tab — which keeps
//     it from ever firing. That single flaw was BOTH the macOS "never aborts" bug
//     and the windows-latest CI hang.
//
// A GetTargets error is inconclusive (transient / mid-teardown) and reported as
// false, so only a clean list that omits our target counts as closed.
func assistPageGone(ctx context.Context, client targetLister, targetID string) bool {
	cctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	targets, err := client.GetTargets(cctx)
	if err != nil {
		return false
	}
	for _, t := range targets {
		if t.TargetID == targetID {
			return false // our assist page is still there
		}
	}
	return true
}

// acceptTag validates a polled window.__stTag against this photo's nonce and
// returns the highlighted name. The overlay writes "<nonce>|<name>", so a value
// without the exact nonce prefix — a blind or stale write from another process
// on the fixed debug port, or a leftover from a previous photo — is rejected.
// Pure, so the anti-hijack contract is unit-tested without a browser. An empty
// nonce never accepts (fail-closed).
func acceptTag(raw *string, nonce string) (string, bool) {
	if raw == nil || nonce == "" {
		return "", false
	}
	sep := strings.IndexByte(*raw, '|')
	if sep < 0 || (*raw)[:sep] != nonce {
		return "", false
	}
	name := strings.TrimSpace((*raw)[sep+1:])
	if name == "" {
		return "", false
	}
	return name, true
}
