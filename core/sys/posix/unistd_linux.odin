#+build linux
package posix

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:sys/linux"
import env "core:sys/_env"

_ :: env

_ :: runtime

// The Linux implementation of the process and user identity procedures of
// `unistd.h` through system calls, without libc.
//
// A failure is reported the same way as for the libc procedures, with `errno`.

// `linux.lseek` takes the matching seek origin, and `off_t` is the kernel's
// 64-bit offset, so values convert without loss.
#assert(int(Whence.SET) == int(linux.Seek_Whence.SET))
#assert(int(Whence.CUR) == int(linux.Seek_Whence.CUR))
#assert(int(Whence.END) == int(linux.Seek_Whence.END))
#assert(size_of(off_t) == size_of(i64))

@(private)
errno_result :: proc "contextless" (err: linux.Errno) -> result {
	if err == .NONE {
		return .OK
	}
	set_errno(Errno(err))
	return .FAIL
}

@(private)
errno_int :: proc "contextless" (n: int, err: linux.Errno) -> c.int {
	if err != .NONE {
		set_errno(Errno(err))
		return -1
	}
	return c.int(n)
}

@(private)
errno_pid :: proc "contextless" (pid: linux.Pid, err: linux.Errno) -> pid_t {
	if err != .NONE {
		set_errno(Errno(err))
		return -1
	}
	return pid_t(pid)
}

@(private)
errno_fd :: proc "contextless" (fd: linux.Fd, err: linux.Errno) -> FD {
	if err != .NONE {
		set_errno(Errno(err))
		return -1
	}
	return FD(fd)
}

@(private)
errno_ssize :: proc "contextless" (n: int, err: linux.Errno) -> c.ssize_t {
	if err != .NONE {
		set_errno(Errno(err))
		return -1
	}
	return c.ssize_t(n)
}

