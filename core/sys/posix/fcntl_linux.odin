#+build linux
package posix

import "base:intrinsics"
import "core:c"
import "core:sys/linux"

// The Linux implementation of the `fcntl.h` advisory-information procedures
// through system calls, without libc.
//
// A filesystem without fallocate support reports EOPNOTSUPP; nothing here
// emulates the allocation by writing zeros.
//
// Both procedures return the error number and never set `errno`.

// `FAdvice` is cast to the kernel's `FAdvice`, which needs them to agree.
#assert(int(FAdvice.DONTNEED)   == int(linux.FAdvice.DONTNEED))
#assert(int(FAdvice.NOREUSE)    == int(linux.FAdvice.NOREUSE))
#assert(int(FAdvice.NORMAL)     == int(linux.FAdvice.NORMAL))
#assert(int(FAdvice.RANDOM)     == int(linux.FAdvice.RANDOM))
#assert(int(FAdvice.SEQUENTIAL) == int(linux.FAdvice.SEQUENTIAL))
#assert(int(FAdvice.WILLNEED)   == int(linux.FAdvice.WILLNEED))

/*
Ensure that disk space is allocated for the bytes in the range starting at
offset and continuing for len bytes. If the file is smaller than offset+len,
it is extended.

Returns: the error number, without setting errno.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/posix_fallocate.html ]]
*/
posix_fallocate :: proc "c" (fd: FD, offset: off_t, len: off_t) -> Errno {
	return Errno(linux.fallocate(linux.Fd(fd), {}, i64(offset), i64(len)))
}

/*
Announce an intention to access the file data in a specific pattern, allowing
the kernel to perform appropriate optimizations. The advice is not binding.

Returns: the error number, without setting errno.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/posix_fadvise.html ]]
*/
posix_fadvise :: proc "c" (fd: FD, offset: off_t, len: off_t, advice: FAdvice) -> Errno {
	return Errno(linux.fadvise64(linux.Fd(fd), i64(offset), i64(len), linux.FAdvice(advice)))
}

// The Linux implementation of `open`, `openat`, `creat`, and `fcntl`
// through system calls, without libc.
//
// Unlike the advisory-information procedures above, these report failures
// with -1 and set `errno` like libc does.
//
// `O_Flags` transmutes to the kernel's `Open_Flags`, which needs each named
// member to sit on the same bit. `SYNC` has no kernel counterpart: the
// `O_SYNC` value carries two bits and the member holds the upper one, while
// `EXEC` rides alone on its own bit. The transmute still passes the exact
// bits the libc call would pass, so the kernel sees identical flags.
#assert(int(O_Flag_Bits.WRONLY)   == int(linux.Open_Flags_Bits.WRONLY))
#assert(int(O_Flag_Bits.RDWR)     == int(linux.Open_Flags_Bits.RDWR))
#assert(int(O_Flag_Bits.CREAT)    == int(linux.Open_Flags_Bits.CREAT))
#assert(int(O_Flag_Bits.EXCL)     == int(linux.Open_Flags_Bits.EXCL))
#assert(int(O_Flag_Bits.NOCTTY)   == int(linux.Open_Flags_Bits.NOCTTY))
#assert(int(O_Flag_Bits.TRUNC)    == int(linux.Open_Flags_Bits.TRUNC))
#assert(int(O_Flag_Bits.APPEND)   == int(linux.Open_Flags_Bits.APPEND))
#assert(int(O_Flag_Bits.NONBLOCK) == int(linux.Open_Flags_Bits.NONBLOCK))
#assert(int(O_Flag_Bits.DSYNC)    == int(linux.Open_Flags_Bits.DSYNC))
#assert(int(O_Flag_Bits.DIRECTORY) == int(linux.Open_Flags_Bits.DIRECTORY))
#assert(int(O_Flag_Bits.NOFOLLOW)  == int(linux.Open_Flags_Bits.NOFOLLOW))
#assert(int(O_Flag_Bits.CLOEXEC)   == int(linux.Open_Flags_Bits.CLOEXEC))

