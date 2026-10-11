#+build linux
package posix

import "core:c"
import "core:sys/linux"

// The Linux implementation of the `sys/mman.h` procedures through system
// calls, without libc.
//
// A failure is reported the same way as for the libc procedures, with
// `errno`, except for `posix_madvise`, which returns the error number.

// The protection, mapping and invalidation bits match the kernel's.
#assert(int(Prot_Flag_Bits.READ) == int(linux.Mem_Protection_Bits.READ))
#assert(int(Prot_Flag_Bits.WRITE) == int(linux.Mem_Protection_Bits.WRITE))
#assert(int(Prot_Flag_Bits.EXEC) == int(linux.Mem_Protection_Bits.EXEC))
#assert(int(Map_Flag_Bits.SHARED) == int(linux.Map_Flags_Bits.SHARED))
#assert(int(Map_Flag_Bits.PRIVATE) == int(linux.Map_Flags_Bits.PRIVATE))
#assert(int(Map_Flag_Bits.FIXED) == int(linux.Map_Flags_Bits.FIXED))
#assert(int(Map_Flag_Bits.ANONYMOUS) == int(linux.Map_Flags_Bits.ANONYMOUS))
#assert(int(Sync_Flags_Bits.ASYNC) == int(linux.MSync_Flags_Bits.ASYNC))
#assert(int(Sync_Flags_Bits.INVALIDATE) == int(linux.MSync_Flags_Bits.INVALIDATE))
// MS_SYNC has no enum member (it is 0 on some platforms); pin its Linux bit
// against the kernel's instead.
#assert(_MS_SYNC == 0x0004)
#assert(int(linux.MSync_Flags_Bits.SYNC) == log2(_MS_SYNC))

// mlockall passes its bits to the kernel untouched: MCL_CURRENT is 0x1 and
// MCL_FUTURE is 0x2 there too.
#assert(MCL_CURRENT == 0x0001)
#assert(MCL_FUTURE == 0x0002)
#assert(int(Lock_Flag_Bits.CURRENT) == 0)
#assert(int(Lock_Flag_Bits.FUTURE) == 1)

// The advice values match the kernel's MADV_ values one for one.
#assert(int(MAdvice.NORMAL) == int(linux.MAdvice.NORMAL))
#assert(int(MAdvice.RANDOM) == int(linux.MAdvice.RANDOM))
#assert(int(MAdvice.SEQUENTIAL) == int(linux.MAdvice.SEQUENTIAL))
#assert(int(MAdvice.WILLNEED) == int(linux.MAdvice.WILLNEED))
#assert(int(MAdvice.DONTNEED) == int(linux.MAdvice.DONTNEED))

/*
Establish a mapping between an address space of a process and a memory object.

Returns: MAP_FAILED (setting errno) on failure, the address in memory otherwise

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/mmap.html ]]
*/
mmap :: proc "c" (
	addr:  rawptr,
	len:   c.size_t,
	prot:  Prot_Flags,
	flags: Map_Flags,
	fd:    FD    = -1,
	off:   off_t = 0,
) -> rawptr {
	// The raw call reports errors with a nil address, which is a valid
	// mapping result; convert exactly to MAP_FAILED instead.
	m, err := linux.mmap(
		uintptr(addr),
		uint(len),
		transmute(linux.Mem_Protection)prot,
		transmute(linux.Map_Flags)flags,
		linux.Fd(fd),
		i64(off),
	)
	if err != .NONE {
		set_errno(Errno(err))
		return MAP_FAILED
	}
	return m
}

/*
Unmaps pages of memory.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/munmap.html ]]
*/
munmap :: proc "c" (addr: rawptr, len: c.size_t) -> result {
	return errno_result(linux.munmap(addr, uint(len)))
}

/*
Locks a range of the process address space.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/mlock.html ]]
*/
mlock :: proc "c" (addr: rawptr, len: c.size_t) -> result {
	return errno_result(linux.mlock(addr, uint(len)))
}

/*
Unlocks a range of the process address space.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/mlock.html ]]
*/
munlock :: proc "c" (addr: rawptr, len: c.size_t) -> result {
	return errno_result(linux.munlock(addr, uint(len)))
}

