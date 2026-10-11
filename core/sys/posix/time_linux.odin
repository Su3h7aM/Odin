#+build linux
package posix

import "core:c"
import "core:sys/linux"

import dt "core:time/datetime"

// The Linux implementation of the clock and sleep procedures of `time.h`
// through system calls, without libc.
//
// A failure is reported the way POSIX documents, with `errno`.

// The clock ids match the kernel's.
#assert(int(Clock.REALTIME)           == int(linux.Clock_Id.REALTIME))
#assert(int(Clock.MONOTONIC)          == int(linux.Clock_Id.MONOTONIC))
#assert(int(Clock.PROCESS_CPUTIME_ID) == int(linux.Clock_Id.PROCESS_CPUTIME_ID))
#assert(int(Clock.THREAD_CPUTIME_ID)  == int(linux.Clock_Id.THREAD_CPUTIME_ID))

// Reads the clock through the kernel vDSO on amd64, falling back to the raw
// system call everywhere else. One gate for the wrappers below: the vDSO
// answers supported reads in userspace, while unsupported clocks and errors
// take the same system call path as before, preserving errno contracts.
@(private="file")
_clock_gettime_sys :: proc "contextless" (clock_id: linux.Clock_Id) -> (linux.Time_Spec, linux.Errno) {
	when ODIN_ARCH == .amd64 {
		return linux.clock_gettime_fast(clock_id)
	} else {
		return linux.clock_gettime(clock_id)
	}
}

// Reads the clock resolution through the kernel vDSO on amd64, falling back
// to the raw system call everywhere else. One gate for clock_getres below:
// the vDSO answers supported reads in userspace, while unsupported clocks
// and errors take the same system call path as before, preserving errno
// contracts.
@(private="file")
_clock_getres_sys :: proc "contextless" (clock_id: linux.Clock_Id) -> (linux.Time_Spec, linux.Errno) {
	when ODIN_ARCH == .amd64 {
		return linux.clock_getres_fast(clock_id)
	} else {
		return linux.clock_getres(clock_id)
	}
}

/*
Returns the resolution of any clock.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/clock_getres.html ]]
*/
clock_getres :: proc "c" (clock_id: Clock, res: ^timespec) -> result {
	r, err := _clock_getres_sys(linux.Clock_Id(int(clock_id)))
	if err != .NONE {
		set_errno(Errno(err))
		return .FAIL
	}
	// The resolution argument is nullable: a nil res only queries whether
	// the clock ID is valid.
	if res == nil {
		return .OK
	}
	// Assigned field by field: on 32-bit architectures the kernel
	// timespec is narrower than posix.timespec, so a whole-struct
	// copy would misplace the members.
	res.tv_sec  = time_t(r.time_sec)
	res.tv_nsec = c.long(r.time_nsec)
	return .OK
}

/*
Returns the current value tp for the specified clock, clock_id.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/clock_getres.html ]]
*/
clock_gettime :: proc "c" (clock_id: Clock, tp: ^timespec) -> result {
	t, err := _clock_gettime_sys(linux.Clock_Id(int(clock_id)))
	if err != .NONE {
		set_errno(Errno(err))
		return .FAIL
	}
	// Assigned field by field: on 32-bit architectures the kernel
	// timespec is narrower than posix.timespec, so a whole-struct
	// copy would misplace the members.
	tp.tv_sec  = time_t(t.time_sec)
	tp.tv_nsec = c.long(t.time_nsec)
	return .OK
}

/*
Sets the specified clock's time.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/clock_getres.html ]]
*/
clock_settime :: proc "c" (clock_id: Clock, tp: ^timespec) -> result {
	return errno_result(linux.clock_settime(linux.Clock_Id(int(clock_id)), cast(^linux.Time_Spec)tp))
}

/*
Causes the current thread to be suspended from execution until either the time interval
specified by rqtp has elapsed or a signal is delivered.

Returns: -1 on failure (setting errno), if it was due to a signal, rmtp will be filled with the
remaining time, 0 if all time has been slept

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/nanosleep.html ]]
*/
nanosleep :: proc "c" (rqtp: ^timespec, rmtp: ^timespec) -> result {
	// The kernel writes the remaining time into rmtp on EINTR unless it is
	// nil, so passing it through preserves that contract.
	return errno_result(linux.nanosleep(cast(^linux.Time_Spec)rqtp, cast(^linux.Time_Spec)rmtp))
}

