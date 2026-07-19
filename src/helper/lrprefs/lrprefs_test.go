// Unit tests for lrprefs — the Lightroom-preferences surgery that makes an
// install ALWAYS enable the plug-in.
//
// Lightroom Classic remembers disabled plug-ins in its preferences under two
// keys — AgSdkPluginLoader_disabledPluginIDs (by LrToolkitIdentifier) and
// AgSdkPluginLoader_disabledPluginPaths (by absolute .lrplugin path) — each a
// pickled Lua table `t = {\n\t["<key>"] = true,\n...}\n`. On Windows those
// live in the agprefs container file; on macOS in the CC7 defaults domain
// (same pickled strings, reached via `defaults`). Every fixture below is
// modeled byte-for-byte on values read from a real macOS installation on
// 2026-07-19.
package lrprefs

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// ---- fixtures (real-world shapes) ------------------------------------------

// Raw pickled IDs table exactly as `defaults read` prints it (tabs, trailing
// newline), from the real machine — plus our plugin id.
const idsTable = "t = {\n" +
	"\t[\"com.adobe.lightroom.sdk.aperture_importer\"] = true,\n" +
	"\t[\"com.topazlabs.TopazPhoto\"] = true,\n" +
	"\t[\"org.yoren.lightroom.speciestagger\"] = true,\n" +
	"}\n"

// Raw pickled paths table: the copy being installed, a SECOND SpeciesTagger
// copy elsewhere (must survive — see PathMatcher docs), and an unrelated
// plug-in (must survive).
const installedPath = "/Users/yoren/Documents/Lightroom Plugins/SpeciesTagger.lrplugin"

const pathsTable = "t = {\n" +
	"\t[\"/Users/yoren/Documents/Lightroom Plugins/SpeciesTagger.lrplugin\"] = true,\n" +
	"\t[\"/Users/yoren/Documents/Projects/PhotoManagement/lightroom-species-tagger/output/dist/SpeciesTagger.lrplugin\"] = true,\n" +
	"\t[\"/Users/yoren/Library/Application Support/Adobe/Lightroom/Modules/Topaz Photo.lrplugin\"] = true,\n" +
	"}\n"

// ---- Escape / Unescape ------------------------------------------------------

func TestUnescapeEscapeRoundTrip(t *testing.T) {
	cases := []struct{ escaped, raw string }{
		{`plain`, `plain`},
		{`a \"quoted\" word`, `a "quoted" word`},
		{`C:\\Users\\x\\SpeciesTagger.lrplugin`, `C:\Users\x\SpeciesTagger.lrplugin`},
		{"line one\\\nline two", "line one\nline two"}, // pickle newline = backslash + real newline
	}
	for _, c := range cases {
		if got := Unescape(c.escaped); got != c.raw {
			t.Errorf("Unescape(%q) = %q, want %q", c.escaped, got, c.raw)
		}
		if got := Escape(c.raw); got != c.escaped {
			t.Errorf("Escape(%q) = %q, want %q", c.raw, got, c.escaped)
		}
	}
}

// ---- RemoveEntries ----------------------------------------------------------

func TestRemoveEntriesDropsOnlyThePluginID(t *testing.T) {
	out, n := RemoveEntries(idsTable, func(key string) bool { return key == PluginID })
	if n != 1 {
		t.Fatalf("removed %d entries, want 1", n)
	}
	want := "t = {\n" +
		"\t[\"com.adobe.lightroom.sdk.aperture_importer\"] = true,\n" +
		"\t[\"com.topazlabs.TopazPhoto\"] = true,\n" +
		"}\n"
	if out != want {
		t.Errorf("table after removal:\n%q\nwant:\n%q", out, want)
	}
}

func TestRemoveEntriesNoMatchLeavesTableByteIdentical(t *testing.T) {
	out, n := RemoveEntries(idsTable, func(key string) bool { return key == "org.example.other" })
	if n != 0 || out != idsTable {
		t.Errorf("no-match must be a byte-identical no-op (removed %d)", n)
	}
}

