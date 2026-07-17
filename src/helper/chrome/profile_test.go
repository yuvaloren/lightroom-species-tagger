package chrome

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// Both Preferences layouts get the clean-exit flags; unrelated keys survive.
func TestMarkProfileCleanBothLayouts(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "Default", "Preferences"),
		`{"profile":{"exit_type":"Crashed","name":"assist"},"other":{"keep":42}}`)
	writeFile(t, filepath.Join(dir, "Preferences"),
		`{"unrelated":true}`)

	MarkProfileClean(dir)

	for _, p := range []string{
		filepath.Join(dir, "Default", "Preferences"),
		filepath.Join(dir, "Preferences"),
	} {
		data, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		var j map[string]any
		if err := json.Unmarshal(data, &j); err != nil {
			t.Fatalf("%s: output is not valid JSON: %v", p, err)
		}
		profile, _ := j["profile"].(map[string]any)
		if profile == nil || profile["exit_type"] != "Normal" || profile["exited_cleanly"] != true {
			t.Errorf("%s: clean-exit flags not set: %v", p, j)
		}
	}

	// Unrelated keys preserved in both files.
	data, _ := os.ReadFile(filepath.Join(dir, "Default", "Preferences"))
	var j map[string]any
	_ = json.Unmarshal(data, &j)
	if other, _ := j["other"].(map[string]any); other == nil || other["keep"] != float64(42) {
		t.Errorf("unrelated key dropped: %v", j)
	}
	if profile, _ := j["profile"].(map[string]any); profile["name"] != "assist" {
		t.Errorf("unrelated profile key dropped: %v", j)
	}
	data, _ = os.ReadFile(filepath.Join(dir, "Preferences"))
	j = nil
	_ = json.Unmarshal(data, &j)
	if j["unrelated"] != true {
		t.Errorf("unrelated top-level key dropped: %v", j)
	}
}

// Malformed JSON is left byte-for-byte alone — best-effort means never
// destroying a file we can't parse, and never failing the run.
func TestMarkProfileCleanMalformed(t *testing.T) {
	dir := t.TempDir()
	garbled := `{"profile": not json at all`
	writeFile(t, filepath.Join(dir, "Preferences"), garbled)

	MarkProfileClean(dir) // must not panic

	data, _ := os.ReadFile(filepath.Join(dir, "Preferences"))
	if string(data) != garbled {
		t.Errorf("malformed file was rewritten: %q", data)
	}
}

// A profile dir with no Preferences at all (first launch) is a no-op.
func TestMarkProfileCleanMissing(t *testing.T) {
	MarkProfileClean(t.TempDir())                        // empty dir
	MarkProfileClean(filepath.Join(t.TempDir(), "nope")) // nonexistent dir
}
