#+build linux, darwin, freebsd, openbsd, netbsd
package tests_core_posix

import "core:sys/posix"
import "core:testing"

// A pid no system hands out, pid_max is at most 2^22 on Linux and 99999 on the others.
UNUSED_PID :: posix.pid_t(0x7fff_ffff)

@(test)
test_process_ids :: proc(t: ^testing.T) {
	pid  := posix.getpid()
	ppid := posix.getppid()
	testing.expect(t, pid  > 0, "getpid must be positive")
	testing.expect(t, ppid > 0, "getppid must be positive")
	testing.expect(t, pid != ppid, "a process is not its own parent")

	testing.expect_value(t, posix.getpgid(0), posix.getpgid(pid))
	testing.expect(t, posix.getpgid(0) > 0, "getpgid must be positive")
	testing.expect_value(t, posix.getsid(0), posix.getsid(pid))
	testing.expect(t, posix.getsid(0) > 0, "getsid must be positive")
}

@(test)
test_process_id_errors :: proc(t: ^testing.T) {
	testing.expect_value(t, posix.getpgid(UNUSED_PID), -1)
	testing.expect_value(t, posix.errno(), posix.Errno.ESRCH)

	testing.expect_value(t, posix.getsid(UNUSED_PID), -1)
	testing.expect_value(t, posix.errno(), posix.Errno.ESRCH)

	testing.expect_value(t, posix.setpgid(UNUSED_PID, 0), posix.result.FAIL)
	testing.expect_value(t, posix.errno(), posix.Errno.ESRCH)
}

@(test)
test_user_ids :: proc(t: ^testing.T) {
	// Nothing sets the effective ids apart from the real ones here, so the
	// two pairs agree.
	testing.expect_value(t, posix.getuid(), posix.geteuid())
	testing.expect_value(t, posix.getgid(), posix.getegid())
}

@(test)
test_kill :: proc(t: ^testing.T) {
	// Signal zero only checks that the process exists and can be signalled.
	testing.expect_value(t, posix.kill(posix.getpid(), .NONE), posix.result.OK)

	testing.expect_value(t, posix.kill(UNUSED_PID, .NONE), posix.result.FAIL)
	testing.expect_value(t, posix.errno(), posix.Errno.ESRCH)

	testing.expect_value(t, posix.killpg(posix.getpgid(0), .NONE), posix.result.OK)

	testing.expect_value(t, posix.killpg(UNUSED_PID, .NONE), posix.result.FAIL)
	testing.expect_value(t, posix.errno(), posix.Errno.ESRCH)

	testing.expect_value(t, posix.killpg(-1, .NONE), posix.result.FAIL)
	testing.expect_value(t, posix.errno(), posix.Errno.EINVAL)
}
