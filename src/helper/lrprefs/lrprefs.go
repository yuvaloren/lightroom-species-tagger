// Package lrprefs clears Lightroom Classic's remembered "disabled" state for
// the plug-in copy an installer just placed on disk — the piece that makes an
// install ALWAYS enable the plug-in.
//
// Lightroom records disabled plug-ins in its preferences under two keys:
//
//	AgSdkPluginLoader_disabledPluginIDs    (by LrToolkitIdentifier)
//	AgSdkPluginLoader_disabledPluginPaths  (by absolute .lrplugin path)
//
// each holding a pickled Lua table `t = {\n\t["<key>"] = true,\n...}\n`. On
// Windows the tables live in the "Lightroom Classic CC 7 Preferences.agprefs"
// container file; on macOS in the com.adobe.LightroomClassicCC7 defaults
// domain (a plist owned by cfprefsd — edited through defaults(1), never as a
// file). Both use the same pickle escaping: backslash before a quote, a
// backslash, or a newline.
//
// The surgery is deliberately narrow: it removes the plug-in id plus the ONE
// path being installed. Other copies of Species Tagger the user disabled on
// purpose (say, a dev checkout kept alongside the pkg install) stay disabled —
// re-enabling them would duplicate the Plug-in Extras menu.
//
// Formats verified against a real macOS installation 2026-07-19; the fixtures
// in lrprefs_test.go and build/check-install-enables.sh mirror those bytes.
package lrprefs

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
)

// PluginID mirrors LrToolkitIdentifier in src/plugin/Info.lua — a Go test
// guards against drift (the two cannot be read from one source at runtime:
// Lightroom loads Info.lua, installers run this binary).
const PluginID = "org.yoren.lightroom.speciestagger"

const (
	idsKey         = "AgSdkPluginLoader_disabledPluginIDs"
	pathsKey       = "AgSdkPluginLoader_disabledPluginPaths"
	defaultsDomain = "com.adobe.LightroomClassicCC7"
)

// Unescape decodes Lightroom's pickle string escaping: a backslash before a
// quote, a backslash, or a newline stands for that character. Any other
// backslash sequence is kept verbatim (the pickler never writes one; keeping
// it makes Unescape/Escape a safe round-trip on unexpected input).
func Unescape(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == '\\' && i+1 < len(s) {
			switch n := s[i+1]; n {
			case '\\', '"', '\n':
				b.WriteByte(n)
				i++
				continue
			}
		}
		b.WriteByte(c)
	}
	return b.String()
}

// Escape is the inverse of Unescape — exactly the three characters the
// pickler escapes, nothing more.
func Escape(s string) string {
	var b strings.Builder
	b.Grow(len(s) + 8)
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == '\\' || c == '"' || c == '\n' {
			b.WriteByte('\\')
		}
		b.WriteByte(c)
	}
	return b.String()
}

// One `["<key>"] = true,` entry line of a pickled disable-table. Keys are Lua
// string literals, so a quote or backslash inside one arrives escaped. Only
// `= true,` lines are touched — anything else in the table is not a disable
// entry and passes through untouched.
var entryRe = regexp.MustCompile(`^\t\["((?:\\.|[^"\\])*)"\] = true,$`)

// RemoveEntries drops every entry line of a pickled table whose UNESCAPED key
// satisfies match, preserving all other bytes. Returns the rewritten table
// and the number of entries removed.
func RemoveEntries(table string, match func(string) bool) (string, int) {
	var b strings.Builder
	b.Grow(len(table))
	removed := 0
	for _, line := range strings.SplitAfter(table, "\n") {
		if m := entryRe.FindStringSubmatch(strings.TrimSuffix(line, "\n")); m != nil && match(Unescape(m[1])) {
			removed++
			continue
		}
		b.WriteString(line)
	}
	return b.String(), removed
}

// PathMatcher matches only the exact path being installed, case-insensitively
// — NTFS and default APFS/HFS+ don't distinguish case, and Lightroom stores
// the path as it resolved it, which may differ in case from what an installer
// passes in.
func PathMatcher(installed string) func(string) bool {
	return func(key string) bool { return strings.EqualFold(key, installed) }
}

// idMatcher is the disabledPluginIDs counterpart of PathMatcher.
func idMatcher(key string) bool { return key == PluginID }

// keyValueRe finds `\t<key> = "<escaped value>",` in an agprefs container.
// (?s) lets the value cross the backslash-escaped newlines pickled multi-line
// strings are made of.
func keyValueRe(key string) *regexp.Regexp {
	return regexp.MustCompile(`(?m)^\t` + regexp.QuoteMeta(key) + ` = "((?s:(?:\\.|[^"\\])*))",$`)
}

// editKey rewrites one container key's pickled table via RemoveEntries.
// Missing key, or nothing matched: the content comes back byte-identical.
func editKey(content, key string, match func(string) bool) (string, int) {
	loc := keyValueRe(key).FindStringSubmatchIndex(content)
	if loc == nil {
		return content, 0
	}
	newRaw, n := RemoveEntries(Unescape(content[loc[2]:loc[3]]), match)
	if n == 0 {
		return content, 0
	}
	return content[:loc[2]] + Escape(newRaw) + content[loc[3]:], n
}

