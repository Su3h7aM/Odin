#+build linux
package posix

import "core:c"
import "core:sys/linux"

// The Linux implementation of the `sys/wait.h` procedures through system
// calls, without libc.
//
// A failure is reported the same way as for the libc procedures, with
// `errno`, except for the status macros, which read the status value the
// kernel wrote. A nil stat_loc is accepted everywhere and means no status
// is returned.

// The option bits match the kernel's.
#assert(int(Wait_Flag_Bits.NOHANG)    == int(linux.Wait_Option.WNOHANG))
#assert(int(Wait_Flag_Bits.UNTRACED)  == int(linux.Wait_Option.WUNTRACED))
#assert(int(Wait_Flag_Bits.CONTINUED) == int(linux.Wait_Option.WCONTINUED))
#assert(int(Wait_Flag_Bits.EXITED)    == int(linux.Wait_Option.WEXITED))
#assert(int(Wait_Flag_Bits.NOWAIT)    == int(linux.Wait_Option.WNOWAIT))
#assert(int(Wait_Flag_Bits.STOPPED)   == int(linux.Wait_Option.WSTOPPED))

// The id types match the kernel's.
#assert(int(idtype_t.P_ALL)  == int(linux.Id_Type.ALL))
#assert(int(idtype_t.P_PID)  == int(linux.Id_Type.PID))
#assert(int(idtype_t.P_PGID) == int(linux.Id_Type.PGID))

// `siginfo_t` matches the kernel siginfo layout in the fields waitid fills.
#assert(size_of(siginfo_t) == size_of(linux.Sig_Info))
#assert(offset_of(siginfo_t, si_signo)  == offset_of(linux.Sig_Info, signo))
#assert(offset_of(siginfo_t, si_code)   == offset_of(linux.Sig_Info, code))
#assert(offset_of(siginfo_t, si_pid)    == offset_of(linux.Sig_Info, pid))
#assert(offset_of(siginfo_t, si_uid)    == offset_of(linux.Sig_Info, uid))
#assert(offset_of(siginfo_t, si_status) == offset_of(linux.Sig_Info, status))

/*
Obtains status information pertaining to one of the caller's child processes.

Returns: -1 (setting errno) on failure or signal on calling process, the pid of the process that caused the return otherwise

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/wait.html ]]
*/
wait :: proc "c" (stat_loc: ^c.int) -> pid_t {
	// Waiting for any child is waitpid on -1 without options.
	return waitpid(-1, stat_loc, {})
}

/*
Obtains status information pertaining to the given pid specifier.

If pid is -1, status is requested for any child process.
If pid is greater than 0, it specifies the process ID of a single child process.
If pid is 0, it specifies any child process whose process group ID is equal to that of the call.
If pid is < -1, status is requested for any child whose process group ID is the absolute value of pid.

Returns: -1 (setting errno) on failure or signal on calling process, 0 if NOHANG and status is not available, the pid of the process that caused the return otherwise

Example:
	// The following example demonstrates the use of waitpid(), fork(), and the macros used to
	// interpret the status value returned by waitpid() (and wait()). The code segment creates a
	// child process which does some unspecified work. Meanwhile the parent loops performing calls
	// to waitpid() to monitor the status of the child. The loop terminates when child termination
	// is detected.

	child_pid := posix.fork(); switch child_pid {
	case -1: // `fork` failed.
		panic("fork failed")

	case 0:  // This is the child.

		// Do some work...

	case:
		for {
			status: i32
			wpid := posix.waitpid(child_pid, &status, { .UNTRACED, .CONTINUED })
			if wpid == -1 {
				panic("waitpid failure")
			}

			switch {
			case posix.WIFEXITED(status):
				fmt.printfln("child exited, status=%v", posix.WEXITSTATUS(status))
			case posix.WIFSIGNALED(status):
				fmt.printfln("child killed (signal %v)", posix.WTERMSIG(status))
			case posix.WIFSTOPPED(status):
				fmt.printfln("child stopped (signal %v", posix.WSTOPSIG(status))
			case posix.WIFCONTINUED(status):
				fmt.println("child continued")
			case:
				// Should never happen.
				fmt.println("unexpected status (%x)", status)
			}

			if posix.WIFEXITED(status) || posix.WIFSIGNALED(status) {
				break
			}
		}
	}

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/wait.html ]]
*/
waitpid :: proc "c" (pid: pid_t, stat_loc: ^c.int, options: Wait_Flags) -> pid_t {
	p, err := linux.wait4(linux.Pid(pid), cast(^u32)stat_loc, transmute(linux.Wait_Options)options, nil)
	if err != .NONE {
		set_errno(Errno(err))
		return -1
	}
	return pid_t(p)
}

/*
Obtains status information pertaining to the given idtype_t and id specifier.

Returns: 0 if WNOHANG and no status available, 0 if child changed state, -1 (setting errno) on failure

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/waitid.html ]]
*/
waitid :: proc "c" (idtype: idtype_t, id: id_t, infop: ^siginfo_t, options: Wait_Flags) -> c.int {
	err := linux.waitid(
		linux.Id_Type(idtype),
		linux.Id(id),
		cast(^linux.Sig_Info)infop,
		transmute(linux.Wait_Options)options,
		nil,
	)
	if err != .NONE {
		set_errno(Errno(err))
		return -1
	}
	return 0
}
