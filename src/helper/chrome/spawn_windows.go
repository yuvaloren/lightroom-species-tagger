//go:build windows

package chrome

import (
	"os/exec"
	"syscall"
)

const detachedProcess = 0x00000008 // DETACHED_PROCESS

// detach mirrors Node's {detached:true} on Windows: a new process group with
// no console inheritance, so Chrome outlives the helper (which Lightroom runs
// per photo via a temp .bat). Covered by the lifecycle integration test on
// the windows CI runner — if Chrome dies with the helper, window reuse breaks.
func detach(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{
		CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP | detachedProcess,
	}
}
