#+build linux amd64, linux arm64, linux riscv64
package posix

import "core:sys/linux"

// The Linux implementation of `sys/time.h` through system calls, without libc.

// `itimerval` matches the kernel's `ITimer_Val`, and `timeval` the kernel's
// `Time_Val`, so both convert by pointer.
#assert(int(ITimer.REAL)    == int(linux.ITimer_Which.REAL))
#assert(int(ITimer.VIRTUAL) == int(linux.ITimer_Which.VIRTUAL))
#assert(int(ITimer.PROF)    == int(linux.ITimer_Which.PROF))
#assert(size_of(timeval) == size_of(linux.Time_Val))
#assert(offset_of(timeval, tv_sec)  == offset_of(linux.Time_Val, seconds))
#assert(offset_of(timeval, tv_usec) == offset_of(linux.Time_Val, microseconds))
#assert(size_of(itimerval) == size_of(linux.ITimer_Val))
#assert(offset_of(itimerval, it_interval) == offset_of(linux.ITimer_Val, interval))
#assert(offset_of(itimerval, it_value)    == offset_of(linux.ITimer_Val, value))

/*
Store the current value of timer into value.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/getitimer.html ]]
*/
getitimer :: proc "c" (which: ITimer, value: ^itimerval) -> result {
	return errno_result(linux.getitimer(linux.ITimer_Which(int(which)), cast(^linux.ITimer_Val)value))
}

/*
Set the timer to the value given, and store the previous value in ovalue if it is not nil.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/getitimer.html ]]
*/
setitimer :: proc "c" (which: ITimer, value: ^itimerval, ovalue: ^itimerval) -> result {
	return errno_result(linux.setitimer(linux.ITimer_Which(int(which)), cast(^linux.ITimer_Val)value, cast(^linux.ITimer_Val)ovalue))
}

/*
Obtains the current time.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/gettimeofday.html ]]
*/
gettimeofday :: proc "c" (tp: ^timeval, tzp: rawptr = nil) -> result {
	// The zone argument is obsolete and ignored, like libc does.
	// Reads through the kernel vDSO on amd64, falling back to the raw
	// system call everywhere else. A nil tp is valid and succeeds without
	// storing, matching the system call.
	when ODIN_ARCH == .amd64 {
		return errno_result(linux.gettimeofday_fast(cast(^linux.Time_Val)tp))
	} else {
		return errno_result(linux.gettimeofday(cast(^linux.Time_Val)tp))
	}
}

/*
Sets the access and modification times of the file at the given path.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/utimes.html ]]
*/
utimes :: proc "c" (path: cstring, times: ^[2]timeval) -> result {
	// A nil table sets both times to the present, like the call does.
	specs: [2]linux.Time_Spec
	spec_ptr: [^]linux.Time_Spec
	if times != nil {
		for i in 0..<2 {
			specs[i] = { uint(times[i].tv_sec), uint(times[i].tv_usec) * 1_000 }
		}
		spec_ptr = ([^]linux.Time_Spec)(&specs[0])
	}
	return errno_result(linux.utimensat(linux.AT_FDCWD, path, spec_ptr, {}))
}
