package time

import "core:sys/linux"

_IS_SUPPORTED :: true

// Reads the clock through the kernel vDSO on amd64, falling back to the raw
// system call everywhere else. Matches the gate in core:sys/posix so both
// clock consumers share one policy.
@(private="file")
_clock_gettime_sys :: proc "contextless" (clock: linux.Clock_Id) -> (linux.Time_Spec, linux.Errno) {
	when ODIN_ARCH == .amd64 {
		return linux.clock_gettime_fast(clock)
	} else {
		return linux.clock_gettime(clock)
	}
}

_now :: proc "contextless" () -> Time {
	time_spec_now, _ := _clock_gettime_sys(.REALTIME)
	ns := i64(time_spec_now.time_sec) * 1e9 + i64(time_spec_now.time_nsec)
	return Time{_nsec=ns}
}

_sleep :: proc "contextless" (d: Duration) {
	ds := duration_seconds(d)
	seconds := uint(ds)
	nanoseconds := uint((ds - f64(seconds)) * 1e9)

	ts := linux.Time_Spec{
		time_sec  = seconds,
		time_nsec = nanoseconds,
	}

	for {
		if linux.nanosleep(&ts, &ts) != .EINTR {
			break
		}
	}
}

_tick_now :: proc "contextless" () -> Tick {
	t, _ := _clock_gettime_sys(.MONOTONIC_RAW)
	return Tick{_nsec = i64(t.time_sec)*1e9 + i64(t.time_nsec)}
}

_yield :: proc "contextless" () {
	linux.sched_yield()
}

