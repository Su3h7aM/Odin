#+build linux
package posix

import "base:intrinsics"
import "core:c"
import "core:sys/linux"

// The Linux implementation of `ulimit.h` through system calls, without libc.

/*
Control process limits.

Note that -1 is a valid return value, applications should clear errno, do this call and then
check both -1 and the errno to determine status.

Returns: -1 (setting errno) on failure.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/ulimit.html ]]
*/
ulimit :: proc "c" (i: c.int, #c_vararg arg: ..c.long) -> c.long {
	// Only the file size commands exist; anything else fails like libc fails it.
	switch i {
	case UL_GETFSIZE:
		old: linux.RLimit
		if err := linux.prlimit64(0, .FSIZE, nil, &old); err != .NONE {
			set_errno(Errno(err))
			return -1
		}
		// The result is in 512-byte blocks, including an unlimited byte limit.
		blocks := old.cur / 512
		if blocks > uint(max(c.long)) {
			set_errno(.EOVERFLOW)
			return -1
		}
		return c.long(blocks)
	case UL_SETFSIZE:
		list: c.va_list
		intrinsics.c_va_start(&list, arg)
		defer intrinsics.c_va_end(&list)
		blocks := intrinsics.c_va_arg(&list, c.long)
		// Read first so the untouched maximum survives the write.
		old: linux.RLimit
		if err := linux.prlimit64(0, .FSIZE, nil, &old); err != .NONE {
			set_errno(Errno(err))
			return -1
		}
		new := linux.RLimit{ cur = uint(blocks * 512), max = old.max }
		if err := linux.prlimit64(0, .FSIZE, &new, nil); err != .NONE {
			set_errno(Errno(err))
			return -1
		}
		return blocks
	case:
		set_errno(.EINVAL)
		return -1
	}
}
