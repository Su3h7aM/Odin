#+build linux
package posix

import "core:sys/linux"

// The Linux implementation of `utime.h` through system calls, without libc.

/*
Set file access and modification times.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/utime.html ]]
*/
utime :: proc "c" (path: cstring, times: ^utimbuf) -> result {
	// A nil table sets both times to the present, like the call does.
	specs: [2]linux.Time_Spec
	spec_ptr: [^]linux.Time_Spec
	if times != nil {
		specs[0] = { uint(times.actime), 0 }
		specs[1] = { uint(times.modtime), 0 }
		spec_ptr = ([^]linux.Time_Spec)(&specs[0])
	}
	return errno_result(linux.utimensat(linux.AT_FDCWD, path, spec_ptr, {}))
}