// EnableInContent clears the plug-in's disabled state (id + the installed
// path) in an agprefs container. Pure text-in/text-out — the testable core of
// the file mode.
func EnableInContent(content, pluginPath string) (string, int) {
	out, a := editKey(content, idsKey, idMatcher)
	out, b := editKey(out, pathsKey, PathMatcher(pluginPath))
	return out, a + b
}

// EnableInFile applies EnableInContent to a prefs file, replacing it
// atomically (same-directory temp + rename) so a crash mid-write can never
// leave Lightroom a half-written prefs file. A missing file is success: on a
// machine where Lightroom has never run there is nothing recorded to clear.
func EnableInFile(path, pluginPath string) (int, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, err
	}
	out, n := EnableInContent(string(data), pluginPath)
	if n == 0 {
		return 0, nil
	}
	mode := os.FileMode(0o644)
	if info, err := os.Stat(path); err == nil {
		mode = info.Mode().Perm()
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".agprefs-rewrite-*")
	if err != nil {
		return 0, err
	}
	defer os.Remove(tmp.Name()) // no-op after the rename succeeds
	if _, err := tmp.WriteString(out); err != nil {
		tmp.Close()
		return 0, err
	}
	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		return 0, err
	}
	if err := tmp.Close(); err != nil {
		return 0, err
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		return 0, err
	}
	return n, nil
}

// EnableInDefaults is the macOS mode: the CC7 prefs plist belongs to cfprefsd,
// so each pickled table is read and written back through defaults(1) — never
// by touching the plist file. A key that doesn't exist has nothing recorded
// and is skipped.
func EnableInDefaults(domain, pluginPath string) (int, error) {
	total := 0
	for _, k := range []struct {
		key   string
		match func(string) bool
	}{
		{idsKey, idMatcher},
		{pathsKey, PathMatcher(pluginPath)},
	} {
		out, err := exec.Command("defaults", "read", domain, k.key).Output()
		if err != nil {
			continue // key (or domain) absent: nothing recorded under it
		}
		raw := strings.TrimSuffix(string(out), "\n") // read appends one newline
		newRaw, n := RemoveEntries(raw, k.match)
		if n == 0 {
			continue
		}
		if err := exec.Command("defaults", "write", domain, k.key, "-string", newRaw).Run(); err != nil {
			return total, fmt.Errorf("defaults write %s failed: %w", k.key, err)
		}
		total += n
	}
	return total, nil
}

// EnableInstalled picks the mechanism for this machine. ST_LR_AGPREFS forces
// file mode on an explicit path (the test harnesses; also how Linux CI runs
// this at all). ST_LR_DEFAULTS_DOMAIN redirects the macOS mode to a scratch
// domain for live verification without touching real prefs.
func EnableInstalled(pluginPath string) (int, error) {
	if f := os.Getenv("ST_LR_AGPREFS"); f != "" {
		return EnableInFile(f, pluginPath)
	}
	switch runtime.GOOS {
	case "darwin":
		domain := os.Getenv("ST_LR_DEFAULTS_DOMAIN")
		if domain == "" {
			domain = defaultsDomain
		}
		return EnableInDefaults(domain, pluginPath)
	case "windows":
		appdata := os.Getenv("APPDATA")
		if appdata == "" {
			return 0, nil
		}
		return EnableInFile(filepath.Join(appdata,
			"Adobe", "Lightroom", "Preferences",
			"Lightroom Classic CC 7 Preferences.agprefs"), pluginPath)
	}
	return 0, nil // no Lightroom on this OS
}

// LightroomRunning reports whether Lightroom Classic currently has the prefs
// open in memory — it rewrites them wholesale on quit, so an edit made now
// can be overwritten. Best-effort: false on any doubt.
func LightroomRunning() bool {
	switch runtime.GOOS {
	case "darwin":
		return exec.Command("pgrep", "-x", "Adobe Lightroom Classic").Run() == nil
	case "windows":
		out, err := exec.Command("tasklist", "/FI", "IMAGENAME eq Lightroom.exe", "/NH").Output()
		return err == nil && strings.Contains(string(out), "Lightroom.exe")
	}
	return false
}

// CmdEnableInstalled is the `lens-helper enable-installed <plugin path>`
// entry point every installer calls (build.lua --install, the macOS pkg
// postinstall, the NSIS section). Output is human-readable install-log text,
// and the exit code is always 0: failing to clear a stale flag must never
// fail an install — the user can still enable the plug-in by hand.
func CmdEnableInstalled(pluginPath string) int {
	n, err := EnableInstalled(pluginPath)
	switch {
	case err != nil:
		fmt.Printf("enable-installed: %v — if Species Tagger shows disabled, enable it in File > Plug-in Manager\n", err)
	case n > 0:
		fmt.Printf("cleared Lightroom's remembered \"disabled\" state for %s\n", pluginPath)
		if LightroomRunning() {
			fmt.Println("note: Lightroom Classic is running and rewrites its preferences when it quits — if the plug-in still shows disabled after restarting Lightroom, quit Lightroom and run the install again")
		}
	default:
		fmt.Println("Species Tagger was not marked disabled — nothing to clear")
	}
	return 0
}