/*
Locks all pages of the process address space.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/mlockall.html ]]
*/
mlockall :: proc "c" (flags: Lock_Flags) -> result {
	return errno_result(linux.mlockall(transmute(linux.MLock_Flags)flags))
}

/*
Unlocks all pages of the process address space.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/mlockall.html ]]
*/
munlockall :: proc "c" () -> result {
	return errno_result(linux.munlockall())
}

/*
Set protection of a memory mapping.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/mprotect.html ]]
*/
mprotect :: proc "c" (addr: rawptr, len: c.size_t, prot: Prot_Flags) -> result {
	return errno_result(linux.mprotect(addr, uint(len), transmute(linux.Mem_Protection)prot))
}

/*
Write all modified data to permanent storage locations.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/msync.html ]]
*/
msync :: proc "c" (addr: rawptr, len: c.size_t, flags: Sync_Flags) -> result {
	return errno_result(linux.msync(addr, uint(len), transmute(linux.MSync_Flags)flags))
}

/*
Advise the implementation of expected behavior of the application.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/posix_madvise.html ]]
*/
posix_madvise :: proc "c" (addr: rawptr, len: c.size_t, advice: MAdvice) -> Errno {
	// POSIX requires advice to leave the mapping semantics unchanged, but the
	// kernel's MADV_DONTNEED discards private anonymous pages (2-madvise.md),
	// so DONTNEED performs no call and reports success.
	if advice == .DONTNEED {
		return .NONE
	}
	return Errno(linux.madvise(addr, uint(len), linux.MAdvice(int(advice))))
}

// POSIX shared memory objects are files in the tmpfs that is mounted on
// `/dev/shm`. Like glibc and musl, a name is accepted with or without its
// leading slash, and with more than one, but it may name nothing below the
// directory.
@(private="file")
SHM_DIR :: "/dev/shm/"

@(private="file")
SHM_NAME_MAX :: _XOPEN_NAME_MAX

@(private="file")
Shm_Path :: [len(SHM_DIR) + SHM_NAME_MAX + 1]byte

// Writes the file name of the shared memory object `name` into `buf`.
// Returns EINVAL for a name that is empty, has a slash after the leading ones,
// or is "." or "..", and ENAMETOOLONG for one over `NAME_MAX` characters.
@(private="file")
shm_path :: proc "contextless" (name: cstring, buf: ^Shm_Path) -> (path: cstring, err: linux.Errno) {
	if name == nil {
		return nil, .EFAULT
	}
	base := string(name)
	for len(base) > 0 && base[0] == '/' {
		base = base[1:]
	}
	if len(base) == 0 || base == "." || base == ".." {
		return nil, .EINVAL
	}
	for i in 0..<len(base) {
		if base[i] == '/' {
			return nil, .EINVAL
		}
	}
	if len(base) > SHM_NAME_MAX {
		return nil, .ENAMETOOLONG
	}
	length := copy(buf[:], SHM_DIR)
	length += copy(buf[length:], base)
	buf[length] = 0
	return cstring(&buf[0]), .NONE
}

/*
Open a shared memory object.

The descriptor is close-on-exec, and a symbolic link in place of the object is not followed.

Returns: -1 (setting errno) on failure, an open file descriptor otherwise

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/shm_open.html ]]
*/
shm_open :: proc "c" (name: cstring, oflag: O_Flags, mode: mode_t) -> FD {
	buf: Shm_Path
	path, perr := shm_path(name, &buf)
	if perr != .NONE {
		set_errno(Errno(perr))
		return -1
	}
	flags := transmute(linux.Open_Flags)oflag + {.NOFOLLOW, .CLOEXEC}
	fd, err := linux.open(path, flags, transmute(linux.Mode)mode)
	return errno_fd(fd, err)
}

/*
Removes a shared memory object.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/shm_unlink.html ]]
*/
shm_unlink :: proc "c" (name: cstring) -> result {
	buf: Shm_Path
	path, perr := shm_path(name, &buf)
	if perr != .NONE {
		set_errno(Errno(perr))
		return .FAIL
	}
	return errno_result(linux.unlink(path))
}
