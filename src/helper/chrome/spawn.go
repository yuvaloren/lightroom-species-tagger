package chrome

import (
	"os/exec"
)

// SpawnDetached launches Chrome so it SURVIVES this helper exiting — the
// whole point of the reuse-one-window-across-photos design. Each per-photo
// helper invocation exits; the window must not die with it. Per-OS process
// attributes live in spawn_unix.go / spawn_windows.go.
func SpawnDetached(chromePath string, args []string) error {
	cmd := exec.Command(chromePath, args...)
	// No inherited stdio: the helper's stdout is a one-line JSON contract and
	// Chrome must not be able to scribble on it (mirrors stdio:'ignore').
	cmd.Stdin, cmd.Stdout, cmd.Stderr = nil, nil, nil
	detach(cmd)
	if err := cmd.Start(); err != nil {
		return err
	}
	return cmd.Process.Release()
}