func TestRemoveEntriesCanEmptyTheTable(t *testing.T) {
	one := "t = {\n\t[\"org.yoren.lightroom.speciestagger\"] = true,\n}\n"
	out, n := RemoveEntries(one, func(key string) bool { return key == PluginID })
	if n != 1 || out != "t = {\n}\n" {
		t.Errorf("emptied table = %q (removed %d), want %q", out, n, "t = {\n}\n")
	}
}

// ---- PathMatcher ------------------------------------------------------------

// Only the copy BEING INSTALLED is re-enabled. Other copies of the plug-in the
// user disabled on purpose (e.g. a dev copy kept alongside the pkg install)
// must stay disabled — re-enabling them would put duplicate entries in the
// Plug-in Extras menu.
func TestPathMatcherRemovesOnlyTheInstalledCopy(t *testing.T) {
	out, n := RemoveEntries(pathsTable, PathMatcher(installedPath))
	if n != 1 {
		t.Fatalf("removed %d entries, want 1", n)
	}
	if strings.Contains(out, "Documents/Lightroom Plugins/SpeciesTagger.lrplugin") {
		t.Errorf("installed copy still present:\n%s", out)
	}
	if !strings.Contains(out, "output/dist/SpeciesTagger.lrplugin") {
		t.Errorf("OTHER SpeciesTagger copy was wrongly re-enabled:\n%s", out)
	}
	if !strings.Contains(out, "Topaz Photo.lrplugin") {
		t.Errorf("unrelated plug-in entry was lost:\n%s", out)
	}
}

// Windows paths land in the pickle with escaped backslashes; the installer
// hands us the native path. Case must not matter — both NTFS and default
// APFS/HFS+ are case-insensitive.
func TestPathMatcherWindowsEscapedAndCaseInsensitive(t *testing.T) {
	winTable := "t = {\n" +
		"\t[\"C:\\\\Users\\\\Yuval\\\\AppData\\\\Roaming\\\\Adobe\\\\Lightroom\\\\Modules\\\\SpeciesTagger.lrplugin\"] = true,\n" +
		"}\n"
	out, n := RemoveEntries(winTable, PathMatcher(`c:\users\yuval\AppData\Roaming\Adobe\Lightroom\Modules\SpeciesTagger.lrplugin`))
	if n != 1 || out != "t = {\n}\n" {
		t.Errorf("windows-escaped entry not matched: removed %d, out %q", n, out)
	}
}

// ---- EnableInContent (agprefs container) ------------------------------------

// A container in the shape of the real "Lightroom Classic CC 7" agprefs files:
// pickled multi-line string values use backslash+newline escapes, quotes inside
// values are backslash-escaped, keys sit on tab-indented lines. The
// Adobe_successfulUpgrades value is a multi-line pickle that must come through
// byte-identical (it contains bracketed path keys, just like a disabled table).
func agprefsContainer(dest string) string {
	return "prefs = {\n" +
		"\tAdobe_successfulUpgrades1500000 = \"pickle = {\\\n" +
		"\t[\\\"/Users/x/cat.lrcat\\\"] = {\\\n" +
		"\t\tcatalogType = \\\"lr\\\",\\\n" +
		"\t},\\\n" +
		"}\\\n" +
		"\",\n" +
		"\tAgSdkPluginLoader_disabledPluginIDs = \"t = {\\\n" +
		"\t[\\\"com.adobe.lightroom.sdk.aperture_importer\\\"] = true,\\\n" +
		"\t[\\\"org.yoren.lightroom.speciestagger\\\"] = true,\\\n" +
		"}\\\n" +
		"\",\n" +
		"\tAgSdkPluginLoader_disabledPluginPaths = \"t = {\\\n" +
		"\t[\\\"" + Escape(dest) + "\\\"] = true,\\\n" +
		"\t[\\\"/Users/x/Modules/Topaz Photo.lrplugin\\\"] = true,\\\n" +
		"}\\\n" +
		"\",\n" +
		"\tlibraryToLoad20 = \"/Users/x/cat.lrcat\",\n" +
		"}\n"
}

