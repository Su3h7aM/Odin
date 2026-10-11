#+build linux
package tests_core_sys_linux

import "core:sys/linux"
import "core:testing"

@(private="file")
handled: i32

@(private="file")
handler :: proc "c" (sig: linux.Signal) {
	handled = i32(sig)
}

@(test)
test_rt_sigaction_query :: proc(t: ^testing.T) {
	// With no new action this only reads the current one, and must not write through the nil.
	old: linux.Sig_Action
	testing.expect_value(t, linux.rt_sigaction(.SIGUSR1, nil, &old), linux.Errno.NONE)
	testing.expect_value(t, old.special, linux.Sig_Action_Special.SIG_DFL)
}

@(test)
test_rt_sigaction_handler :: proc(t: ^testing.T) {
	// The handler returns through the restorer, so a wrong one crashes this test.
	handled = 0
	action := linux.Sig_Action{handler = handler}
	old: linux.Sig_Action
	testing.expect_value(t, linux.rt_sigaction(.SIGUSR2, &action, &old), linux.Errno.NONE)

	// Signal this thread so the handler has run before the call returns.
	testing.expect_value(t, linux.tgkill(linux.getpid(), linux.gettid(), .SIGUSR2), linux.Errno.NONE)
	testing.expect_value(t, linux.Signal(handled), linux.Signal.SIGUSR2)

	testing.expect_value(t, linux.rt_sigaction(.SIGUSR2, &old, nil), linux.Errno.NONE)
}
