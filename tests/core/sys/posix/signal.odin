#+build linux, darwin, freebsd, openbsd, netbsd
package tests_core_posix

import "core:sys/posix"
import "core:testing"

// How often the handler ran for each signal. The tests run in parallel and each
// uses its own signal, so they do not share a count.
@(private="file")
handled: [65]int

@(private="file")
handler :: proc "c" (sig: posix.Signal) {
	handled[sig] += 1
}

@(test)
test_sigset :: proc(t: ^testing.T) {
	set: posix.sigset_t
	testing.expect_value(t, posix.sigemptyset(&set), 0)
	testing.expect_value(t, posix.sigismember(&set, .SIGUSR1), 0)

	testing.expect_value(t, posix.sigaddset(&set, .SIGUSR1), posix.result.OK)
	testing.expect_value(t, posix.sigaddset(&set, .SIGTERM), posix.result.OK)
	testing.expect_value(t, posix.sigismember(&set, .SIGUSR1), 1)
	testing.expect_value(t, posix.sigismember(&set, .SIGTERM), 1)
	testing.expect_value(t, posix.sigismember(&set, .SIGUSR2), 0)

	testing.expect_value(t, posix.sigdelset(&set, .SIGUSR1), 0)
	testing.expect_value(t, posix.sigismember(&set, .SIGUSR1), 0)
	testing.expect_value(t, posix.sigismember(&set, .SIGTERM), 1)

	testing.expect_value(t, posix.sigfillset(&set), 0)
	testing.expect_value(t, posix.sigismember(&set, .SIGUSR1), 1)
	testing.expect_value(t, posix.sigismember(&set, .SIGUSR2), 1)

	testing.expect_value(t, posix.sigemptyset(&set), 0)
	testing.expect_value(t, posix.sigismember(&set, .SIGTERM), 0)
}

@(test)
test_sigset_invalid_signal :: proc(t: ^testing.T) {
	set: posix.sigset_t
	_ = posix.sigemptyset(&set)

	for invalid in ([]posix.Signal{.NONE, posix.Signal(-1), posix.Signal(65), posix.Signal(1000)}) {
		testing.expect_value(t, posix.sigaddset(&set, invalid), posix.result.FAIL)
		testing.expect_value(t, posix.errno(), posix.Errno.EINVAL)
		testing.expect_value(t, posix.sigdelset(&set, invalid), -1)
		testing.expect_value(t, posix.errno(), posix.Errno.EINVAL)
		testing.expect_value(t, posix.sigismember(&set, invalid), -1)
		testing.expect_value(t, posix.errno(), posix.Errno.EINVAL)
	}
}

@(test)
test_sigset_internal_signals :: proc(t: ^testing.T) {
	// Signals 32 and 33 are libc's own, so they cannot be added to or removed
	// from a set, and a full set leaves them out.
	CANCEL :: posix.Signal(32)
	SETXID :: posix.Signal(33)

	set: posix.sigset_t
	_ = posix.sigemptyset(&set)
	for internal in ([]posix.Signal{CANCEL, SETXID}) {
		testing.expect_value(t, posix.sigaddset(&set, internal), posix.result.FAIL)
		testing.expect_value(t, posix.errno(), posix.Errno.EINVAL)
		testing.expect_value(t, posix.sigdelset(&set, internal), -1)
		testing.expect_value(t, posix.errno(), posix.Errno.EINVAL)
		testing.expect_value(t, posix.sigismember(&set, internal), 0)
	}

	_ = posix.sigfillset(&set)
	testing.expect_value(t, posix.sigismember(&set, CANCEL), 0)
	testing.expect_value(t, posix.sigismember(&set, SETXID), 0)
	testing.expect_value(t, posix.sigismember(&set, .SIGUSR1), 1)
	testing.expect_value(t, posix.sigismember(&set, posix.Signal(34)), 1)
	testing.expect_value(t, posix.sigismember(&set, posix.Signal(64)), 1)

	act: posix.sigaction_t
	testing.expect_value(t, posix.sigaction(CANCEL, &act, nil), posix.result.FAIL)
	testing.expect_value(t, posix.errno(), posix.Errno.EINVAL)
	testing.expect_value(t, posix.sigaction(SETXID, nil, &act), posix.result.FAIL)
	testing.expect_value(t, posix.errno(), posix.Errno.EINVAL)
}

