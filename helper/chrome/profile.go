package chrome

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// MarkProfileClean forces the assist profile's last-exit state to "clean"
// before each launch. Chrome shows a "didn't shut down correctly / restore
// pages?" bubble when the previous exit wasn't Normal — and ONE unclean exit
// (crash, killed helper, quitting Lightroom mid-run) poisons every launch
// after it. Editing Preferences is more reliable than a flag (and avoids the
// "unsupported flag" warning bar on a visible window).
//
// Best-effort BY DESIGN: any error (missing file, malformed JSON, read-only
// dir) leaves the file alone and never fails the run — worst case the user
// sees Chrome's restore bubble once.
func MarkProfileClean(profileDir string) {
	for _, pref := range []string{
		filepath.Join(profileDir, "Default", "Preferences"),
		filepath.Join(profileDir, "Preferences"),
	} {
		data, err := os.ReadFile(pref)
		if err != nil {
			continue
		}
		var j map[string]any
		if json.Unmarshal(data, &j) != nil {
			continue
		}
		profile, _ := j["profile"].(map[string]any)
		if profile == nil {
			profile = map[string]any{}
		}
		profile["exit_type"] = "Normal"
		profile["exited_cleanly"] = true
		j["profile"] = profile
		out, err := json.Marshal(j)
		if err != nil {
			continue
		}
		_ = os.WriteFile(pref, out, 0o644)
	}
}
