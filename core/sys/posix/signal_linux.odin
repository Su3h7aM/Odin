#+build linux amd64, linux arm64, linux riscv64
package posix

import "core:c"
import "core:sys/linux"

// The Linux implementation of the signal procedures through system calls,
// without libc.

// `Signal` is cast to the kernel's `linux.Signal`, which needs them to agree.
#assert(int(Signal.SIGHUP)  == int(linux.Signal.SIGHUP))
#assert(int(Signal.SIGINT)  == int(linux.Signal.SIGINT))
#assert(int(Signal.SIGQUIT) == int(linux.Signal.SIGQUIT))
#assert(int(Signal.SIGABRT) == int(linux.Signal.SIGABRT))
#assert(int(Signal.SIGKILL) == int(linux.Signal.SIGKILL))
#assert(int(Signal.SIGSEGV) == int(linux.Signal.SIGSEGV))
#assert(int(Signal.SIGPIPE) == int(linux.Signal.SIGPIPE))
#assert(int(Signal.SIGALRM) == int(linux.Signal.SIGALRM))
#assert(int(Signal.SIGTERM) == int(linux.Signal.SIGTERM))
#assert(int(Signal.SIGCHLD) == int(linux.Signal.SIGCHLD))
#assert(int(Signal.SIGCONT) == int(linux.Signal.SIGCONT))
#assert(int(Signal.SIGSTOP) == int(linux.Signal.SIGSTOP))
#assert(int(Signal.SIGUSR1) == int(linux.Signal.SIGUSR1))
#assert(int(Signal.SIGUSR2) == int(linux.Signal.SIGUSR2))
#assert(int(Signal.SIGILL)  == int(linux.Signal.SIGILL))
#assert(int(Signal.SIGFPE)  == int(linux.Signal.SIGFPE))
#assert(int(Signal.SIGBUS)  == int(linux.Signal.SIGBUS))
#assert(int(Signal.SIGTRAP) == int(linux.Signal.SIGTRAP))
#assert(int(Signal.SIGTSTP) == int(linux.Signal.SIGTSTP))
#assert(int(Signal.SIGTTIN) == int(linux.Signal.SIGTTIN))
#assert(int(Signal.SIGTTOU) == int(linux.Signal.SIGTTOU))
#assert(int(Signal.SIGURG)  == int(linux.Signal.SIGURG))
#assert(int(Signal.SIGXCPU) == int(linux.Signal.SIGXCPU))
#assert(int(Signal.SIGXFSZ) == int(linux.Signal.SIGXFSZ))
#assert(int(Signal.SIGVTALRM) == int(linux.Signal.SIGVTALRM))
#assert(int(Signal.SIGPROF) == int(linux.Signal.SIGPROF))
#assert(int(Signal.SIGPOLL) == int(linux.Signal.SIGPOLL))
#assert(int(Signal.SIGSYS)  == int(linux.Signal.SIGSYS))

kill :: proc "c" (pid: pid_t, sig: Signal) -> result {
	return errno_result(linux.kill(linux.Pid(pid), linux.Signal(sig)))
}

killpg :: proc "c" (pgrp: pid_t, sig: Signal) -> result {
	if pgrp < 0 {
		set_errno(.EINVAL)
		return .FAIL
	}
	return errno_result(linux.kill(-linux.Pid(pgrp), linux.Signal(sig)))
}

raise :: proc "c" (sig: Signal) -> result {
	// The signal goes to this thread, so its handler has run when this returns.
	return errno_result(linux.tgkill(linux.getpid(), linux.gettid(), linux.Signal(sig)))
}

// A `sigset_t` is 1024 bits wide, while the kernel only knows the first 64 of them.
// The kernel takes and returns the mask as a single word.
#assert(size_of(linux.Sig_Set) == size_of(c.ulong))
#assert(int(Sig.BLOCK)   == int(linux.Sig_Mask_Kind.SIG_BLOCK))
#assert(int(Sig.UNBLOCK) == int(linux.Sig_Mask_Kind.SIG_UNBLOCK))
#assert(int(Sig.SETMASK) == int(linux.Sig_Mask_Kind.SIG_SETMASK))

// The highest signal number the kernel has, as `_NSIG - 1` is for libc.
@(private="file")
SIGNAL_MAX :: 64

