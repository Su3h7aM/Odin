#+build linux amd64, linux arm64, linux riscv64
package posix

import "core:sys/linux"

// The Linux implementation of the `sys/stat.h` procedures through system
// calls, without libc.
//
// A failure is reported the same way as for the libc procedures, with `errno`.
//
// The caller's `stat_t` is handed to the kernel directly: on all three
// 64-bit architectures `stat_t` and `linux.Stat` have identical sizes and
// per-field offsets, pinned by the asserts below. Only the signedness of
// some fields differs, which a pointer cast preserves bit for bit.

// `stat_t` is the kernel stat layout on every 64-bit architecture.
#assert(size_of(stat_t) == size_of(linux.Stat))
#assert(offset_of(stat_t, st_dev)     == offset_of(linux.Stat, dev))
#assert(offset_of(stat_t, st_ino)     == offset_of(linux.Stat, ino))
#assert(offset_of(stat_t, st_nlink)   == offset_of(linux.Stat, nlink))
#assert(offset_of(stat_t, st_mode)    == offset_of(linux.Stat, mode))
#assert(offset_of(stat_t, st_uid)     == offset_of(linux.Stat, uid))
#assert(offset_of(stat_t, st_gid)     == offset_of(linux.Stat, gid))
#assert(offset_of(stat_t, st_rdev)    == offset_of(linux.Stat, rdev))
#assert(offset_of(stat_t, st_size)    == offset_of(linux.Stat, size))
#assert(offset_of(stat_t, st_blksize) == offset_of(linux.Stat, blksize))
#assert(offset_of(stat_t, st_blocks)  == offset_of(linux.Stat, blocks))
#assert(offset_of(stat_t, st_atim)    == offset_of(linux.Stat, atime))
#assert(offset_of(stat_t, st_mtim)    == offset_of(linux.Stat, mtime))
#assert(offset_of(stat_t, st_ctim)    == offset_of(linux.Stat, ctime))

// `timespec` and `linux.Time_Spec` differ only in signedness.
#assert(size_of(timespec) == size_of(linux.Time_Spec))
#assert(offset_of(timespec, tv_sec)  == offset_of(linux.Time_Spec, time_sec))
#assert(offset_of(timespec, tv_nsec) == offset_of(linux.Time_Spec, time_nsec))

// The mode bit positions match the kernel's.
#assert(int(Mode_Bits.IXOTH) == int(linux.Mode_Bits.IXOTH))
#assert(int(Mode_Bits.IWOTH) == int(linux.Mode_Bits.IWOTH))
#assert(int(Mode_Bits.IROTH) == int(linux.Mode_Bits.IROTH))
#assert(int(Mode_Bits.IXGRP) == int(linux.Mode_Bits.IXGRP))
#assert(int(Mode_Bits.IWGRP) == int(linux.Mode_Bits.IWGRP))
#assert(int(Mode_Bits.IRGRP) == int(linux.Mode_Bits.IRGRP))
#assert(int(Mode_Bits.IXUSR) == int(linux.Mode_Bits.IXUSR))
#assert(int(Mode_Bits.IWUSR) == int(linux.Mode_Bits.IWUSR))
#assert(int(Mode_Bits.IRUSR) == int(linux.Mode_Bits.IRUSR))
#assert(int(Mode_Bits.ISVXT) == int(linux.Mode_Bits.ISVTX))
#assert(int(Mode_Bits.ISGID) == int(linux.Mode_Bits.ISGID))
#assert(int(Mode_Bits.ISUID) == int(linux.Mode_Bits.ISUID))
#assert(int(Mode_Bits.IFIFO) == int(linux.Mode_Bits.IFIFO))
#assert(int(Mode_Bits.IFCHR) == int(linux.Mode_Bits.IFCHR))
#assert(int(Mode_Bits.IFDIR) == int(linux.Mode_Bits.IFDIR))
#assert(int(Mode_Bits.IFREG) == int(linux.Mode_Bits.IFREG))

// The shared `*at` flag positions and values match the kernel's.
#assert(int(AT_Flag_Bits.SYMLINK_NOFOLLOW) == int(linux.FD_Flags_Bits.SYMLINK_NOFOLLOW))
#assert(int(AT_Flag_Bits.SYMLINK_FOLLOW)   == int(linux.FD_Flags_Bits.SYMLINK_FOLLOW))
#assert(int(AT_Flag_Bits.REMOVEDIR)        == int(linux.FD_Flags_Bits.REMOVEDIR))
#assert(int(AT_Flag_Bits.EACCESS)          == int(linux.FD_Flags_Bits.EACCESS))
#assert(int(AT_FDCWD) == int(linux.AT_FDCWD))
#assert(AT_SYMLINK_NOFOLLOW == 0x100)
#assert(AT_SYMLINK_FOLLOW   == 0x400)
#assert(AT_REMOVEDIR        == 0x200)
#assert(AT_EACCESS          == 0x200)

// The timestamp constants match the kernel's.
#assert(UTIME_NOW  == linux.UTIME_NOW)
#assert(UTIME_OMIT == linux.UTIME_OMIT)

#assert(size_of(off_t) == 8)
#assert(size_of(dev_t) == size_of(linux.Dev))
#assert(size_of(ino_t) == size_of(linux.Inode))

/*
Equivalent to either stat or lstat (based on the SYMLINK_NOFOLLOW bit in flags)
but resolves relative paths based on the given fd.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/fstatat.html ]]
*/
fstatat :: proc "c" (fd: FD, path: cstring, buf: ^stat_t, flag: AT_Flags) -> result {
	return errno_result(linux.fstatat(linux.Fd(fd), path, cast(^linux.Stat)buf, transmute(linux.FD_Flags)flag))
}