@(private)
errno_off :: proc "contextless" (off: i64, err: linux.Errno) -> off_t {
	if err != .NONE {
		set_errno(Errno(err))
		return -1
	}
	return off_t(off)
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

/*
Deallocates the file descriptor indicated by fildes.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/close.html ]]
*/
close :: proc "c" (fildes: FD) -> result {
	// Linux always releases the descriptor, even when it reports EINTR.
	// POSIX reads EINTR as the descriptor still being open, which invites a
	// retry that may close a number another thread just received, so report
	// success instead.
	err := linux.close(linux.Fd(fildes))
	if err == .EINTR {
		err = .NONE
	}
	return errno_result(err)
}

/*
Returns a new file descriptor referring to the one given, sharing locks, clearing CLOEXEC.

Returns: -1 (setting errno) on failure, the new file descriptor on success

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/dup.html ]]
*/
dup :: proc "c" (fildes: FD) -> FD {
	fd, err := linux.dup(linux.Fd(fildes))
	return errno_fd(fd, err)
}

/*
Causes the file descriptor fildes2 to refer to the same open file description as
the file descriptor fildes and to share any locks, and shall return fildes2.

Returns: -1 (setting errno) on failure, fildes2 on success

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/dup.html ]]
*/
dup2 :: proc "c" (fildes, fildes2: FD) -> FD {
	// EBUSY from a race with open or dup passes through as documented.
	// The oldfd == newfd case is handled inside `linux.dup2`.
	fd, err := linux.dup2(linux.Fd(fildes), linux.Fd(fildes2))
	return errno_fd(fd, err)
}

/*
Create an interprocess channel.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/pipe.html ]]
*/
pipe :: proc "c" (fildes: ^[2]FD) -> result {
	// There is no pipe syscall on arm64 and riscv64, so pipe2 with no flags
	// serves every architecture.
	return errno_result(linux.pipe2(cast(^[2]linux.Fd)fildes, {}))
}

tcgetpgrp :: proc "c" (fildes: FD) -> pid_t {
	pgrp: linux.Pid
	_, err := linux.ioctl(linux.Fd(fildes), linux.TIOCGPGRP, uintptr(&pgrp))
	return errno_pid(pgrp, err)
}

tcsetpgrp :: proc "c" (fildes: FD, pgid_id: pid_t) -> result {
	pgrp := linux.Pid(pgid_id)
	_, err := linux.ioctl(linux.Fd(fildes), linux.TIOCSPGRP, uintptr(&pgrp))
	return errno_result(err)
}

/*
Read from a file.

Returns: the amount of bytes read or -1 (setting errno) on failure

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/pread.html ]]
*/
read :: proc "c" (fd: FD, buf: [^]byte, nbyte: c.size_t) -> c.ssize_t {
	b: []u8
	if nbyte > 0 {
		b = ([^]u8)(buf)[:nbyte]
	}
	n, err := linux.read(linux.Fd(fd), b)
	return errno_ssize(n, err)
}

/*
Equivalent to read on a specified offset instead of the internal offset.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/pread.html ]]
*/
pread :: proc "c" (fd: FD, buf: [^]byte, nbyte: c.size_t, offset: off_t) -> c.ssize_t {
	b: []u8
	if nbyte > 0 {
		b = ([^]u8)(buf)[:nbyte]
	}
	n, err := linux.pread(linux.Fd(fd), b, i64(offset))
	return errno_ssize(n, err)
}

/*
Write on a file.

Returns: the amount of bytes written or -1 (setting errno) on failure.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/write.html ]]
*/
write :: proc "c" (fd: FD, buf: [^]byte, buflen: c.size_t) -> c.ssize_t {
	b: []u8
	if buflen > 0 {
		b = ([^]u8)(buf)[:buflen]
	}
	n, err := linux.write(linux.Fd(fd), b)
	return errno_ssize(n, err)
}

/*
Equivalent to write on a specified offset instead of the internal offset.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/write.html ]]
*/
pwrite :: proc "c" (fd: FD, buf: [^]byte, buflen: c.size_t, offset: off_t) -> c.ssize_t {
	// A negative offset is never a valid position, so fail before any call
	// can mistake it for the current offset.
	if offset < 0 {
		set_errno(.EINVAL)
		return -1
	}
	// pwritev2 with RWF_NOAPPEND writes at the offset even on an O_APPEND
	// descriptor (Linux 6.9); plain pwrite would append instead.
	vec := [1]linux.IO_Vec{{base = ([^]byte)(buf), len = uint(buflen)}}
	n, err := linux.pwritev2(linux.Fd(fd), vec[:], i64(offset), {.NOAPPEND})
	if err != .EOPNOTSUPP && err != .ENOSYS {
		return errno_ssize(n, err)
	}
	// Without pwritev2 an O_APPEND descriptor cannot do positional writes,
	// so fail instead of appending elsewhere.
	flags, ferr := linux.fcntl_getfl(linux.Fd(fd), linux.F_GETFL)
	if ferr != .NONE {
		return errno_ssize(0, ferr)
	}
	if .APPEND in flags {
		return errno_ssize(0, .EOPNOTSUPP)
	}
	b: []u8
	if buflen > 0 {
		b = ([^]u8)(buf)[:buflen]
	}
	n, err = linux.pwrite(linux.Fd(fd), b, i64(offset))
	return errno_ssize(n, err)
}

/*
Sets the file offset of the given file descriptor.

If whence is .SET, the offset is set
If whence is .CUR, the offset is the current offset + given offset
If whence is .END, the offset is set to the size of the file + given offset

Returns: the resulting offset or -1 (setting errno)

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/lseek.html ]]
*/
lseek :: proc "c" (fildes: FD, offset: off_t, whence: Whence) -> off_t {
	off, err := linux.lseek(linux.Fd(fildes), i64(offset), linux.Seek_Whence(int(whence)))
	return errno_off(off, err)
}

/*
Requests that all data for the open file descriptor named by fildes is to be transferred
to the storage device associated with the file described by fildes.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/fsync.html ]]
*/
fsync :: proc "c" (fildes: FD) -> result {
	return errno_result(linux.fsync(linux.Fd(fildes)))
}

/*
Forcec all currently queued I/O operations associated with the file indicated by file descriptor
fildes to the synchronized I/O completion state.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/fdatasync.html ]]
*/
fdatasync :: proc "c" (fd: FD) -> result {
	return errno_result(linux.fdatasync(linux.Fd(fd)))
}

/*
Truncates a file to the specified length.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/ftruncate.html ]]
*/
ftruncate :: proc "c" (fildes: FD, length: off_t) -> result {
	return errno_result(linux.ftruncate(linux.Fd(fildes), i64(length)))
}

// The access mode bits match the kernel's.
#assert(int(Mode_Flag_Bits.X_OK) == int(linux.Mode_Bits.IXOTH))
#assert(int(Mode_Flag_Bits.W_OK) == int(linux.Mode_Bits.IWOTH))
#assert(int(Mode_Flag_Bits.R_OK) == int(linux.Mode_Bits.IROTH))

/*
Checks the file named by the pathname pointed to by the path argument for
accessibility according to the bit pattern contained in amode.

Example:
	if (posix.access("/tmp/myfile", posix.F_OK) != .OK) {
		fmt.printfln("/tmp/myfile access check failed: %v", posix.strerror(posix.errno()))
	}

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/access.html ]]
*/
access :: proc "c" (path: cstring, amode: Mode_Flags = F_OK) -> result {
	return errno_result(linux.access(path, transmute(linux.Mode)amode))
}

/*
Equivalent to `access` but relative paths are resolved based on `fd`.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/access.html ]]
*/
faccessat :: proc "c" (fd: FD, path: cstring, amode: Mode_Flags, flag: AT_Flags) -> result {
	mode := transmute(linux.Mode)amode
	if flag == {} {
		return errno_result(linux.faccessat(linux.Fd(fd), path, mode))
	}
	// The older faccessat system call takes no flags; flags go through
	// faccessat2 (Linux 5.8), whose result, ENOSYS included, is returned.
	return errno_result(linux.faccessat2(linux.Fd(fd), path, mode, transmute(linux.FD_Flags)flag))
}

/*
Causes the directory named by path to become the current working directory.

Example:
	if (posix.chdir("/tmp") == .OK) {
		fmt.println("changed current directory to /tmp")
	}

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/chdir.html ]]
*/
chdir :: proc "c" (path: cstring) -> result {
	return errno_result(linux.chdir(path))
}

/*
Equivalent to chdir but instead of a path the fildes is resolved to a directory.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/fchdir.html ]]
*/
fchdir :: proc "c" (fildes: FD) -> result {
	return errno_result(linux.fchdir(linux.Fd(fildes)))
}

/*
Places an absolute pathname of the current working directory into buf.

Returns: buf as a cstring on success, nil (setting errno) on failure

On Linux a nil buf or a zero size reports EINVAL: no buffer is allocated.
A working directory path longer than the kernel's PATH_MAX gives ENAMETOOLONG.

Example:
	size: int
	path_max := posix.pathconf(".", ._PATH_MAX)
	if path_max == -1 {
		size = 1024
	} else if path_max > 10240 {
		size = 10240
	} else {
		size = int(path_max)
	}

	buf: [dynamic]byte
	cwd: cstring
	for ; cwd == nil; size *= 2 {
		if err := resize(&buf, size); err != nil {
			fmt.panicf("allocation failure: %v", err)
		}

		cwd = posix.getcwd(raw_data(buf), len(buf))
		if cwd == nil {
			errno := posix.errno()
			if errno != .ERANGE {
				fmt.panicf("getcwd failure: %v", posix.strerror(errno))
			}
		}
	}

	fmt.println(path_max, cwd)

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/getcwd.html ]]
*/
getcwd :: proc "c" (buf: [^]c.char, size: c.size_t) -> cstring {
	// A nil buffer or a zero size reports EINVAL: this procedure has no
	// allocator to hand out memory with.
	if buf == nil || size == 0 {
		set_errno(.EINVAL)
		return nil
	}
	b := ([^]u8)(buf)[:size]
	n, err := linux.getcwd(b)
	if err != .NONE {
		set_errno(Errno(err))
		return nil
	}
	// The kernel prefixes "(unreachable)" when the working directory is
	// outside the process root; that breaks the absolute-path promise, so
	// report ENOENT.
	if n == 0 || b[0] != '/' {
		set_errno(.ENOENT)
		return nil
	}
	return cstring(buf)
}

/*
Remove an (empty) directory.

]] More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/rmdir.html ]]
*/
rmdir :: proc "c" (path: cstring) -> result {
	return errno_result(linux.rmdir(path))
}

/*
Remove a directory entry.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/unlink.html ]]
*/
unlink :: proc "c" (path: cstring) -> result {
	return errno_result(linux.unlink(path))
}

/*
Equivalent to unlink or rmdir (if flag is .REMOVEDIR) but relative paths are relative to the dir fd.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/unlink.html ]]
*/
unlinkat :: proc "c" (fd: FD, path: cstring, flag: AT_Flags) -> result {
	return errno_result(linux.unlinkat(linux.Fd(fd), path, transmute(linux.FD_Flags)flag))
}

/*
Creates a new link for the existing file path1 to path2.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/link.html ]]
*/
link :: proc "c" (path1: cstring, path2: cstring) -> result {
	return errno_result(linux.link(path1, path2))
}

/*
If path1 is relative it is relative to directory fd1.
If path2 is relative it is relative to directory fd2.
If flag is { .SYMLINK_FOLLOW } path1 is resolved to its link if it is a link.
Equivalent to link otherwise.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/link.html ]]
*/
linkat :: proc "c" (fd1: FD, path1: cstring, fd2: FD, path2: cstring, flag: AT_Flags) -> result {
	return errno_result(linux.linkat(linux.Fd(fd1), path1, linux.Fd(fd2), path2, transmute(linux.FD_Flags)flag))
}

/*
Creates a symbolic link called path2 that contains a link to path1.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/symlink.html ]]
*/
symlink :: proc "c" (path1: cstring, path2: cstring) -> result {
	return errno_result(linux.symlink(path1, path2))
}

/*
Equivalent to symlink but relative paths are resolved to dir fd.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/symlink.html ]]
*/
symlinkat :: proc "c" (path1: cstring, fd: FD, path2: cstring) -> result {
	return errno_result(linux.symlinkat(path1, linux.Fd(fd), path2))
}

/*
Read the contents of a symbolic link.

Returns: the amount of bytes read or -1 (setting errno) on failure.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/readlink.html ]]
*/
readlink :: proc "c" (path: cstring, buf: [^]byte, bufsize: c.size_t) -> c.ssize_t {
	if bufsize == 0 {
		// A zero size still validates the link through a dummy buffer and
		// reports success as 0.
		dummy: [1]u8
		_, err := linux.readlink(path, dummy[:])
		return errno_ssize(0, err)
	}
	b := ([^]u8)(buf)[:bufsize]
	n, err := linux.readlink(path, b)
	return errno_ssize(n, err)
}

/*
Equivalent to readlink but relative paths are resolved based on the dir fd.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/readlink.html ]]
*/
readlinkat :: proc "c" (fd: FD, path: cstring, buf: [^]byte, bufsize: c.size_t) -> c.ssize_t {
	if bufsize == 0 {
		// A zero size still validates the link through a dummy buffer and
		// reports success as 0.
		dummy: [1]u8
		_, err := linux.readlinkat(linux.Fd(fd), path, dummy[:])
		return errno_ssize(0, err)
	}
	b := ([^]u8)(buf)[:bufsize]
	n, err := linux.readlinkat(linux.Fd(fd), path, b)
	return errno_ssize(n, err)
}

/*
Changes the user and group ownership of a file.

If owner or group is specified as (uid_t)-1 or (gid_t)-1, respectively, the corresponding ID of the file shall not be changed.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/chown.html ]]
*/
chown :: proc "c" (path: cstring, owner: uid_t, group: gid_t) -> result {
	return errno_result(linux.chown(path, linux.Uid(owner), linux.Gid(group)))
}

/*
Equivalent to chown expect that it takes a file descriptor.

Example:
	fildes := posix.open("/home/cnd/mod1", {.RDWR})
	pwd := posix.getpwnam("jones")
	grp := posix.getgrnam("cnd")
	posix.fchown(fildes, pwd.pw_uid, grp.gr_gid)

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/fchown.html ]]
*/
fchown :: proc "c" (fildes: FD, owner: uid_t, mode: gid_t) -> result {
	return errno_result(linux.fchown(linux.Fd(fildes), linux.Uid(owner), linux.Gid(mode)))
}

/*
Equivalent to fchown except that relative paths are based on the given fildes.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/chown.html ]]
*/
fchownat :: proc "c" (fildes: FD, path: cstring, owner: uid_t, group: gid_t, flag: AT_Flags) -> result {
	return errno_result(
		linux.fchownat(linux.Fd(fildes), path, linux.Uid(owner), linux.Gid(group), transmute(linux.FD_Flags)flag),
	)
}

/*
If path points to a symbolic link, the owner and group of the link itself is changed.
Equivalent to chown on normal files.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/lchown.html ]]
*/
lchown :: proc "c" (path: cstring, owner: uid_t, group: gid_t) -> result {
	return errno_result(linux.lchown(path, linux.Uid(owner), linux.Gid(group)))
}

/*
Truncates a file to the specified length.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/truncate.html ]]
*/
truncate :: proc "c" (path: cstring, length: off_t) -> result {
	// A negative length passes through; the kernel rejects it with EINVAL.
	return errno_result(linux.truncate(path, i64(length)))
}

// The Linux implementation of the remaining `unistd.h` process, sleep and
// system procedures through system calls, without libc.
//
// A failure is reported the same way as for the libc procedures, with `errno`.

/*
Exits but, shall not call functions registered with atexit() nor any registered signal handlers.
Open streams shall not be flushed.
Whether open streams are closed (without flushing) is implementation-defined. Finally, the calling process shall be terminated with the consequences described below.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/_exit.html ]]
*/
_exit :: proc "c" (status: c.int) -> ! {
	// POSIX ends the whole process; exit_group ends the thread group while
	// exit would end only the calling thread.
	linux.exit_group(i32(status))
}

/*
The alarm() function shall cause the system to generate a SIGALRM signal for the process after the number of realtime seconds specified by seconds have elapsed. Processor scheduling delays may prevent the process from handling the signal as soon as it is generated.

If seconds is 0, a pending alarm request, if any, is canceled.

Returns: the time left on the previous alarm() or 0

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/alarm.html ]]
*/
alarm :: proc "c" (seconds: c.uint) -> c.uint {
	// linux.alarm carries the per-architecture call with the kernel's
	// rounding; c.uint is 32 bits on Linux, so the values convert exactly.
	return c.uint(linux.alarm(u32(seconds)))
}

/*
Returns the standard host name for the current machine.

Host names are limited to HOST_NAME_MAX bytes.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/gethostname.html ]]
*/
gethostname :: proc "c" (name: [^]c.char, namelen: c.size_t) -> result {
	uts: linux.UTS_Name
	if err := linux.uname(&uts); err != .NONE {
		set_errno(Errno(err))
		return .FAIL
	}
	// Like Linux libc, a short buffer gets namelen bytes without a NUL and
	// fails with ENAMETOOLONG. A full buffer includes the terminating NUL.
	n := 0
	for n < len(uts.nodename) && uts.nodename[n] != 0 {
		n += 1
	}
	count := min(uint(n + 1), uint(namelen))
	for i in 0..<count {
		name[i] = c.char(uts.nodename[i])
	}
	if uint(namelen) <= uint(n) {
		set_errno(.ENAMETOOLONG)
		return .FAIL
	}
	return .OK
}

/*
Tests whether fildes is associated with a terminal device.

Returns: false (setting errno) if fildes is invalid or not a terminal, true otherwise

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/isatty.html ]]
*/
isatty :: proc "c" (fildes: FD) -> b32 {
	// Raw TCGETS probe: the kernel copies out the terminal attributes on
	// success and fails with ENOTTY otherwise.
	termios: linux.Termios
	_, err := linux.ioctl(linux.Fd(fildes), linux.TCGETS, uintptr(rawptr(&termios)))
	if err != .NONE {
		set_errno(Errno(err))
		return false
	}
	return true
}

/*
Changes the nice value of a process.

Higher values result in less favorable scheduling.

Because -1 is a valid nice value, checking failure would be done by first setting errno to .NONE
and then calling nice.

Returns: the new nice value, or -1 (setting) errno on failure

Example:
	posix.set_errno(.NONE)
	niceness := posix.nice(-20)
	if errno := posix.errno(); niceness == -1 && errno != .NONE {
		fmt.panicf("nice failure: %v", posix.strerror(errno))
	}
	fmt.printfln("Niceness is now: %v", niceness)

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/nice.html ]]
*/
nice :: proc "c" (incr: c.int) -> c.int {
	// A legitimate result can be -1, so errno is only set on real failures
	// and left alone on success. The value is read back because the kernel
	// clamps it into range.
	prio, gerr := linux.getpriority(linux.Priority_Which.PROCESS, 0)
	if gerr != .NONE {
		set_errno(Errno(gerr))
		return -1
	}
	target := i32(clamp(i64(prio) + i64(incr), -20, 19))
	if serr := linux.setpriority(linux.Priority_Which.PROCESS, 0, target); serr != .NONE {
		set_errno(.EPERM if serr == .EACCES else Errno(serr))
		return -1
	}
	prio, gerr = linux.getpriority(linux.Priority_Which.PROCESS, 0)
	if gerr != .NONE {
		set_errno(Errno(gerr))
		return -1
	}
	return c.int(prio)
}

/*
Suspend the thread until a signal is received.

Returns: -1 (setting errno to EINTR)

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/pause.html ]]
*/
pause :: proc "c" () -> c.int {
	// The wait only ends for a caught signal, which the kernel reports as EINTR.
	linux.pause()
	set_errno(.EINTR)
	return -1
}

/*
Suspend execution for an interval of time.

Returns: the time left to sleep (may be > 0 in case of signals)

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/sleep.html ]]
*/
sleep :: proc "c" (seconds: c.uint) -> c.uint {
	if seconds == 0 {
		return 0
	}
	req := linux.Time_Spec{ time_sec = uint(seconds) }
	rem := linux.Time_Spec{}
	if err := linux.nanosleep(&req, &rem); err == .NONE {
		return 0
	} else if err == .EINTR {
		// A caught signal leaves the remainder behind; any unslept
		// fraction counts as a whole second.
		unslept := rem.time_sec
		if rem.time_nsec > 0 {
			unslept += 1
		}
		return c.uint(unslept)
	}
	return seconds
}

/*
Schedule file system updates.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/sync.html ]]
*/
sync :: proc "c" () {
	// The call always succeeds, so there is nothing to report.
	_ = linux.sync()
}

// `gid_t` converts to the kernel's `Gid` without loss.
#assert(size_of(gid_t) == size_of(linux.Gid))

/*
The exec family of functions shall replace the current process image with a new process image.
The new image shall be constructed from a regular, executable file called the new process image file.
There shall be no return from a successful exec,
because the calling process image is overlaid by the new process image.

Takes arguments as an array which should be nil terminated.

Example:
	args := []cstring{ "ls", "-l", nil }
	ret := posix.execv("/bin/ls", raw_data(args))
	fmt.panicf("could not execute: %v, %v", ret, posix.strerror(posix.errno()))

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/execl.html ]]
*/
execv :: proc "c" (path: cstring, argv: [^]cstring) -> c.int {
	// execv is async-signal-safe, including a handler that interrupted an
	// environment operation. Do not lock or allocate here. As with direct
	// environ access, callers synchronize concurrent environment mutation.
	set_errno(Errno(linux.execve(path, argv, environ)))
	return -1
}


when ODIN_NO_CRT {
	// Without libc linked there are no atfork handlers to run and no libc
	// locks to reset. With libc, fork stays with the C library, whose
	// handlers keep its internal state consistent across the fork. The owned
	// thread registry still needs its child reset below: its spinlock may be
	// held by a thread that did not survive, and every other entry is dead.
	// Heap and temp-allocator state are deliberately not touched here; the
	// child must stay allocation-free until exec, and resetting allocator
	// locks alone could expose half-mutated state.

	/*
	The fork() function shall create a new process.
	The new process (child process) shall be an exact copy of the calling process (parent process).
	With some exceptions outlined below.

	Result: -1 (setting errno) on failure, otherwise 0 to the child process and the child process id to the parent process.

	[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/fork.html ]]
	*/
	fork :: proc "c" () -> pid_t {
		pid, err := linux.fork()
		if err != .NONE {
			set_errno(Errno(err))
			return -1
		}
		if pid == 0 {
			when ODIN_ARCH == .amd64 {
				// Async-signal-safe: plain stores only. The child keeps its
				// TLS registry node (never a tid scan: the new tid matches
				// no old entry), drops dead siblings, and re-syncs tid,
				// pid, and credential epoch without allocating.
				runtime._owned_thread_registry_atfork_child()
			}
		}
		return pid_t(pid)
	}


	// The raw credential calls affect only the calling thread. libc
	// broadcasts them to every thread as POSIX requires. The owned protocol
	// below applies them the same way on amd64 through a single runtime
	// call per wrapper: the runtime preflights everything that can fail
	// without mutation (lock, snapshot allocation, cancel deferral,
	// argument copy), applies the caller, then converges every other live
	// owned thread through a targeted signal with a recorded per-thread
	// result. Success (0) means all of them applied; a failed direct apply
	// returns before any mutation, and any failure once mutation is
	// possible terminates the whole process (fail-closed: irreversible
	// credential changes cannot roll back, so an ordinary error over
	// possibly divergent threads would be fail-open). No wrapper applies a
	// credential directly and broadcasts after: that order would return an
	// ordinary error with the caller's credential already changed. Other
	// architectures keep the direct per-thread call.
	//
	// Coverage note, not a completeness claim: the six coordinated setters
	// here are setuid, setgid, seteuid, setegid, setreuid, and setregid.
	// Supplementary groups have no owned wrapper: raw `linux.setgroups`
	// keeps documented per-thread kernel behaviour, and callers needing
	// process-wide group changes have no coordinated primitive in this
	// profile. Likewise there are no owned setresuid/setresgid wrappers;
	// the res-family ops exist only as broadcast kinds used internally by
	// seteuid/setegid.

	/*
	Set user ID.

	[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/setuid.html ]]
	*/
	setuid :: proc "c" (uid: uid_t) -> result {
		when ODIN_ARCH == .amd64 {
			// A failed call must not leave the caller's UID changed: the
			// runtime applies the caller only after preflight, and a failed
			// direct apply returns before any mutation.
			if berr := runtime._owned_credentials_broadcast(u32(runtime.Owned_Cred_Op.Set_Uid), i64(uid), 0, 0); berr != 0 {
				set_errno(cast(Errno)(-berr))
				return .FAIL
			}
			return .OK
		} else {
			return errno_result(linux.setuid(linux.Uid(uid)))
		}
	}

	/*
	Sets the group ID.

	[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/setgid.html ]]
	*/
	setgid :: proc "c" (gid: gid_t) -> result {
		when ODIN_ARCH == .amd64 {
			if berr := runtime._owned_credentials_broadcast(u32(runtime.Owned_Cred_Op.Set_Gid), i64(gid), 0, 0); berr != 0 {
				set_errno(cast(Errno)(-berr))
				return .FAIL
			}
			return .OK
		} else {
			return errno_result(linux.setgid(linux.Gid(gid)))
		}
	}

	/*
	Sets the effective user ID.

	[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/seteuid.html ]]
	*/
	seteuid :: proc "c" (uid: uid_t) -> result {
		// Keep both real and saved IDs, as seteuid(2) requires.
		when ODIN_ARCH == .amd64 {
			if berr := runtime._owned_credentials_broadcast(u32(runtime.Owned_Cred_Op.Set_Res_Uid), -1, i64(uid), -1); berr != 0 {
				set_errno(cast(Errno)(-berr))
				return .FAIL
			}
			return .OK
		} else {
			return errno_result(linux.setresuid(transmute(linux.Uid)i32(-1), linux.Uid(uid), transmute(linux.Uid)i32(-1)))
		}
	}

	/*
	Set the effective group ID.

	[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/setegid.html ]]
	*/
	setegid :: proc "c" (gid: gid_t) -> result {
		// Keep both real and saved IDs, as seteuid(2) requires.
		when ODIN_ARCH == .amd64 {
			if berr := runtime._owned_credentials_broadcast(u32(runtime.Owned_Cred_Op.Set_Res_Gid), -1, i64(gid), -1); berr != 0 {
				set_errno(cast(Errno)(-berr))
				return .FAIL
			}
			return .OK
		} else {
			return errno_result(linux.setresgid(transmute(linux.Gid)i32(-1), linux.Gid(gid), transmute(linux.Gid)i32(-1)))
		}
	}

	/*
	Set real and effective user IDs.

	[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/setreuid.html ]]
	*/
	setreuid :: proc "c" (ruid: uid_t, euid: uid_t) -> result {
		when ODIN_ARCH == .amd64 {
			if berr := runtime._owned_credentials_broadcast(u32(runtime.Owned_Cred_Op.Set_Re_Uid), i64(ruid), i64(euid), 0); berr != 0 {
				set_errno(cast(Errno)(-berr))
				return .FAIL
			}
			return .OK
		} else {
			return errno_result(linux.setreuid(linux.Uid(ruid), linux.Uid(euid)))
		}
	}

	/*
	Set the real and effective group IDs.

	[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/setregid.html ]]
	*/
	setregid :: proc "c" (rgid: gid_t, egid: gid_t) -> result {
		when ODIN_ARCH == .amd64 {
			if berr := runtime._owned_credentials_broadcast(u32(runtime.Owned_Cred_Op.Set_Re_Gid), i64(rgid), i64(egid), 0); berr != 0 {
				set_errno(cast(Errno)(-berr))
				return .FAIL
			}
			return .OK
		} else {
			return errno_result(linux.setregid(linux.Gid(rgid), linux.Gid(egid)))
		}
	}
}

// Looks up a name in an independent environment snapshot.
@(private="file")
_exec_getenv :: proc "contextless" (envp: [^]cstring, name: string) -> cstring {
	if envp == nil {
		return nil
	}
	i := 0
	for envp[i] != nil {
		eb := ([^]byte)(envp[i])
		match := true
		for j in 0..<len(name) {
			if eb[j] != name[j] {
				match = false
				break
			}
		}
		if match && eb[len(name)] == '=' {
			return cstring(&eb[len(name) + 1])
		}
		i += 1
	}
	return nil
}

// Runs /bin/sh on a file execve rejected as ENOEXEC, with the file as
// its first argument. Only returns on failure, with errno set.
@(private="file")
_exec_shell :: proc "contextless" (file: cstring, argv: [^]cstring, envp: [^]cstring) -> c.int {
	argc := 0
	for argv[argc] != nil {
		if argc >= int(max(c.int)) - 1 || argc >= max(int) / size_of(cstring) - 2 {
			set_errno(.E2BIG)
			return -1
		}
		argc += 1
	}
	// Keep valid argument vectors subject to Linux execve limits, not a
	// fixed local array. The extra entries are the shell, file and sentinel.
	count := max(argc + 2, 3)
	sh_argv := cast([^]cstring)intrinsics.alloca(count * size_of(cstring), align_of(cstring))
	sh_argv[0] = "/bin/sh"
	sh_argv[1] = file
	if argc > 1 {
		for i in 1..<argc {
			sh_argv[i + 1] = argv[i]
		}
		sh_argv[argc + 1] = nil
	} else {
		sh_argv[2] = nil
	}
	set_errno(Errno(linux.execve("/bin/sh", sh_argv, envp)))
	return -1
}

// Searches PATH for file like execvp does. A slash means a path, not a
// name to look up. EACCES keeps searching and is reported when nothing
// else is found; ENOEXEC runs the shell and stops the search; any other
// error returns at once. Only returns on failure, with errno set.
@(private="file")
_execvpe :: proc "contextless" (file: cstring, argv: [^]cstring, envp: [^]cstring) -> c.int {
	fb := ([^]byte)(file)
	if fb[0] == 0 {
		set_errno(.ENOENT)
		return -1
	}
	// Without a slash the name is sought in each PATH entry; an empty
	// entry means the working directory, so the bare file is tried.
	if !_has_slash(file) {
		// A name longer than any entry can hold fails as execve itself
		// would fail it.
		f := 0
		for fb[f] != 0 {
			f += 1
		}
		if f > 255 {
			set_errno(.ENAMETOOLONG)
			return -1
		}
		pstr := _exec_getenv(envp, "PATH")
		if pstr == nil {
			// confstr(_CS_PATH) is "/bin:/usr/bin" on Linux.
			pstr = "/bin:/usr/bin"
		}
		path := ([^]byte)(pstr)
		seen_eacces := false
		i := 0
		for {
			j := i
			for path[j] != 0 && path[j] != ':' {
				j += 1
			}
			buf: [4096]byte
			n := j - i
			// Check the whole candidate before copying even the directory.
			// Entries too long to try are skipped, as in musl execvp.
			separator := 1 if n > 0 else 0
			if n <= len(buf) - separator - f - 1 {
				for k in 0..<n {
					buf[k] = path[i + k]
				}
				if separator != 0 {
					buf[n] = '/'
					n += 1
				}
				for k in 0..<f {
					buf[n + k] = fb[k]
				}
				buf[n + f] = 0
				err := linux.execve(cstring(&buf[0]), argv, envp)
				if err == .EACCES {
					seen_eacces = true
				} else if err == .ENOENT || err == .ENOTDIR {
					// Try the next entry.
				} else if err == .ENOEXEC {
					return _exec_shell(cstring(&buf[0]), argv, envp)
				} else {
					set_errno(Errno(err))
					return -1
				}
			}
			if path[j] == 0 {
				break
			}
			i = j + 1
		}
		if seen_eacces {
			set_errno(.EACCES)
		} else {
			set_errno(.ENOENT)
		}
		return -1
	}
	err := linux.execve(file, argv, envp)
	if err == .ENOEXEC {
		return _exec_shell(file, argv, envp)
	}
	set_errno(Errno(err))
	return -1
}

// Reports whether the name contains a slash.
@(private="file")
_has_slash :: proc "contextless" (file: cstring) -> bool {
	fb := ([^]byte)(file)
	i := 0
	for fb[i] != 0 {
		if fb[i] == '/' {
			return true
		}
		i += 1
	}
	return false
}

// Count a copied list so collection needs neither heap allocation nor a
// fixed argument cap. Leave the caller's list at its first argument.
@(private="file")
_exec_arg_count :: proc "contextless" (args: ^c.va_list) -> (count: int, ok: bool) {
	list: c.va_list
	intrinsics.c_va_copy(&list, args)
	defer intrinsics.c_va_end(&list)
	count = 1
	for intrinsics.c_va_arg(&list, cstring) != nil {
		if count >= int(max(c.int)) - 1 || count >= max(int) / size_of(cstring) - 2 {
			set_errno(.E2BIG)
			return 0, false
		}
		count += 1
	}
	return count, true
}

@(private="file")
_exec_collect :: proc "contextless" (arg0: cstring, args: ^c.va_list, argv: [^]cstring, count: int) {
	argv[0] = arg0
	for i in 1..=count {
		argv[i] = intrinsics.c_va_arg(args, cstring)
	}
}

/*
The exec family of functions shall replace the current process image with a new process image.
The new image shall be constructed from a regular, executable file called the new process image file.
There shall be no return from a successful exec,
because the calling process image is overlaid by the new process image.

Takes arguments as varargs and the last of them must be nil.

Example:
	ret := posix.execl("/bin/ls", "ls", "-l", nil)
	fmt.panicf("could not execute: %v %v", ret, posix.strerror(posix.errno()))

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/execl.html ]]
*/
execl :: proc "c" (path: cstring, arg0: cstring, #c_vararg args: ..cstring) -> c.int {
	list: c.va_list
	intrinsics.c_va_start(&list, args)
	defer intrinsics.c_va_end(&list)
	count, ok := _exec_arg_count(&list)
	if !ok {
		return -1
	}
	argv := cast([^]cstring)intrinsics.alloca((count + 1) * size_of(cstring), align_of(cstring))
	_exec_collect(arg0, &list, argv, count)
	return execv(path, &argv[0])
}

/*
The exec family of functions shall replace the current process image with a new process image.
The new image shall be constructed from a regular, executable file called the new process image file.
There shall be no return from a successful exec,
because the calling process image is overlaid by the new process image.

Takes arguments as varargs and the last of them must be nil.
After the arguments an array of environment strings (also nil terminated) is expected.

Example:
	env := []cstring{
		"HOME=/usr/home",
		"LOGNAME=home",
		nil,
	}
	ret := posix.execle("/bin/ls", "ls", cstring("-l"), cstring(nil), raw_data(env))
	fmt.panicf("could not execute: %v", posix.strerror(posix.errno()))

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/execl.html ]]
*/
execle :: proc "c" (path: cstring, arg0: cstring, #c_vararg args: ..any) -> c.int {
	list: c.va_list
	intrinsics.c_va_start(&list, args)
	defer intrinsics.c_va_end(&list)
	count, ok := _exec_arg_count(&list)
	if !ok {
		return -1
	}
	argv := cast([^]cstring)intrinsics.alloca((count + 1) * size_of(cstring), align_of(cstring))
	_exec_collect(arg0, &list, argv, count)
	envp := intrinsics.c_va_arg(&list, [^]cstring)
	set_errno(Errno(linux.execve(path, &argv[0], envp)))
	return -1
}

/*
The exec family of functions shall replace the current process image with a new process image.
The new image shall be constructed from a regular, executable file called the new process image file.
There shall be no return from a successful exec,
because the calling process image is overlaid by the new process image.

If file does not contain a slash the PATH environment variable is searched for a matching file.
Takes arguments as varargs and the last of them must be nil.

Example:
	ret := posix.execlp("ls", "-l", cstring(nil))
	fmt.panicf("could not execute: %v, %v", ret, posix.strerror(posix.errno()))

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/execl.html ]]
*/
execlp :: proc "c" (file: cstring, arg0: cstring, #c_vararg args: ..cstring) -> c.int {
	list: c.va_list
	intrinsics.c_va_start(&list, args)
	defer intrinsics.c_va_end(&list)
	count, ok := _exec_arg_count(&list)
	if !ok {
		return -1
	}
	argv := cast([^]cstring)intrinsics.alloca((count + 1) * size_of(cstring), align_of(cstring))
	_exec_collect(arg0, &list, argv, count)
	return execvp(file, &argv[0])
}

/*
The exec family of functions shall replace the current process image with a new process image.
The new image shall be constructed from a regular, executable file called the new process image file.
There shall be no return from a successful exec,
because the calling process image is overlaid by the new process image.

If file does not contain a slash the PATH environment variable is searched for a matching file.
Takes arguments as an array which should be nil terminated.

Example:
	cmd := []cstring{ "ls", "-l", nil }
	ret := posix.execvp("ls", raw_data(cmd))
	fmt.panicf("could not execute: %v, %v", ret, posix.strerror(posix.errno()))

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/execl.html ]]
*/
execvp :: proc "c" (file: cstring, argv: [^]cstring) -> c.int {
	when ODIN_NO_CRT {
		context = runtime.default_context()
		snapshot, err := env.take_snapshot(runtime.heap_allocator())
		if err != nil {
			set_errno(.ENOMEM)
			return -1
		}
		defer env.release_snapshot(snapshot)
		return _execvpe(file, argv, raw_data(snapshot.values))
	} else {
		// Actual C callers share the C environment, but process replacement
		// still uses the owned syscall implementation.
		return _execvpe(file, argv, environ)
	}
}

/*
The exec family of functions shall replace the current process image with a new process image.
The new image shall be constructed from a regular, executable file called the new process image file.
There shall be no return from a successful exec,
because the calling process image is overlaid by the new process image.

Takes arguments as an array which should be nil terminated.
Takes environment variables as an array which should be nil terminated.

Example:
	cmd := []cstring{ "ls", "-l", nil }
	env := []cstring{ "HOME=/usr/home", "LOGNAME=home", nil }
	ret := posix.execve("/bin/ls", raw_data(cmd), raw_data(env))
	fmt.panicf("could not execute: %v, %v", ret, posix.strerror(posix.errno()))

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/execl.html ]]
*/
execve :: proc "c" (path: cstring, argv: [^]cstring, envp: [^]cstring) -> c.int {
	set_errno(Errno(linux.execve(path, argv, envp)))
	return -1
}

/*
The exec family of functions shall replace the current process image with a new process image.
The new image shall be constructed from a regular, executable file called the new process image file.
There shall be no return from a successful exec,
because the calling process image is overlaid by the new process image.

Equivalent to execve but takes a file descriptor instead of a path.

Example:
	ls := posix.open("/bin/ls", { .EXEC })
	cmd := []cstring{ "ls", "-l", nil }
	env := []cstring{ "HOME=/usr/home", "LOGNAME=home", nil }
	ret := posix.fexecve(ls, raw_data(cmd), raw_data(env))
	fmt.panicf("could not execute: %v, %v", ret, posix.strerror(posix.errno()))

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/execl.html ]]
*/
fexecve :: proc "c" (fd: FD, argv: [^]cstring, envp: [^]cstring) -> c.int {
	// fexecve is execveat with an empty path against the descriptor.
	set_errno(Errno(linux.execveat(linux.Fd(fd), "", argv, envp, { .AT_EMPTY_PATH })))
	return -1
}

/*
Fills the grouplist array with the current supplementary group IDs of the calling process.

Returns: -1 (setting errno) on failure, desired grouplist length if gidsetsize is 0, amount of IDs added otherwise

Example:
	length := posix.getgroups(0, nil)
	if length == -1 {
		fmt.panicf("getgroups failure: %v", posix.strerror(posix.errno()))
	}

	groups := make([]posix.gid_t, length) or_else panic("allocation failure")
	if posix.getgroups(length, raw_data(groups)) != length {
		fmt.panicf("getgroups failure: %v", posix.strerror(posix.errno()))
	}

	fmt.println(groups)

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/getgroups.html ]]
*/
getgroups :: proc "c" (gidsetsize: c.int, grouplist: [^]gid_t) -> c.int {
	if gidsetsize < 0 {
		set_errno(.EINVAL)
		return -1
	}
	// A zero size only asks for the count; the kernel reports it without writing.
	gids: []linux.Gid
	if gidsetsize > 0 {
		ptr := cast([^]linux.Gid)grouplist
		gids = ptr[:gidsetsize]
	}
	n, err := linux.getgroups(gids)
	return errno_int(n, err)
}

/*
Locks sections of a file with advisory-mode locks.

Example:
	fildes := posix.open("/home/cnd/mod1", { .RDWR })
	if posix.lockf(fildes, .TLOCK, 10000) != .OK {
		errno := posix.errno(); #partial switch errno {
		case .EACCES, .EAGAIN:
			// File is already locked.
		case:
			// Other error.
			fmt.panicf("lockf failure: %v", posix.strerror(errno))
		}
	}

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/lockf.html ]]
*/
lockf :: proc "c" (fildes: FD, function: Lock_Function, size: off_t) -> result {
	// lockf rides on POSIX locks with the section starting at the current
	// offset. A foreign lock under TEST reports EACCES; the manual allows
	// EACCES or EAGAIN here.
	lock := flock{ l_whence = c.short(Whence.CUR), l_len = size }
	switch function {
	case .TEST:
		lock.l_type = .WRLCK
		if err := linux.fcntl_getlk(linux.Fd(fildes), linux.F_GETLK, cast(^linux.FLock)&lock); err != .NONE {
			set_errno(Errno(err))
			return .FAIL
		}
		if lock.l_type != .UNLCK && lock.l_pid != getpid() {
			set_errno(.EACCES)
			return .FAIL
		}
		return .OK
	case .ULOCK:
		lock.l_type = .UNLCK
		return errno_result(linux.fcntl_setlk(linux.Fd(fildes), linux.F_SETLK, cast(^linux.FLock)&lock))
	case .TLOCK:
		lock.l_type = .WRLCK
		return errno_result(linux.fcntl_setlk(linux.Fd(fildes), linux.F_SETLK, cast(^linux.FLock)&lock))
	case .LOCK:
		lock.l_type = .WRLCK
		return errno_result(linux.fcntl_setlkw(linux.Fd(fildes), linux.F_SETLKW, cast(^linux.FLock)&lock))
	case:
		set_errno(.EINVAL)
		return .FAIL
	}
}

/*
Returns the process group ID of the calling process.

Returns: no failure

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/getpgrp.html ]]
*/
getpgrp :: proc "c" () -> pid_t {
	// The XSI form is getpgid of the calling process.
	return getpgid(0)
}

/*
Set the process group ID to that of the process.

Returns: the process group id, no failures are defined

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/setpgrp.html ]]
*/
setpgrp :: proc "c" () -> pid_t {
	// The XSI form is setpgid of the calling process to itself.
	if setpgid(0, 0) != .OK {
		return -1
	}
	return getpgrp()
}

// Static result for ttyname, which may be invalidated by later calls.
@(private="file")
_ttyname_buf: [4096]byte

// Writes a non-negative number in decimal, without terminator. Returns digits used.
@(private="file")
_itoa_dec :: proc "contextless" (v: int, buf: []byte) -> int {
	x := v
	div := 1
	for div <= x / 10 {
		div *= 10
	}
	n := 0
	for div > 0 {
		buf[n] = byte(x / div) + '0'
		n += 1
		x %= div
		div /= 10
	}
	return n
}

// Resolves the terminal path of fildes into name, like ttyname_r does.
// Returns the path length, or -1 with errno set.
@(private="file")
_ttyname_path :: proc "contextless" (fildes: FD, name: [^]byte, namesize: int) -> int {
	// The descriptor must be a terminal; this also rejects stale descriptors.
	termios: linux.Termios
	if _, err := linux.ioctl(linux.Fd(fildes), linux.TCGETS, uintptr(rawptr(&termios))); err != .NONE {
		set_errno(Errno(err))
		return -1
	}
	link: [32]byte
	n := copy(link[:], "/proc/self/fd/")
	n += _itoa_dec(int(fildes), link[n:])
	link[n] = 0

	// Read into a full-size buffer first: a short caller buffer must report
	// ERANGE rather than silently truncate.
	target: [4096]byte
	m := readlink(cstring(&link[0]), ([^]byte)(&target[0]), len(target) - 1)
	if m < 0 {
		return -1
	}
	mm := int(m)
	target[mm] = 0

	// The path must name the same device the descriptor refers to.
	fst, pst: stat_t
	if fstat(fildes, &fst) != .OK {
		return -1
	}
	if stat(cstring(&target[0]), &pst) != .OK {
		return -1
	}
	if fst.st_rdev != pst.st_rdev {
		set_errno(.ENOTTY)
		return -1
	}
	if mm + 1 > namesize {
		set_errno(.ERANGE)
		return -1
	}
	for i in 0..<mm {
		name[i] = target[i]
	}
	name[mm] = 0
	return mm
}

/*
Find the path name of a terminal.

Returns: nil (setting errno) on failure, the name, which may be invalidated by subsequent calls on success

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/ttyname.html ]]
*/
ttyname :: proc "c" (fildes: FD) -> cstring {
	if _ttyname_path(fildes, ([^]byte)(&_ttyname_buf[0]), len(_ttyname_buf)) < 0 {
		return nil
	}
	return cstring(&_ttyname_buf[0])
}

/*
Equivalent to ttyname but name is placed into the buf.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/ttyname.html ]]
*/
ttyname_r :: proc "c" (fildes: FD, name: [^]byte, namesize: c.size_t) -> Errno {
	if _ttyname_path(fildes, name, int(namesize)) < 0 {
		return errno()
	}
	return .NONE
}

// Answers pathconf names from a statfs name length. Returns -1, setting
// errno only for names libc does not implement on Linux.
@(private="file")
_pathconf_value :: proc "contextless" (name: PC, namelen: i64) -> c.long {
	// The shared enum cannot name _PC_SOCK_MAXBUF, which has no limit here.
	if int(name) == _PC_SOCK_MAXBUF {
		return -1
	}
	// LINK_MAX varies by filesystem in libc (127 on tmpfs); NAME_MAX comes
	// from the filesystem; the rest are Linux constants. SYMLINK_MAX and
	// the _ASYNC/_PRIO_IO options have no limit here. Transfer sizes use
	// the Linux constants in musl src/conf/fpathconf.c.
	switch name {
	case ._LINK_MAX:         return 127
	case ._MAX_CANON:        return 255
	case ._MAX_INPUT:        return 255
	case ._NAME_MAX:         return c.long(namelen)
	case ._PATH_MAX:         return 4096
	case ._PIPE_BUF:         return 4096
	case ._CHOWN_RESTRICTED: return 1
	case ._NO_TRUNC:         return 1
	case ._VDISABLE:         return 0
	case ._SYNC_IO: return 1
	case ._ASYNC_IO,
	     ._PRIO_IO,
	     ._SYMLINK_MAX:
		return -1
	case ._FILESIZEBITS:
		return 32
	case ._2_SYMLINKS: return 1
	case ._ALLOC_SIZE_MIN,
	     ._REC_INCR_XFER_SIZE,
	     ._REC_MAX_XFER_SIZE,
	     ._REC_MIN_XFER_SIZE,
	     ._REC_XFER_ALIGN:
		return 4096
	case:
		set_errno(.EINVAL)
		return -1
	}
}

/*
Determines the current value of a configurable limit or option that is associated with a file or directory.

Returns: value on success, -1 (setting errno) on failure, -1 (no errno) if the variable should be taken from limits

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/fpathconf.html ]]
*/
pathconf :: proc "c" (path: cstring, name: PC) -> c.long {
	kfs: linux.Stat_FS
	if err := linux.statfs(path, &kfs); err != .NONE {
		set_errno(Errno(err))
		return -1
	}
	return _pathconf_value(name, i64(kfs.namelen))
}

/*
Equivalent to pathconf but takes a file descriptor instead of a path.

Returns: value on success, -1 (setting errno) on failure, -1 (no errno) if the variable should be taken from limits

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/fpathconf.html ]]
*/
fpathconf :: proc "c" (fildes: FD, name: PC) -> c.long {
	kfs: linux.Stat_FS
	if err := linux.fstatfs(linux.Fd(fildes), &kfs); err != .NONE {
		set_errno(Errno(err))
		return -1
	}
	return _pathconf_value(name, i64(kfs.namelen))
}
