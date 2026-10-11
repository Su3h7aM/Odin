#+build linux
package posix

import "core:sys/linux"

// The Linux implementation of `sys/times.h` through system calls, without libc.

// `tms` matches the kernel's `Tms` field for field.
#assert(size_of(tms) == size_of(linux.Tms))
#assert(offset_of(tms, tms_utime)  == offset_of(linux.Tms, tms_utime))
#assert(offset_of(tms, tms_stime)  == offset_of(linux.Tms, tms_stime))
#assert(offset_of(tms, tms_cutime) == offset_of(linux.Tms, tms_cutime))
#assert(offset_of(tms, tms_cstime) == offset_of(linux.Tms, tms_cstime))

/*
Get time accounting information.

Returns: -1 (setting errno) on failure, the elapsed real time, since an arbitrary point in the past
*/
times :: proc "c" (buffer: ^tms) -> clock_t {
	ticks, err := linux.times(cast(^linux.Tms)buffer)
	if err != .NONE {
		set_errno(Errno(err))
		return -1
	}
	return clock_t(ticks)
}
