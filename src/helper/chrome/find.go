// Package chrome locates, launches, and tidies up after the user's installed
// Google Chrome. Port of the former Node find-chrome.js plus the detached-spawn
// and markProfileClean pieces of lens-search.js.
package chrome

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// Find returns the path of the installed Google Chrome (LENS_CHROME wins),
// falling back to a bare name and hoping it's on PATH — same contract as
// find-chrome.js.
func Find() string {
	if p := os.Getenv("LENS_CHROME"); p != "" {
		return p
	}
	var candidates []string
	switch runtime.GOOS {
	case "windows":
		pf := envOr("ProgramFiles", `C:\Program Files`)
		pfx86 := envOr("ProgramFiles(x86)", `C:\Program Files (x86)`)
		local := os.Getenv("LOCALAPPDATA")
		if local == "" {
			home, _ := os.UserHomeDir()
			local = filepath.Join(home, "AppData", "Local")
		}
		candidates = []string{
			filepath.Join(pf, `Google\Chrome\Application\chrome.exe`),
			filepath.Join(pfx86, `Google\Chrome\Application\chrome.exe`),
			filepath.Join(local, `Google\Chrome\Application\chrome.exe`),
			filepath.Join(pf, `Google\Chrome Beta\Application\chrome.exe`),
			filepath.Join(pf, `Chromium\Application\chrome.exe`),
		}
	case "darwin":
		candidates = []string{
			"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
			"/Applications/Google Chrome Beta.app/Contents/MacOS/Google Chrome Beta",
			"/Applications/Chromium.app/Contents/MacOS/Chromium",
		}
	default:
		candidates = []string{
			"/usr/bin/google-chrome", "/usr/bin/google-chrome-stable", "/opt/google/chrome/chrome",
			"/usr/bin/chromium", "/usr/bin/chromium-browser", "/snap/bin/chromium",
		}
	}
	for _, c := range candidates {
		if _, err := os.Stat(c); err == nil {
			return c
		}
	}
	if runtime.GOOS == "windows" {
		return "chrome.exe"
	}
	return "google-chrome"
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// Version is the installed Chrome's version, split the way the UA needs it.
type Version struct {
	Full  string // "138.0.7204.49"
	Major string // "138"
}

// fallback mirrors find-chrome.js's recent-default when detection fails.
var fallback = Version{Full: "149.0.0.0", Major: "149"}

var versionDirRe = regexp.MustCompile(`^\d+\.\d+\.\d+\.\d+$`)
var versionRe = regexp.MustCompile(`(\d+)\.\d+\.\d+\.\d+`)

// PickChromeVersionDir returns the highest "a.b.c.d" entry from a directory
// listing (Windows Chrome keeps one folder per installed version next to
// chrome.exe). Pure — data-driven-testable. Empty string when none match.
func PickChromeVersionDir(entries []string) string {
	best := ""
	var bestParts [4]int
	for _, e := range entries {
		if !versionDirRe.MatchString(e) {
			continue
		}
		var p [4]int
		for i, s := range strings.SplitN(e, ".", 4) {
			p[i], _ = strconv.Atoi(s) // versionDirRe already guaranteed all-digits
		}
		if best == "" || less(bestParts, p) {
			best, bestParts = e, p
		}
	}
	return best
}

func less(a, b [4]int) bool {
	for i := 0; i < 4; i++ {
		if a[i] != b[i] {
			return a[i] < b[i]
		}
	}
	return false
}

// DetectVersion reads the installed Chrome's version: `chrome --version` on
// mac/linux (a clean print-and-exit), the version folder next to chrome.exe
// on Windows (running `chrome.exe --version` pops a phantom window and prints
// nothing — see find-chrome.js's header note).
func DetectVersion(chromePath string) Version {
	if runtime.GOOS == "windows" {
		entries, err := os.ReadDir(filepath.Dir(chromePath))
		if err == nil {
			names := make([]string, 0, len(entries))
			for _, e := range entries {
				names = append(names, e.Name())
			}
			if best := PickChromeVersionDir(names); best != "" {
				return Version{Full: best, Major: strings.SplitN(best, ".", 2)[0]}
			}
		}
		return fallback
	}
	// CommandContext kills `chrome --version` if it hangs past the deadline —
	// no manual goroutine + Process.Kill dance.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, chromePath, "--version").Output()
	if err == nil {
		if m := versionRe.FindStringSubmatch(string(out)); m != nil {
			return Version{Full: m[0], Major: m[1]}
		}
	}
	return fallback
}