// With libc, threads are created through it, and glibc uses two real-time
// signals to cancel a thread and to change credentials in every thread. To
// interoperate, these procedures refuse to change their action, to add them to
// a set, or to leave them blocked.
//
// The owned noCRT profile on amd64 reserves the same two numbers for its own
// asynchronous-cancel and credential-broadcast protocols, installed before
// constructors, so they are refused here as well. Raw `core:sys/linux` calls
// keep raw documented kernel behaviour and never enforce this reservation.
// User real-time signals in either profile are 34 to 64; kernel numbers, not
// a libc SIGRTMIN, which does not exist here to consult.
@(private="file")
SIGCANCEL :: 32
@(private="file")
SIGSETXID :: 33

@(private="file")
is_internal_signal :: proc "contextless" (signo: Signal) -> bool {
	when ODIN_NO_CRT && ODIN_ARCH != .amd64 {
		// No protocol owns them on this target: ordinary real-time signals.
		return false
	} else {
		return int(signo) == SIGCANCEL || int(signo) == SIGSETXID
	}
}

when ODIN_NO_CRT {
	when ODIN_ARCH == .amd64 {
		@(private="file")
		INTERNAL_SIGNALS :: uint(1) << (SIGCANCEL - 1) | uint(1) << (SIGSETXID - 1)
	} else {
		@(private="file")
		INTERNAL_SIGNALS :: uint(0)
	}
} else {
	@(private="file")
	INTERNAL_SIGNALS :: uint(1) << (SIGCANCEL - 1) | uint(1) << (SIGSETXID - 1)
}

// The mask handed to the kernel never blocks the two internal signals.
@(private)
without_internal_signals :: proc "contextless" (set: linux.Sig_Set) -> linux.Sig_Set {
	return {set[0] &~ INTERNAL_SIGNALS}
}

@(private)
to_kernel_set :: proc "contextless" (set: ^sigset_t) -> linux.Sig_Set {
	return {uint(set.__val[0])}
}

// The words past the first are cleared so a caller never sees stale bits there.
@(private="file")
from_kernel_set :: proc "contextless" (set: ^sigset_t, kernel: linux.Sig_Set) {
	set^ = {}
	set.__val[0] = c.ulong(kernel[0])
}

// Changes the calling thread's mask. The kernel's mask is per thread, so this
// is both `sigprocmask` and `pthread_sigmask`, which differ only in how they
// report the error.
@(private="file")
change_mask :: proc "contextless" (how: Sig, set: ^sigset_t, oldset: ^sigset_t) -> linux.Errno {
	new: linux.Sig_Set
	new_ptr: ^linux.Sig_Set
	if set != nil {
		new     = without_internal_signals(to_kernel_set(set))
		new_ptr = &new
	}

	old: linux.Sig_Set
	old_ptr: ^linux.Sig_Set
	if oldset != nil {
		old_ptr = &old
	}

	if err := linux.rt_sigprocmask(linux.Sig_Mask_Kind(how), new_ptr, old_ptr); err != .NONE {
		return err
	}
	if oldset != nil {
		from_kernel_set(oldset, old)
	}
	return .NONE
}

sigprocmask :: proc "c" (how: Sig, set: ^sigset_t, oldset: ^sigset_t) -> result {
	return errno_result(change_mask(how, set, oldset))
}

/*
Examine and change blocked signals.

Equivalent to sigprocmask(), without the restriction that the call be made in a single-threaded process.

Returns: the error number, without setting errno.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/pthread_sigmask.html ]]
*/
pthread_sigmask :: proc "c" (how: Sig, set: ^sigset_t, oset: ^sigset_t) -> Errno {
	return Errno(change_mask(how, set, oset))
}

sigpending :: proc "c" (set: ^sigset_t) -> result {
	if set == nil {
		set_errno(.EFAULT)
		return .FAIL
	}
	pending: linux.Sig_Set
	if err := linux.rt_sigpending(&pending); err != .NONE {
		return errno_result(err)
	}
	from_kernel_set(set, pending)
	return .OK
}

sigsuspend :: proc "c" (sigmask: ^sigset_t) -> result {
	if sigmask == nil {
		set_errno(.EFAULT)
		return .FAIL
	}
	mask := without_internal_signals(to_kernel_set(sigmask))
	return errno_result(linux.rt_sigsuspend(&mask))
}

