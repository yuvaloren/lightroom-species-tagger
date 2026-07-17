package chrome

import "testing"

// Mirrors scripts/lens/test/find-chrome.test.js — the load-bearing part is
// picking the right version FOLDER on Windows (so we never shell out to
// `chrome --version`, which pops a phantom browser window there).
func TestPickChromeVersionDir(t *testing.T) {
	cases := []struct {
		name    string
		entries []string
		want    string
	}{
		{"picks the newest of several",
			[]string{"140.0.7259.5", "139.0.7000.0", "140.0.7300.1"}, "140.0.7300.1"},
		{"ignores non-version entries",
			[]string{"chrome.exe", "SetupMetrics", "141.0.1.2", "Dictionaries"}, "141.0.1.2"},
		{"numeric compare, not lexical (…9 < …10)",
			[]string{"1.0.0.9", "1.0.0.10"}, "1.0.0.10"},
		{"empty when nothing matches",
			[]string{"chrome.exe", "Dictionaries"}, ""},
		{"empty on no entries", nil, ""},
	}
	for _, c := range cases {
		if got := PickChromeVersionDir(c.entries); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}

// DetectVersion must always return a usable {Full, Major} shape, never panic —
// even pointed at a nonexistent binary (it falls back to a recent default).
func TestDetectVersionNeverFails(t *testing.T) {
	v := DetectVersion("/no/such/chrome/here")
	if v.Full == "" || v.Major == "" {
		t.Errorf("fallback version is incomplete: %+v", v)
	}
}