// Each `fcntl` command below is issued through its own typed wrapper, which
// needs the posix command number to equal the kernel one.
#assert(int(FCNTL_Cmd.DUPFD)         == int(linux.FCntl_Command.DUPFD))
#assert(int(FCNTL_Cmd.DUPFD_CLOEXEC) == int(linux.FCntl_Command.DUPFD_CLOEXEC))
#assert(int(FCNTL_Cmd.GETFD)         == int(linux.FCntl_Command.GETFD))
#assert(int(FCNTL_Cmd.SETFD)         == int(linux.FCntl_Command.SETFD))
#assert(int(FCNTL_Cmd.GETFL)         == int(linux.FCntl_Command.GETFL))
#assert(int(FCNTL_Cmd.SETFL)         == int(linux.FCntl_Command.SETFL))
#assert(int(FCNTL_Cmd.GETLK)         == int(linux.FCntl_Command.GETLK))
#assert(int(FCNTL_Cmd.SETLK)         == int(linux.FCntl_Command.SETLK))
#assert(int(FCNTL_Cmd.SETLKW)        == int(linux.FCntl_Command.SETLKW))
#assert(int(FCNTL_Cmd.SETOWN)        == int(linux.FCntl_Command.SETOWN))

// The locking commands hand the caller's `flock` to the kernel by pointer,
// which needs it to match the kernel's `FLock` field for field so the
// `F_GETLK` write-back lands in the right places.
#assert(size_of(flock) == size_of(linux.FLock))
#assert(offset_of(flock, l_type)   == offset_of(linux.FLock, type))
#assert(offset_of(flock, l_whence) == offset_of(linux.FLock, whence))
#assert(offset_of(flock, l_start)  == offset_of(linux.FLock, start))
#assert(offset_of(flock, l_len)    == offset_of(linux.FLock, len))
#assert(offset_of(flock, l_pid)    == offset_of(linux.FLock, pid))
#assert(int(Lock_Type.RDLCK) == int(linux.FLock_Type.RDLCK))
#assert(int(Lock_Type.WRLCK) == int(linux.FLock_Type.WRLCK))
#assert(int(Lock_Type.UNLCK) == int(linux.FLock_Type.UNLCK))

/*
Implemented as `return open(path, O_WRONLY|O_CREAT|O_TRUNC, mode);`

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/creat.html ]]
*/
creat :: proc "c" (path: cstring, mode: mode_t) -> FD {
	return open(path, { .WRONLY, .CREAT, .TRUNC }, mode)
}

/*
Establish the connection between a file and a file descriptor.
It shall create an open file description that refers to a file and a file descriptor that
refers to that open file description. The file descriptor is used by other I/O functions to
refer to that file.
The path argument points to a pathname naming the file

Returns: -1 on failure (setting errno), a file descriptor on success.

Example:
	// The following example opens the file /tmp/file, either by creating it (if it does not already exist),
	// or by truncating its length to 0 (if it does exist). In the former case, if the call creates a new file,
	// the access permission bits in the file mode of the file are set to permit reading and writing by the owner,
	// and to permit reading only by group members and others.
	fd := posix.open("/tmp/file", { .WRONLY, .CREAT, .TRUNC }, { .IRUSR, .IWUSR, .IRGRP, .IROTH })

	// The following example uses the open() function to try to create the LOCKFILE file and open it for writing.
	// Since the open() function specifies the O_EXCL flag, the call fails if the file already exists.
	// In that case, the program assumes that someone else is updating the password file and exits.
	fd := posix.open("/etc/ptmp", { .WRONLY, .CREAT, .EXCL }, { .IRUSR, .IWUSR, .IRGRP, .IROTH })
	if fd == -1 {
		fmt.println("cannot open /etc/ptmp")
	}

	// The following example opens a file for writing, creating the file if it does not already exist.
	// If the file does exist, the system truncates the file to zero bytes.
	fd := posix.open("/etc/ptmp", { .WRONLY, .CREAT, .TRUNC }, { .IRUSR, .IWUSR, .IRGRP, .IROTH })
	if fd == -1 {
		fmt.println("cannot open output file")
	}

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/open.html ]]
*/
open :: proc "c" (path: cstring, flags: O_Flags, #c_vararg mode: ..mode_t) -> FD {
	// The kernel ignores the mode without O_CREAT, and the argument is only present then.
	m := mode_t{}
	if .CREAT in flags {
		list: c.va_list
		intrinsics.c_va_start(&list, mode)
		defer intrinsics.c_va_end(&list)
		m = intrinsics.c_va_arg(&list, mode_t)
	}
	fd, err := linux.open(path, transmute(linux.Open_Flags)flags, transmute(linux.Mode)m)
	return errno_fd(fd, err)
}

