#+build linux
package posix

import "core:sys/linux"

// The Linux implementation of the process and user identity procedures of
// `unistd.h` through system calls, without libc.
//
// A failure is reported the same way as for the libc procedures, with `errno`.

@(private)
errno_result :: proc "contextless" (err: linux.Errno) -> result {
	if err == .NONE {
		return .OK
	}
	set_errno(Errno(err))
	return .FAIL
}

@(private)
errno_pid :: proc "contextless" (pid: linux.Pid, err: linux.Errno) -> pid_t {
	if err != .NONE {
		set_errno(Errno(err))
		return -1
	}
	return pid_t(pid)
}

getpid :: proc "c" () -> pid_t {
	return pid_t(linux.getpid())
}

getppid :: proc "c" () -> pid_t {
	return pid_t(linux.getppid())
}

getpgid :: proc "c" (pid: pid_t) -> pid_t {
	pgid, err := linux.getpgid(linux.Pid(pid))
	return errno_pid(pgid, err)
}

getsid :: proc "c" (pid: pid_t) -> pid_t {
	sid, err := linux.getsid(linux.Pid(pid))
	return errno_pid(sid, err)
}

setpgid :: proc "c" (pid: pid_t, pgid: pid_t) -> result {
	return errno_result(linux.setpgid(linux.Pid(pid), linux.Pid(pgid)))
}

setsid :: proc "c" () -> pid_t {
	sid, err := linux.setsid()
	return errno_pid(sid, err)
}

getuid :: proc "c" () -> uid_t {
	return uid_t(linux.getuid())
}

geteuid :: proc "c" () -> uid_t {
	return uid_t(linux.geteuid())
}

getgid :: proc "c" () -> gid_t {
	return gid_t(linux.getgid())
}

getegid :: proc "c" () -> gid_t {
	return gid_t(linux.getegid())
}
