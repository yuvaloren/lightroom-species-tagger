//go:build live

// T8 — the live smoke: run the REAL helper against REAL Google with a real
// (generated) JPEG, in a HEADED Chrome, and stand in for the human's Tag
// press over the remote-debug port. Verifies the one thing the hermetic
// suite structurally can't: Google's actual upload endpoint + results page
// accept our flow (UA, cookies, form action, vsrid redirect).
//
//	just lens-live        (= go test -tags live -count=1 -v -run TestLiveSmoke ./lens/)
//
// Run on the Mac AND the Windows VM before cutover and before each release.
// NEVER in CI: needs real network (ideally residential) and pops a visible
// Chrome window for ~15 s. Uses exactly ONE tag: `live` and `integration`
// each define their own TestMain-equivalents, so don't combine the tags.
package lens

import (
	"bytes"
	"context"
	"encoding/json"
	"image"
	"image/color"
	"image/jpeg"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/yuvaloren/lightroom-species-tagger/helper/cdp"
)

const liveTag = "LIVE-SMOKE-OK"

func TestLiveSmoke(t *testing.T) {
	const port = 9481
	bin := buildLiveHelper(t)
	img := generateJPEG(t)
	cache, err := os.MkdirTemp("", "lens-live-cache")
	if err != nil {
		t.Fatal(err)
	}
	// Cleanup: close the window, then retire the profile dir race-free — an
	// atomic rename (one syscall, can't race Chrome's async flush, never rmdirs
	// a live dir) then a best-effort delete of the moved copy. No sleep.
	t.Cleanup(func() {
		cmd := exec.Command(bin, "x")
		cmd.Env = append(os.Environ(), "LENS_ASSIST_CLOSE=1", "LENS_TABS_PORT=9481", "LENS_CACHE_DIR="+cache)
		_ = cmd.Run()
		trash := cache + ".trash"
		if os.Rename(cache, trash) == nil {
			_ = os.RemoveAll(trash)
		}
	})

	// The stand-in human: as soon as the helper's Chrome shows a Lens results
	// page (vsrid in the URL), set window.__stTag over CDP — the same page
	// global the real Tag button sets.
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	go standInHuman(ctx, t, port)

	cmd := exec.CommandContext(ctx, bin, img)
	cmd.Env = append(os.Environ(),
		"LENS_TABS_PORT=9481",
		"LENS_CACHE_DIR="+cache,
		"LENS_ASSIST_POS=Live smoke",
		"LENS_INTERACTIVE_TIMEOUT=60000",
	)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	_ = cmd.Run()

	lines := strings.Split(strings.TrimSpace(stdout.String()), "\n")
	var res map[string]any
	if err := json.Unmarshal([]byte(lines[len(lines)-1]), &res); err != nil {
		t.Fatalf("no JSON from the helper: %q (stderr: %s)", stdout.String(), stderr.String())
	}
	if res["ok"] != true || res["name"] != liveTag {
		t.Fatalf("live flow failed: %v (stderr: %s)", res, stderr.String())
	}
	t.Log("real-Google upload + results + tag poll: OK")
}

func standInHuman(ctx context.Context, t *testing.T, port int) {
	vsrid := regexp.MustCompile(`[?&]vsrid=`)
	var client *cdp.Client
	for ctx.Err() == nil && client == nil {
		time.Sleep(500 * time.Millisecond)
		if c, err := connect(ctx, port); err == nil {
			client = c
		}
	}
	if client == nil {
		return
	}
	defer client.Close()
	for ctx.Err() == nil {
		time.Sleep(1 * time.Second)
		targets, err := client.GetTargets(ctx)
		if err != nil {
			return
		}
		for _, tg := range targets {
			if tg.Type != "page" || !vsrid.MatchString(tg.URL) {
				continue
			}
			session, err := client.AttachToTarget(ctx, tg.TargetID)
			if err != nil {
				continue
			}
			_, err = client.Evaluate(ctx, session, `window.__stTag = "`+liveTag+`"`, true)
			if err == nil {
				t.Log("stood in for the human: __stTag set on the results page")
				return
			}
		}
	}
}

func buildLiveHelper(t *testing.T) string {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "lens-helper-live")
	cmd := exec.Command("go", "build", "-o", bin,
		"github.com/yuvaloren/lightroom-species-tagger/helper")
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		t.Fatal(err)
	}
	return bin
}

// generateJPEG renders a simple but real photo-ish image (gradient sky +
// green blob) so Lens has something legitimate to analyze. What Lens says
// about it is irrelevant — the human stand-in tags a fixed string.
func generateJPEG(t *testing.T) string {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 480, 360))
	for y := 0; y < 360; y++ {
		for x := 0; x < 480; x++ {
			img.Set(x, y, color.RGBA{uint8(100 + y/4), uint8(150 + y/8), uint8(220 - y/6), 255})
		}
	}
	for y := 200; y < 340; y++ { // a leafy blob
		for x := 140; x < 340; x++ {
			dx, dy := x-240, y-270
			if dx*dx+dy*dy < 90*90 {
				img.Set(x, y, color.RGBA{uint8(30 + (x+y)%40), uint8(120 + (x*y)%60), 40, 255})
			}
		}
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: 90}); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(t.TempDir(), "live-smoke.jpg")
	if err := os.WriteFile(p, buf.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}