/*
Equivalent to the open() function except in the case where path specifies a relative path.
In this case the file to be opened is determined relative to the directory associated with the
file descriptor fd instead of the current working directory.

Returns: -1 on failure (setting errno), a file descriptor on success.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/open.html ]]
*/
openat :: proc "c" (fd: FD, path: cstring, flags: O_Flags, #c_vararg mode: ..mode_t) -> FD {
	// The kernel ignores the mode without O_CREAT, and the argument is only present then.
	m := mode_t{}
	if .CREAT in flags {
		list: c.va_list
		intrinsics.c_va_start(&list, mode)
		defer intrinsics.c_va_end(&list)
		m = intrinsics.c_va_arg(&list, mode_t)
	}
	kfd, err := linux.openat(linux.Fd(fd), path, transmute(linux.Open_Flags)flags, transmute(linux.Mode)m)
	return errno_fd(kfd, err)
}

/*
Perform the operations on open files.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/fcntl.html ]]
*/
fcntl :: proc "c" (fd: FD, cmd: FCNTL_Cmd, #c_vararg args: ..any) -> c.int {
	// Each command takes one argument of a fixed type; a command name the
	// kernel does not know reports EINVAL like libc does.
	list: c.va_list
	intrinsics.c_va_start(&list, args)
	defer intrinsics.c_va_end(&list)
	switch cmd {
	case .DUPFD:
		arg := intrinsics.c_va_arg(&list, c.int)
		newfd, err := linux.fcntl_dupfd(linux.Fd(fd), linux.F_DUPFD, linux.Fd(arg))
		return errno_int(int(newfd), err)
	case .DUPFD_CLOEXEC:
		arg := intrinsics.c_va_arg(&list, c.int)
		newfd, err := linux.fcntl_dupfd_cloexec(linux.Fd(fd), linux.F_DUPFD_CLOEXEC, linux.Fd(arg))
		return errno_int(int(newfd), err)
	case .GETFD:
		flag, err := linux.fcntl_getfd(linux.Fd(fd), linux.F_GETFD)
		return errno_int(int(flag), err)
	case .SETFD:
		arg := intrinsics.c_va_arg(&list, c.int)
		return errno_int(0, linux.fcntl_setfd(linux.Fd(fd), linux.F_SETFD, linux.Fd(arg)))
	case .GETFL:
		flags, err := linux.fcntl_getfl(linux.Fd(fd), linux.F_GETFL)
		return errno_int(int(transmute(u32)flags), err)
	case .SETFL:
		arg := intrinsics.c_va_arg(&list, c.int)
		return errno_int(0, linux.fcntl_setfl(linux.Fd(fd), linux.F_SETFL, transmute(linux.Open_Flags)arg))
	case .GETLK:
		lock := intrinsics.c_va_arg(&list, ^flock)
		return errno_int(0, linux.fcntl_getlk(linux.Fd(fd), linux.F_GETLK, cast(^linux.FLock)lock))
	case .SETLK:
		lock := intrinsics.c_va_arg(&list, ^flock)
		return errno_int(0, linux.fcntl_setlk(linux.Fd(fd), linux.F_SETLK, cast(^linux.FLock)lock))
	case .SETLKW:
		lock := intrinsics.c_va_arg(&list, ^flock)
		return errno_int(0, linux.fcntl_setlkw(linux.Fd(fd), linux.F_SETLKW, cast(^linux.FLock)lock))
	case .GETOWN:
		// F_GETOWN cannot tell a process group ID from -1 to -4095 apart
		// from an error return, so read the owner with F_GETOWN_EX and
		// render it in F_GETOWN's sign convention instead: a process or
		// thread owner comes back positive, a process group owner negated,
		// and no owner reads back as zero.
		owner := linux.F_Owner{}
		if kerr := linux.fcntl_getown_ex(linux.Fd(fd), linux.F_GETOWN_EX, &owner); kerr != .NONE {
			set_errno(Errno(kerr))
			return -1
		}
		if owner.type == .OWNER_PGRP {
			return errno_int(-int(owner.pid), .NONE)
		}
		return errno_int(int(owner.pid), .NONE)
	case .SETOWN:
		arg := intrinsics.c_va_arg(&list, c.int)
		return errno_int(0, linux.fcntl_setown(linux.Fd(fd), linux.F_SETOWN, int(arg)))
	case:
		set_errno(.EINVAL)
		return -1
	}
}
