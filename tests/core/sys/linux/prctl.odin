#+build linux
package tests_core_sys_linux

import "core:sys/linux"
import "core:testing"

@(test)
test_prctl_pdeathsig :: proc(t: ^testing.T) {
	signal: i32 = -1
	testing.expect_value(t, linux.prctl(linux.PR_GET_PDEATHSIG, uint(uintptr(&signal))), linux.Errno.NONE)
	testing.expect_value(t, signal, 0)

	testing.expect_value(t, linux.prctl(linux.PR_SET_PDEATHSIG, uint(linux.Signal.SIGTERM)), linux.Errno.NONE)
	testing.expect_value(t, linux.prctl(linux.PR_GET_PDEATHSIG, uint(uintptr(&signal))), linux.Errno.NONE)
	testing.expect_value(t, linux.Signal(signal), linux.Signal.SIGTERM)

	// The setting outlives the test in this process, so put it back.
	testing.expect_value(t, linux.prctl(linux.PR_SET_PDEATHSIG, 0), linux.Errno.NONE)
}
