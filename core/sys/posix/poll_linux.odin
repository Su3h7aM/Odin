#+build linux
package posix

import "core:c"
import "core:sys/linux"

// The Linux implementation of `poll` through system calls, without libc.
//
// A failure is reported the same way as for the libc procedure, with `errno`.

// `linux.poll` takes the same array, so the caller's entries are handed over
// directly. The layouts must match exactly.
#assert(size_of(pollfd) == size_of(linux.Poll_Fd))
#assert(offset_of(pollfd, fd) == offset_of(linux.Poll_Fd, fd))
#assert(offset_of(pollfd, events) == offset_of(linux.Poll_Fd, events))
#assert(offset_of(pollfd, revents) == offset_of(linux.Poll_Fd, revents))
#assert(size_of(FD) == size_of(linux.Fd))
#assert(size_of(Poll_Event) == size_of(linux.Fd_Poll_Events))

// Each posix bit must be the matching kernel bit.
#assert(int(Poll_Event_Bits.IN)     == int(linux.Fd_Poll_Events_Bits.IN))
#assert(int(Poll_Event_Bits.PRI)    == int(linux.Fd_Poll_Events_Bits.PRI))
#assert(int(Poll_Event_Bits.OUT)    == int(linux.Fd_Poll_Events_Bits.OUT))
#assert(int(Poll_Event_Bits.ERR)    == int(linux.Fd_Poll_Events_Bits.ERR))
#assert(int(Poll_Event_Bits.HUP)    == int(linux.Fd_Poll_Events_Bits.HUP))
#assert(int(Poll_Event_Bits.NVAL)   == int(linux.Fd_Poll_Events_Bits.NVAL))
#assert(int(Poll_Event_Bits.RDNORM) == int(linux.Fd_Poll_Events_Bits.RDNORM))
#assert(int(Poll_Event_Bits.RDBAND) == int(linux.Fd_Poll_Events_Bits.RDBAND))
#assert(int(Poll_Event_Bits.WRNORM) == int(linux.Fd_Poll_Events_Bits.WRNORM))
#assert(int(Poll_Event_Bits.WRBAND) == int(linux.Fd_Poll_Events_Bits.WRBAND))

/*
For each pointer in fds, poll() shall examine the given descriptor for the events.
poll will identify on which descriptors writes or reads can be done.

Returns: -1 (setting errno) on failure, 0 on timeout, the amount of fds that have been changed on success.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/poll.html ]]
*/
poll :: proc "c" (fds: [^]pollfd, nfds: nfds_t, timeout: c.int) -> c.int {
	fds_slice: []linux.Poll_Fd
	if nfds > 0 {
		fds_slice = ([^]linux.Poll_Fd)(fds)[:int(nfds)]
	}
	n, err := linux.poll(fds_slice, i32(timeout))
	return errno_int(int(n), err)
}