@(test)
test_sigset_null :: proc(t: ^testing.T) {
	testing.expect_value(t, posix.sigpending(nil), posix.result.FAIL)
	testing.expect_value(t, posix.errno(), posix.Errno.EFAULT)
	testing.expect_value(t, posix.sigsuspend(nil), posix.result.FAIL)
	testing.expect_value(t, posix.errno(), posix.Errno.EFAULT)
}

@(test)
test_sigprocmask_internal_signals :: proc(t: ^testing.T) {
	// A mask with the internal signals set in it does not block them.
	set, old, now: posix.sigset_t
	set.__val[0] = max(type_of(set.__val[0]))
	testing.expect_value(t, posix.sigprocmask(.SETMASK, &set, &old), posix.result.OK)
	defer posix.sigprocmask(.SETMASK, &old, nil)

	testing.expect_value(t, posix.sigprocmask(.BLOCK, nil, &now), posix.result.OK)
	testing.expect_value(t, posix.sigismember(&now, posix.Signal(32)), 0)
	testing.expect_value(t, posix.sigismember(&now, posix.Signal(33)), 0)
	testing.expect_value(t, posix.sigismember(&now, posix.Signal(34)), 1)
}

@(test)
test_sigaction :: proc(t: ^testing.T) {
	// Querying changes nothing, and the default action is reported as no handler.
	old: posix.sigaction_t
	testing.expect_value(t, posix.sigaction(.SIGUSR1, nil, &old), posix.result.OK)
	testing.expect(t, old.sa_handler == nil, "the default action must report SIG_DFL")

	// A handler is installed with the flags and mask given, and reads back the same.
	act := posix.sigaction_t{
		sa_handler = handler,
		sa_flags   = {.RESTART},
	}
	testing.expect_value(t, posix.sigemptyset(&act.sa_mask), 0)
	testing.expect_value(t, posix.sigaddset(&act.sa_mask, .SIGUSR2), posix.result.OK)
	testing.expect_value(t, posix.sigaction(.SIGUSR1, &act, nil), posix.result.OK)

	got: posix.sigaction_t
	testing.expect_value(t, posix.sigaction(.SIGUSR1, nil, &got), posix.result.OK)
	testing.expect(t, got.sa_handler == handler, "the handler must read back")
	testing.expect_value(t, got.sa_flags, posix.SA_Flags{.RESTART})
	testing.expect_value(t, posix.sigismember(&got.sa_mask, .SIGUSR2), 1)
	testing.expect_value(t, posix.sigismember(&got.sa_mask, .SIGUSR1), 0)

	// The handler runs and returns, then the old action is put back.
	testing.expect_value(t, posix.raise(.SIGUSR1), posix.result.OK)
	testing.expect_value(t, handled[posix.Signal.SIGUSR1], 1)

	testing.expect_value(t, posix.sigaction(.SIGUSR1, &old, nil), posix.result.OK)
	testing.expect_value(t, posix.sigaction(.SIGUSR1, nil, &got), posix.result.OK)
	testing.expect(t, got.sa_handler == nil, "the old action must be back")
}

@(test)
test_sigaction_errors :: proc(t: ^testing.T) {
	act: posix.sigaction_t
	// These two cannot be caught, blocked or ignored.
	testing.expect_value(t, posix.sigaction(.SIGKILL, &act, nil), posix.result.FAIL)
	testing.expect_value(t, posix.errno(), posix.Errno.EINVAL)
	testing.expect_value(t, posix.sigaction(.SIGSTOP, &act, nil), posix.result.FAIL)
	testing.expect_value(t, posix.errno(), posix.Errno.EINVAL)

	testing.expect_value(t, posix.sigaction(.NONE, &act, nil), posix.result.FAIL)
	testing.expect_value(t, posix.errno(), posix.Errno.EINVAL)
}

