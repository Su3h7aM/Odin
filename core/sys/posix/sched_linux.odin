#+build linux amd64, linux arm64, linux riscv64
package posix

import "core:c"
import "core:sys/linux"

// The Linux implementation of the `sched.h` procedures through system calls,
// without libc.
//
// A failure is reported the same way as for the libc procedures, with `errno`.

// The policy values match the kernel's.
#assert(int(Sched_Policy.OTHER) == 0)
#assert(int(Sched_Policy.FIFO)  == 1)
#assert(int(Sched_Policy.RR)    == 2)

/*
Returns the maximum priority for the given scheduling policy.

Returns: -1 (setting errno) on failure, the maximum on success

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/sched_get_priority_max.html ]]
*/
sched_get_priority_max :: proc "c" (policy: Sched_Policy) -> c.int {
	n, err := linux.sched_get_priority_max(i32(policy))
	if err != .NONE {
		set_errno(Errno(err))
		return -1
	}
	return c.int(n)
}

/*
Returns the minimum priority for the given scheduling policy.

Returns: -1 (setting errno) on failure, the minimum on success

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/sched_get_priority_min.html ]]
*/
sched_get_priority_min :: proc "c" (policy: Sched_Policy) -> c.int {
	n, err := linux.sched_get_priority_min(i32(policy))
	if err != .NONE {
		set_errno(Errno(err))
		return -1
	}
	return c.int(n)
}

/*
Forces the running thread to relinquish the processor until it again becomes the head of its thread list.
*/
sched_yield :: proc "c" () -> result {
	// Yielding cannot fail, so errno is left alone.
	linux.sched_yield()
	return .OK
}
