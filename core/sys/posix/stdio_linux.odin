#+build linux
package posix

import "core:c"
import "core:sys/linux"

// The Linux implementation of the `stdio.h` file procedures that map to
// system calls, without libc.

/*
Renames a file or directory.

Returns: 0 on success, -1 (setting errno) on failure

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/rename.html ]]
*/
rename :: proc "c" (old, new: cstring) -> c.int {
	return c.int(errno_result(linux.renameat(linux.AT_FDCWD, old, linux.AT_FDCWD, new)))
}

/*
Equivalent to rename but relative directories are resolved from their respective fds.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/renameat.html ]]
*/
renameat :: proc "c" (oldfd: FD, old: cstring, newfd: FD, new: cstring) -> result {
	return errno_result(linux.renameat(linux.Fd(oldfd), old, linux.Fd(newfd), new))
}
/*
Deletes a name from the filesystem, like the C library `remove`: files,
symbolic links, sockets, FIFOs and devices with `unlink`, directories with
`rmdir`. `unlink` is tried first so a directory replacing a file between two
system calls cannot be silently unlinked, and a file replacing a directory
still fails with the directory error.

Returns: 0 on success, -1 (setting errno) on failure

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/remove.html ]]
*/
remove :: proc "c" (path: cstring) -> c.int {
	if path == nil {
		set_errno(.EINVAL)
		return -1
	}
	// A directory fails `unlink` with EISDIR on Linux; anything else, such as
	// EPERM on an immutable regular file, keeps the `unlink` error instead of
	// turning into the `rmdir` error.
	if err := linux.unlink(path); err == .NONE {
		return 0
	} else if err == .EISDIR {
		if rerr := linux.rmdir(path); rerr == .NONE {
			return 0
		} else {
			set_errno(Errno(rerr))
			return -1
		}
	} else {
		set_errno(Errno(err))
		return -1
	}
}
