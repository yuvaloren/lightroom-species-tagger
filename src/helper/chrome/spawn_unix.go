//go:build !windows

package chrome

import (
	"os/exec"
	"syscall"
)

// detach puts Chrome in its own session so it survives the helper exiting
// (and any signal aimed at the helper's group).
func detach(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
}