/*
Obtain information about a "file" at the given path.

Follows symbolic links.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/fstatat.html ]]
*/
stat :: proc "c" (path: cstring, buf: ^stat_t) -> result {
	return errno_result(linux.stat(path, cast(^linux.Stat)buf))
}

/*
Obtain information about an open file.

Follows symbol links.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/fstat.html ]]
*/
fstat :: proc "c" (fildes: FD, buf: ^stat_t) -> result {
	// The kernel reports EBADF for a descriptor that is not open, negative
	// and AT_FDCWD included.
	return errno_result(linux.fstat(linux.Fd(fildes), cast(^linux.Stat)buf))
}

/*
Obtain information about a "file" at the given path.

Does not follow symlinks (will stat the symlink itself).

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/fstatat.html ]]
*/
lstat :: proc "c" (path: cstring, buf: ^stat_t) -> result {
	return errno_result(linux.lstat(path, cast(^linux.Stat)buf))
}

/*
Change the mode of a file.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/chmod.html ]]
*/
chmod :: proc "c" (path: cstring, mode: mode_t) -> result {
	return errno_result(linux.chmod(path, transmute(linux.Mode)mode))
}

/*
Equivalent to chmod but takes an open file descriptor.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/fchmod.html ]]
*/
fchmod :: proc "c" (fd: FD, mode: mode_t) -> result {
	// The kernel reports EBADF for a descriptor that cannot change modes,
	// O_PATH descriptors included.
	return errno_result(linux.fchmod(linux.Fd(fd), transmute(linux.Mode)mode))
}

/*
Equivalent to chmod but follows (or doesn't) symlinks based on the flag and resolves
relative paths from the given fd.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/chmod.html ]]
*/
fchmodat :: proc "c" (fd: FD, path: cstring, mode: mode_t, flag: AT_Flags) -> result {
	m := transmute(linux.Mode)mode
	if flag == {} {
		return errno_result(linux.fchmodat(linux.Fd(fd), path, m, {}))
	}
	// Flags go through fchmodat2 (Linux 6.6), whose result, ENOSYS
	// included, is returned.
	return errno_result(linux.fchmodat2(linux.Fd(fd), path, m, transmute(linux.FD_Flags)flag))
}

/*
Make a directory.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/mkdir.html ]]
*/
mkdir :: proc "c" (path: cstring, mode: mode_t) -> result {
	return errno_result(linux.mkdir(path, transmute(linux.Mode)mode))
}

/*
Equivalent to mkdir but relative paths are relative to fd.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/mkdir.html ]]
*/
mkdirat :: proc "c" (fd: FD, path: cstring, mode: mode_t) -> result {
	return errno_result(linux.mkdirat(linux.Fd(fd), path, transmute(linux.Mode)mode))
}

/*
Make a FIFO special file.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/mkfifo.html ]]
*/
mkfifo :: proc "c" (path: cstring, mode: mode_t) -> result {
	// A FIFO is a fifo-typed mknod with no device.
	return mknod(path, mode | S_IFIFO, dev_t(0))
}

/*
Equivalent to mkfifo but relative paths are relative to fd.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/mkfifo.html ]]
*/
mkfifoat :: proc "c" (fd: FD, path: cstring, mode: mode_t) -> result {
	// A FIFO is a fifo-typed mknodat with no device.
	return mknodat(fd, path, mode | S_IFIFO, dev_t(0))
}

/*
Make directory, special file, or regular file.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/mknodat.html ]]
*/
mknod :: proc "c" (path: cstring, mode: mode_t, dev: dev_t) -> result {
	return errno_result(linux.mknod(path, transmute(linux.Mode)mode, linux.Dev(dev)))
}

/*
Equivalent to mknod but relative paths are relative to fd.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/mknodat.html ]]
*/
mknodat :: proc "c" (fd: FD, path: cstring, mode: mode_t, dev: dev_t) -> result {
	return errno_result(linux.mknodat(linux.Fd(fd), path, transmute(linux.Mode)mode, linux.Dev(dev)))
}

/*
Sets the file access and modification time of the given file descriptor.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/futimens.html ]]
*/
futimens :: proc "c" (fd: FD, times: ^[2]timespec) -> result {
	// This is utimensat with a null path. A null times pointer passes
	// through and means both stamps are set to the current time.
	return errno_result(linux.utimensat(linux.Fd(fd), nil, cast([^]linux.Time_Spec)times, {}))
}

/*
Equivalent to futimens.
Relative directories are based on fd.
Symlinks may or may not be followed based on the flags.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/futimens.html ]]
*/
utimensat :: proc "c" (fd: FD, path: cstring, times: ^[2]timespec, flag: AT_Flags) -> result {
	// The kernel accepts the stamps as given: explicit times, UTIME_NOW,
	// UTIME_OMIT, and a null pointer for both stamps at the current time.
	return errno_result(
		linux.utimensat(linux.Fd(fd), path, cast([^]linux.Time_Spec)times, transmute(linux.FD_Flags)flag),
	)
}

/*
Set and get the file mode creation flags.

Makes the file mode permissions bits in cmask the new default for the process.

Returns: the previous value

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/umask.html ]]
*/
umask :: proc "c" (cmask: mode_t) -> mode_t {
	// umask cannot fail, so errno is left alone.
	return transmute(mode_t)linux.umask(transmute(linux.Mode)cmask)
}