func TestEnableInContentClearsIDAndInstalledPathOnly(t *testing.T) {
	dest := "/Users/x/Library/Application Support/Adobe/Lightroom/Modules/SpeciesTagger.lrplugin"
	out, n := EnableInContent(agprefsContainer(dest), dest)
	if n != 2 {
		t.Fatalf("removed %d entries, want 2 (id + installed path)", n)
	}
	if strings.Contains(out, "speciestagger") || strings.Contains(out, "SpeciesTagger.lrplugin") {
		t.Errorf("a SpeciesTagger disabled entry survived:\n%s", out)
	}
	for _, keep := range []string{
		"aperture_importer",
		"Topaz Photo.lrplugin",
		"Adobe_successfulUpgrades1500000",
		"libraryToLoad20 = \"/Users/x/cat.lrcat\",",
	} {
		if !strings.Contains(out, keep) {
			t.Errorf("container lost unrelated content %q:\n%s", keep, out)
		}
	}
	// Everything around the two edited values must be byte-identical: strip the
	// two edited lines' worth of change by re-running on the result — a second
	// pass must be a perfect no-op.
	again, n2 := EnableInContent(out, dest)
	if n2 != 0 || again != out {
		t.Errorf("EnableInContent is not idempotent (second pass removed %d)", n2)
	}
}

func TestEnableInContentWithoutDisabledKeysIsANoOp(t *testing.T) {
	content := "prefs = {\n\tlibraryToLoad20 = \"/Users/x/cat.lrcat\",\n}\n"
	out, n := EnableInContent(content, "/anywhere/SpeciesTagger.lrplugin")
	if n != 0 || out != content {
		t.Errorf("fresh prefs must pass through untouched (removed %d)", n)
	}
}

// ---- EnableInFile -----------------------------------------------------------

func TestEnableInFileEndToEndAndIdempotent(t *testing.T) {
	dest := "/Users/x/Library/Application Support/Adobe/Lightroom/Modules/SpeciesTagger.lrplugin"
	prefs := filepath.Join(t.TempDir(), "Lightroom Classic CC 7 Preferences.agprefs")
	if err := os.WriteFile(prefs, []byte(agprefsContainer(dest)), 0o644); err != nil {
		t.Fatal(err)
	}
	n, err := EnableInFile(prefs, dest)
	if err != nil || n != 2 {
		t.Fatalf("EnableInFile = (%d, %v), want (2, nil)", n, err)
	}
	after, err := os.ReadFile(prefs)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(after), "speciestagger") {
		t.Errorf("file still holds a disabled entry:\n%s", after)
	}
	// Second run: nothing to do, file byte-identical.
	n2, err := EnableInFile(prefs, dest)
	if err != nil || n2 != 0 {
		t.Fatalf("second EnableInFile = (%d, %v), want (0, nil)", n2, err)
	}
	again, _ := os.ReadFile(prefs)
	if string(again) != string(after) {
		t.Error("idempotent re-run modified the file")
	}
}

// A machine where Lightroom has never run has no prefs file. There is nothing
// recorded to disable the plug-in, so that is success, not an error.
func TestEnableInFileMissingFileIsSuccess(t *testing.T) {
	n, err := EnableInFile(filepath.Join(t.TempDir(), "no such.agprefs"), "/x/SpeciesTagger.lrplugin")
	if err != nil || n != 0 {
		t.Errorf("missing prefs file = (%d, %v), want (0, nil)", n, err)
	}
}

// ---- drift guard ------------------------------------------------------------

// PluginID must stay in lock-step with LrToolkitIdentifier in the plugin
// manifest — if they drift, installs silently stop clearing the disabled flag.
func TestPluginIDMatchesInfoLua(t *testing.T) {
	src, err := os.ReadFile(filepath.Join("..", "..", "plugin", "Info.lua"))
	if err != nil {
		t.Fatalf("cannot read Info.lua: %v", err)
	}
	if !strings.Contains(string(src), "'"+PluginID+"'") {
		t.Errorf("Info.lua's LrToolkitIdentifier does not match PluginID %q", PluginID)
	}
}