sigaction :: proc "c" (sig: Signal, act: ^sigaction_t, oact: ^sigaction_t) -> result {
	if is_internal_signal(sig) {
		set_errno(.EINVAL)
		return .FAIL
	}

	new: linux.Sig_Action
	new_ptr: ^linux.Sig_Action
	if act != nil {
		// The flags are at the same bit positions in both, and the handler is
		// a pointer where SIG_DFL and SIG_IGN are the small values 0 and 1.
		// The restorer is left to `rt_sigaction`, which sets it where the
		// kernel requires one, and the flag that says so is not a POSIX flag.
		// riscv64 has no restorer, so `sa_restorer` is not passed there.
		new = {
			handler  = cast(linux.Sig_Handler_Fn)act.sa_handler,
			flags    = transmute(linux.Sig_Action_Flags)uint(transmute(u32)act.sa_flags),
			mask     = to_kernel_set(&act.sa_mask),
		}
		when ODIN_ARCH != .riscv64 {
			new.restorer = cast(linux.Sig_Restore_Fn)act.sa_restorer
		}
		new_ptr = &new
	}

	old: linux.Sig_Action
	old_ptr: ^linux.Sig_Action
	if oact != nil {
		old_ptr = &old
	}

	if err := linux.rt_sigaction(linux.Signal(sig), new_ptr, old_ptr); err != .NONE {
		return errno_result(err)
	}

	if oact != nil {
		RESTORER :: uint(1) << uint(linux.Sig_Action_Flag.RESTORER)
		oact^ = {
			sa_flags    = transmute(SA_Flags)u32(transmute(uint)old.flags &~ RESTORER),
		}
		when ODIN_ARCH != .riscv64 {
			oact.sa_restorer = cast(proc "c" ())old.restorer
		}
		oact.sa_handler = cast(proc "c" (Signal))old.handler
		from_kernel_set(&oact.sa_mask, old.mask)
	}
	return .OK
}

@(private="file")
signal_bit :: proc "contextless" (signo: Signal) -> (word: int, mask: c.ulong, ok: bool) {
	n := int(signo)
	if n < 1 || n > SIGNAL_MAX {
		return
	}
	BITS :: 8 * size_of(c.ulong)
	return (n - 1) / BITS, c.ulong(1) << uint((n - 1) % BITS), true
}

sigemptyset :: proc "c" (set: ^sigset_t) -> c.int {
	set^ = {}
	return 0
}

sigfillset :: proc "c" (set: ^sigset_t) -> c.int {
	set^ = {}
	set.__val[0] = ~c.ulong(INTERNAL_SIGNALS)
	return 0
}

sigaddset :: proc "c" (set: ^sigset_t, signo: Signal) -> result {
	word, mask, ok := signal_bit(signo)
	if !ok || is_internal_signal(signo) {
		set_errno(.EINVAL)
		return .FAIL
	}
	set.__val[word] |= mask
	return .OK
}

sigdelset :: proc "c" (set: ^sigset_t, signo: Signal) -> c.int {
	word, mask, ok := signal_bit(signo)
	if !ok || is_internal_signal(signo) {
		set_errno(.EINVAL)
		return -1
	}
	set.__val[word] &~= mask
	return 0
}

sigismember :: proc "c" (set: ^sigset_t, signo: Signal) -> c.int {
	word, mask, ok := signal_bit(signo)
	if !ok {
		set_errno(.EINVAL)
		return -1
	}
	return 1 if set.__val[word] & mask != 0 else 0
}

// `Sig_Stack` is the kernel's `stack_t`, which `stack_t` is cast to, and the
// flag bits are the kernel's `SS_ONSTACK` and `SS_DISABLE`.
#assert(size_of(stack_t) == size_of(linux.Sig_Stack))
#assert(offset_of(stack_t, ss_sp)    == offset_of(linux.Sig_Stack, sp))
#assert(offset_of(stack_t, ss_flags) == offset_of(linux.Sig_Stack, flags))
#assert(offset_of(stack_t, ss_size)  == offset_of(linux.Sig_Stack, size))
#assert(int(SS_Flag_Bits.ONSTACK) == int(linux.Sig_Stack_Flag.ONSTACK))
#assert(int(SS_Flag_Bits.DISABLE) == int(linux.Sig_Stack_Flag.DISABLE))

