package lens

import "runtime"

// Indirection so UserAgentFor stays a pure function of (goos, goarch) and the
// golden tests can pin every platform from any runner.
func goos() string   { return runtime.GOOS }
func goarch() string { return runtime.GOARCH }
