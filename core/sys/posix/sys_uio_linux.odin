#+build linux
package posix

import "core:c"
import "core:sys/linux"

// The Linux implementation of `readv` and `writev` through system calls,
// without libc.
//
// A failure is reported the same way as for the libc procedures, with `errno`.

// `linux.IO_Vec` has the same layout as `iovec`, so the caller's array is
// handed over directly without copying.
#assert(size_of(iovec) == size_of(linux.IO_Vec))
#assert(offset_of(iovec, iov_base) == offset_of(linux.IO_Vec, base))
#assert(offset_of(iovec, iov_len) == offset_of(linux.IO_Vec, len))

/*
Equivalent to read() but takes a vector of inputs.

iovcnt can be 0..=IOV_MAX in length.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/readv.html ]]
*/
readv :: proc "c" (fildes: FD, iov: [^]iovec, iovcnt: c.int) -> c.ssize_t {
	// A negative count cannot become a slice length, so fail with EINVAL here.
	if iovcnt < 0 {
		set_errno(.EINVAL)
		return -1
	}
	v: []linux.IO_Vec
	if iovcnt > 0 {
		v = ([^]linux.IO_Vec)(iov)[:iovcnt]
	}
	n, err := linux.readv(linux.Fd(fildes), v)
	return errno_ssize(n, err)
}

/*
Equivalent to write() but takes a vector of inputs.

iovcnt can be 0..=IOV_MAX in length.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/readv.html ]]
*/
writev :: proc "c" (fildes: FD, iov: [^]iovec, iovcnt: c.int) -> c.ssize_t {
	// A negative count cannot become a slice length, so fail with EINVAL here.
	if iovcnt < 0 {
		set_errno(.EINVAL)
		return -1
	}
	v: []linux.IO_Vec
	if iovcnt > 0 {
		v = ([^]linux.IO_Vec)(iov)[:iovcnt]
	}
	n, err := linux.writev(linux.Fd(fildes), v)
	return errno_ssize(n, err)
}