/*
Returns the processor time used by the process, in units of CLOCKS_PER_SEC.

Returns -1 on failure: with the call's errno when the underlying clock is
unavailable, and with errno untouched when the value cannot be represented
in a clock_t (Linux clock(3)).

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/clock.html ]]
[[ More; https://man7.org/linux/man-pages/man3/clock.3.html ]]
*/
clock :: proc "c" () -> clock_t {
	ts, err := _clock_gettime_sys(.PROCESS_CPUTIME_ID)
	if err != .NONE {
		set_errno(Errno(err))
		return -1
	}
	// Ticks are seconds scaled by CLOCKS_PER_SEC plus whole microseconds.
	// i128 arithmetic keeps the overflow check below exact on every
	// architecture, including 32-bit clock_t.
	ticks := i128(ts.time_sec) * CLOCKS_PER_SEC + i128(ts.time_nsec) / 1_000
	if ticks > i128(max(clock_t)) {
		return -1
	}
	return clock_t(ticks)
}

/*
Returns the difference `time1 - time0` in seconds as a floating-point number,
as POSIX requires.

The magnitude is differenced as integers first, so adjacent seconds stay
distinct past 2^53 and signed extremes cannot overflow; only the final
conversion rounds. The result is always finite.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/difftime.html ]]
*/
difftime :: proc "c" (time1, time0: time_t) -> c.double {
	if time1 >= time0 {
		return c.double(u64(time1) - u64(time0))
	}
	return -c.double(u64(time0) - u64(time1))
}

/*
Returns the calendar time encoded as a `time_t`, and stores it through `t`
when `t` is not nil. A nil `t` only skips the store.

Returns -1 (setting errno) on failure.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/time.html ]]
*/
time :: proc "c" (timer: ^time_t) -> time_t {
	ts, err := _clock_gettime_sys(.REALTIME)
	if err != .NONE {
		set_errno(Errno(err))
		return -1
	}
	sec := time_t(ts.time_sec)
	if timer != nil {
		timer^ = sec
	}
	return sec
}

// Breaks `t` seconds since the epoch into a UTC calendar date over the
// proleptic Gregorian calendar in core:time/datetime, storing it in the
// caller-owned record. Negative epochs round the day down, so every field
// stays in range. A year that cannot fit tm_year fails with EOVERFLOW.
//
// The zone fields name UTC the way the Linux library does: zero offset,
// GMT designation.
@(private="file")
_GMT_ZONE := "GMT"

@(private="file")
_gmtime_fill :: proc "contextless" (t: time_t, result: ^tm) -> ^tm {
	secs := i64(t)
	days := secs / 86400
	rem := secs % 86400
	if rem < 0 {
		days -= 1
		rem += 86400
	}

	epoch, _ := dt.date_to_ordinal(dt.Date{1970, 1, 1})
	ord := epoch + days
	date, derr := dt.ordinal_to_date(ord)
	if derr != .None {
		set_errno(.EOVERFLOW)
		return nil
	}
	rel := date.year - 1900
	if rel < i64(min(c.int)) || rel > i64(max(c.int)) {
		set_errno(.EOVERFLOW)
		return nil
	}
	jan1, _ := dt.date_to_ordinal(dt.Date{date.year, 1, 1})

	result.tm_sec   = c.int(rem % 60)
	result.tm_min   = c.int(rem / 60 % 60)
	result.tm_hour  = c.int(rem / 3600)
	result.tm_mday  = c.int(date.day)
	result.tm_mon   = c.int(date.month) - 1
	result.tm_year  = c.int(rel)
	result.tm_wday  = c.int(dt.day_of_week(ord))
	result.tm_yday  = c.int(ord - jan1)
	result.tm_isdst = 0
	result.tm_gmtoff = 0
	result.tm_zone = rawptr(raw_data(_GMT_ZONE))
	return result
}

/*
Converts the time in seconds since epoch to a broken-down UTC tm struct in
the caller-owned record.

Returns: nil (setting errno) on failure, the result pointer on success.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/gmtime_r.html ]]
[[ More; https://man7.org/linux/man-pages/man3/gmtime.3.html ]]
*/
gmtime_r :: proc "c" (timer: ^time_t, result: ^tm) -> ^tm {
	if timer == nil || result == nil {
		set_errno(.EINVAL)
		return nil
	}
	return _gmtime_fill(timer^, result)
}

// The native gmtime keeps its static result in thread-local storage, so
// threads never overwrite each other. It exists only where no libc shares
// the buffer with actual C localtime and ctime calls.
when ODIN_NO_CRT {

@(private="file", thread_local)
_gmtime_static: tm

/*
Converts the time in seconds since epoch to a broken-down UTC tm struct in
a static thread-local buffer, overwritten by later calls on this thread.

Returns: nil (setting errno) on failure, the result pointer on success.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/gmtime.html ]]
[[ More; https://man7.org/linux/man-pages/man3/gmtime.3.html ]]
*/
gmtime :: proc "c" (timer: ^time_t) -> ^tm {
	if timer == nil {
		set_errno(.EINVAL)
		return nil
	}
	return _gmtime_fill(timer^, &_gmtime_static)
}

}