/*
Set and get the signal alternate stack context.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/sigaltstack.html ]]
*/
sigaltstack :: proc "c" (ss: ^stack_t, oss: ^stack_t) -> result {
	return errno_result(linux.sigaltstack((^linux.Sig_Stack)(ss), (^linux.Sig_Stack)(oss)))
}

// The XSI signal procedures below are the compositions that glibc and musl
// make of `sigprocmask`, `sigaction` and `sigsuspend`.

/*
Adds sig to the signal mask of the calling process.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/sighold.html ]]
*/
sighold :: proc "c" (sig: Signal) -> result {
	set: sigset_t
	if sigaddset(&set, sig) != .OK {
		return .FAIL
	}
	return sigprocmask(.BLOCK, &set, nil)
}

/*
Removes sig from the signal mask of the calling process.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/sighold.html ]]
*/
sigrelse :: proc "c" (sig: Signal) -> result {
	set: sigset_t
	if sigaddset(&set, sig) != .OK {
		return .FAIL
	}
	return sigprocmask(.UNBLOCK, &set, nil)
}

/*
Sets the disposition of sig to SIG_IGN.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/sighold.html ]]
*/
sigignore :: proc "c" (sig: Signal) -> result {
	// The handler is the integer 1, which is SIG_IGN, and the rest is zero.
	act: sigaction_t
	act.sa_handler = transmute(proc "c" (Signal))uintptr(1)
	return sigaction(sig, &act, nil)
}

/*
Removes sig from the signal mask of the calling process and suspend the calling process until
a signal is received. The mask is restored on return.

Returns: always -1, with errno EINTR once a handler has run.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/sighold.html ]]
*/
sigpause :: proc "c" (sig: Signal) -> result {
	mask: sigset_t
	if sigprocmask(.BLOCK, nil, &mask) != .OK || sigdelset(&mask, sig) != 0 {
		return .FAIL
	}
	return sigsuspend(&mask)
}

/*
Changes the restart behavior when a function is interrupted by the specified signal.

If flag is true, SA_RESTART is removed, added otherwise.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/siginterrupt.html ]]
*/
siginterrupt :: proc "c" (sig: Signal, flag: b32) -> result {
	act: sigaction_t
	if sigaction(sig, nil, &act) != .OK {
		return .FAIL
	}
	if flag {
		act.sa_flags -= {.RESTART}
	} else {
		act.sa_flags += {.RESTART}
	}
	return sigaction(sig, &act, nil)
}

/*
Wait for queued signals.

A signal handler that interrupts the wait does not end it. Like `pthread_sigmask`, this returns the
error number and does not set errno.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/sigwait.html ]]
*/
sigwait :: proc "c" (set: ^sigset_t, sig: ^Signal) -> Errno {
	if set == nil || sig == nil {
		return .EFAULT
	}
	mask := without_internal_signals(to_kernel_set(set))
	for {
		got, err := linux.rt_sigtimedwait(&mask, nil, nil)
		if err == .EINTR {
			// POSIX does not let sigwait report EINTR.
			continue
		}
		if err == .NONE {
			sig^ = Signal(got)
		}
		return Errno(err)
	}
}

/*
Set a signal handler.

func can either be:
- `auto_cast posix.SIG_DFL` setting the default handler for that specific signal
- `auto_cast posix.SIG_IGN` causing the specific signal to be ignored
- a custom signal handler

The handler stays installed after it runs, and an interrupted system call restarts, as in BSD and as
`signal` is in glibc and musl; it is `sigaction` with only `SA_RESTART`, so while the handler runs the
signal itself is blocked.

Returns: SIG_ERR (setting errno), the last value of func on success

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/signal.html ]]
*/
signal :: proc "c" (sig: Signal, func: proc "c" (Signal)) -> proc "c" (Signal) {
	act := sigaction_t{
		sa_handler = func,
		sa_flags   = {.RESTART},
	}
	old: sigaction_t
	if sigaction(sig, &act, &old) != .OK {
		return transmute(proc "c" (Signal))SIG_ERR
	}
	return old.sa_handler
}