@(test)
test_sigprocmask :: proc(t: ^testing.T) {
	// The signal mask is per thread, so everything done here stays on this one.
	set, old, now: posix.sigset_t
	_ = posix.sigemptyset(&set)
	_ = posix.sigaddset(&set, .SIGUSR2)

	testing.expect_value(t, posix.sigprocmask(.BLOCK, &set, &old), posix.result.OK)
	defer posix.sigprocmask(.SETMASK, &old, nil)

	testing.expect_value(t, posix.sigprocmask(.BLOCK, nil, &now), posix.result.OK)
	testing.expect_value(t, posix.sigismember(&now, .SIGUSR2), 1)

	testing.expect_value(t, posix.sigprocmask(.UNBLOCK, &set, nil), posix.result.OK)
	testing.expect_value(t, posix.sigprocmask(.BLOCK, nil, &now), posix.result.OK)
	testing.expect_value(t, posix.sigismember(&now, .SIGUSR2), 0)

	testing.expect_value(t, posix.sigprocmask(.SETMASK, &set, nil), posix.result.OK)
	testing.expect_value(t, posix.sigprocmask(.BLOCK, nil, &now), posix.result.OK)
	testing.expect_value(t, posix.sigismember(&now, .SIGUSR2), 1)

	// An unknown way to change the mask is refused.
	testing.expect_value(t, posix.sigprocmask(posix.Sig(99), &set, nil), posix.result.FAIL)
	testing.expect_value(t, posix.errno(), posix.Errno.EINVAL)
}

@(test)
test_sigpending_sigsuspend :: proc(t: ^testing.T) {
	act := posix.sigaction_t{sa_handler = handler}
	_ = posix.sigemptyset(&act.sa_mask)
	old_act: posix.sigaction_t
	testing.expect_value(t, posix.sigaction(.SIGUSR2, &act, &old_act), posix.result.OK)
	defer posix.sigaction(.SIGUSR2, &old_act, nil)

	blocked, old_mask, empty, pending: posix.sigset_t
	_ = posix.sigemptyset(&blocked)
	_ = posix.sigemptyset(&empty)
	_ = posix.sigaddset(&blocked, .SIGUSR2)
	testing.expect_value(t, posix.sigprocmask(.BLOCK, &blocked, &old_mask), posix.result.OK)
	defer posix.sigprocmask(.SETMASK, &old_mask, nil)

	// A blocked signal is held back, and shows as pending.
	testing.expect_value(t, posix.raise(.SIGUSR2), posix.result.OK)
	testing.expect_value(t, handled[posix.Signal.SIGUSR2], 0)
	testing.expect_value(t, posix.sigpending(&pending), posix.result.OK)
	testing.expect_value(t, posix.sigismember(&pending, .SIGUSR2), 1)

	// Suspending with an empty mask lets it through, and the call then fails with EINTR.
	testing.expect_value(t, posix.sigsuspend(&empty), posix.result.FAIL)
	testing.expect_value(t, posix.errno(), posix.Errno.EINTR)
	testing.expect_value(t, handled[posix.Signal.SIGUSR2], 1)

	// The handler consumed the signal, and the mask from before the suspend is back.
	testing.expect_value(t, posix.sigpending(&pending), posix.result.OK)
	testing.expect_value(t, posix.sigismember(&pending, .SIGUSR2), 0)
	now: posix.sigset_t
	testing.expect_value(t, posix.sigprocmask(.BLOCK, nil, &now), posix.result.OK)
	testing.expect_value(t, posix.sigismember(&now, .SIGUSR2), 1)
}
