#+build linux amd64, linux arm64, linux riscv64
package posix

import "core:c"
import "core:sys/linux"

// The Linux implementation of the `select` and `pselect` procedures of
// `sys/select.h` through the `pselect6` system call, without libc.
//
// A failure is reported the same way as for the libc procedures, with `errno`.

// `fd_set` holds the same 1024 bits as the bitmap the syscall takes, so a set
// is passed by reinterpreting it. This is only sound while the sizes agree.
#assert(size_of(fd_set) == size_of(linux.FD_Set))
#assert(size_of(fd_set) == 128)

// The kernel signal set is the first word of the 1024-bit `sigset_t`.
#assert(size_of(linux.Sig_Set) == size_of(c.ulong))
#assert(offset_of(sigset_t, __val) == 0)

// A set for the syscall, or nil when the caller passed none.
@(private="file")
fd_bitmap :: proc "contextless" (set: ^fd_set) -> [^]uint {
	return cast([^]uint)set
}

/*
Examines the file descriptor sets to see whether some of their descriptors are ready for reading,
ready for writing, or have an exceptional condition pending, respectively.

On Linux the remaining time is written back into the caller's timeout after every return; POSIX permits either behavior.

Returns: -1 (setting errno) on failure, total amount of bits set in the bit masks otherwise

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/select.html ]]
*/
select :: proc "c" (
	nfds:     c.int,
	readfds:  ^fd_set,
	writefds: ^fd_set,
	errorfds: ^fd_set,
	timeout:  ^timeval,
) -> c.int {
	ts: linux.Time_Spec
	ts_ptr: ^linux.Time_Spec
	if timeout != nil {
		sec := i64(timeout.tv_sec)
		usec := i64(timeout.tv_usec)
		// The kernel rejects out-of-range intervals with EINVAL instead of
		// normalizing them, so check first and convert exactly.
		if sec < 0 || usec < 0 || usec > 999_999 {
			set_errno(.EINVAL)
			return -1
		}
		ts = {uint(sec), uint(usec * 1_000)}
		ts_ptr = &ts
	}
	n, err := linux.pselect6(i32(nfds), fd_bitmap(readfds), fd_bitmap(writefds), fd_bitmap(errorfds), ts_ptr, nil)
	if timeout != nil {
		timeout.tv_sec = time_t(ts.time_sec)
		timeout.tv_usec = suseconds_t(ts.time_nsec / 1_000)
	}
	return errno_int(n, err)
}

/*
Equivalent to select() except the timeout has nanosecond resolution and is never modified,
and the thread's signal mask is replaced by sigmask, if not nil, for the duration of the wait.

Returns: -1 (setting errno) on failure, total amount of bits set in the bit masks otherwise

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/pselect.html ]]
*/
pselect :: proc "c" (
	nfds:     c.int,
	readfds:  ^fd_set,
	writefds: ^fd_set,
	errorfds: ^fd_set,
	timeout:  ^timespec,
	sigmask:  ^sigset_t,
) -> c.int {
	// The kernel writes the time left back into the timeout, so pass it a copy.
	ts: linux.Time_Spec
	ts_ptr: ^linux.Time_Spec
	if timeout != nil {
		ts = {uint(timeout.tv_sec), uint(timeout.tv_nsec)}
		ts_ptr = &ts
	}
	mask: linux.Pselect_Sigmask
	mask_ptr: ^linux.Pselect_Sigmask
	if sigmask != nil {
		// The mask for the kernel never blocks libc's internal signals.
		filtered := without_internal_signals(to_kernel_set(sigmask))
		mask = {&filtered, size_of(linux.Sig_Set)}
		mask_ptr = &mask
	}
	n, err := linux.pselect6(i32(nfds), fd_bitmap(readfds), fd_bitmap(writefds), fd_bitmap(errorfds), ts_ptr, mask_ptr)
	return errno_int(n, err)
}
