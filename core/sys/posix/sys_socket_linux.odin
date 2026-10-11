#+build linux amd64, linux arm64, linux riscv64
package posix

import "core:c"
import "core:sys/linux"

// The Linux implementation of the `sys/socket.h` procedures through system
// calls, without libc.
//
// A failure is reported the same way as for the libc procedures, with
// `errno`.
//
// Socket operations use core:sys/linux wrappers with caller-supplied address
// and option lengths, without copying buffers into typed structures.

// The address family, type and protocol values match the kernel's.
#assert(int(AF.UNSPEC) == 0)
#assert(int(AF.UNIX)   == 1)
#assert(int(AF.INET)   == 2)
#assert(int(AF.INET6)  == 10)
#assert(int(Sock.STREAM)    == int(linux.Socket_Type.STREAM))
#assert(int(Sock.DGRAM)     == int(linux.Socket_Type.DGRAM))
#assert(int(Sock.RAW)       == int(linux.Socket_Type.RAW))
#assert(int(Sock.SEQPACKET) == int(linux.Socket_Type.SEQPACKET))
#assert(int(Protocol.IP)  == 0)
#assert(int(Protocol.TCP) == 6)
#assert(int(Protocol.UDP) == 17)

// The message flag positions match the kernel's.
#assert(int(Msg_Flag_Bits.OOB)      == int(linux.Socket_Msg_Bits.OOB))
#assert(int(Msg_Flag_Bits.PEEK)     == int(linux.Socket_Msg_Bits.PEEK))
#assert(int(Msg_Flag_Bits.DONTROUTE) == int(linux.Socket_Msg_Bits.DONTROUTE))
#assert(int(Msg_Flag_Bits.EOR)      == int(linux.Socket_Msg_Bits.EOR))
#assert(int(Msg_Flag_Bits.TRUNC)    == int(linux.Socket_Msg_Bits.TRUNC))
#assert(int(Msg_Flag_Bits.CTRUNC)   == int(linux.Socket_Msg_Bits.CTRUNC))
#assert(int(Msg_Flag_Bits.WAITALL)  == int(linux.Socket_Msg_Bits.WAITALL))
#assert(int(Msg_Flag_Bits.NOSIGNAL) == int(linux.Socket_Msg_Bits.NOSIGNAL))

// The shutdown values match the kernel's.
#assert(int(Shut.RD)   == int(linux.Shutdown_How.RD))
#assert(int(Shut.WR)   == int(linux.Shutdown_How.WR))
#assert(int(Shut.RDWR) == int(linux.Shutdown_How.RDWR))

// `msghdr` is the kernel layout: a name pointer, a 32-bit length, the vector
// pointer and count, the control pointer and length, and the flags.
#assert(size_of(msghdr) == size_of(linux.Msg_Hdr))
#assert(offset_of(msghdr, msg_name) == offset_of(linux.Msg_Hdr, name))
#assert(offset_of(msghdr, msg_namelen) == offset_of(linux.Msg_Hdr, namelen))
#assert(offset_of(msghdr, msg_iov) == offset_of(linux.Msg_Hdr, iov))
#assert(offset_of(msghdr, msg_iovlen) == offset_of(linux.Msg_Hdr, iov) + size_of(rawptr))
#assert(offset_of(msghdr, msg_control) == offset_of(linux.Msg_Hdr, control))
#assert(offset_of(msghdr, msg_controllen) == offset_of(linux.Msg_Hdr, control) + size_of(rawptr))
#assert(offset_of(msghdr, msg_flags) == offset_of(linux.Msg_Hdr, flags))

#assert(size_of(iovec) == size_of(linux.IO_Vec))
#assert(offset_of(iovec, iov_base) == offset_of(linux.IO_Vec, base))
#assert(offset_of(iovec, iov_len) == offset_of(linux.IO_Vec, len))
#assert(SO_RCVTIMEO == int(linux.Socket_Option.RCVTIMEO))
#assert(SO_SNDTIMEO == int(linux.Socket_Option.SNDTIMEO))

// `cmsghdr` is the kernel layout: a length and two 32-bit integers.
#assert(size_of(cmsghdr) == 16)
#assert(offset_of(cmsghdr, cmsg_len)   == 0)
#assert(offset_of(cmsghdr, cmsg_level) == 8)
#assert(offset_of(cmsghdr, cmsg_type)  == 12)

// `socklen_t` is the 32-bit length the kernel reads and writes back.
#assert(size_of(socklen_t) == 4)

/*
Creates a socket.

Returns: -1 (setting errno) on failure, file descriptor of socket otherwise

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/socket.html ]]
*/
socket :: proc "c" (domain: AF, type: Sock, protocol: Protocol = .IP) -> FD {
	// The type converts by value, so flag bits such as SOCK_NONBLOCK and
	// SOCK_CLOEXEC ride along into the kernel instead of being dropped.
	fd, err := linux.socket(
		linux.Address_Family(int(domain)),
		linux.Socket_Type(int(type)),
		{},
		linux.Protocol(int(protocol)),
	)
	return errno_fd(fd, err)
}

/*
Extracts the first connection on the queue of pending connections.

Blocks (if not O_NONBLOCK) if there is no pending connection.

Returns: -1 (setting errno) on failure, file descriptor of accepted socket otherwise

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/accept.html ]]
*/
accept :: proc "c" (socket: FD, address: ^sockaddr, address_len: ^socklen_t) -> FD {
	// accept4 with no flags is accept; it exists on every architecture,
	// unlike the older accept call.
	fd, err := linux.accept_raw(linux.Fd(socket), address, cast(^u32)address_len)
	return errno_fd(fd, err)
}

/*
Assigns a local socket address to the socket.

Example:
	sfd := posix.socket(.UNIX, .STREAM)
	if sfd == -1 {
		/* Handle error */
	}

	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], "/somepath\x00")

	/*
		unlink the socket before binding in case
		of previous runs not cleaning up the socket
	*/
	posix.unlink("/somepath")

	if posix.bind(sfd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK {
		/* Handle error */
	}

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/bind.html ]]
*/
bind :: proc "c" (socket: FD, address: ^sockaddr, address_len: socklen_t) -> result {
	return errno_result(linux.bind_raw(linux.Fd(socket), address, u32(address_len)))
}

/*
Attempt to make a connection.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/connect.html ]]
*/
connect :: proc "c" (socket: FD, address: ^sockaddr, address_len: socklen_t) -> result {
	return errno_result(linux.connect_raw(linux.Fd(socket), address, u32(address_len)))
}

/*
Get the peer address of the specified socket.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/getpeername.html ]]
*/
getpeername :: proc "c" (socket: FD, address: ^sockaddr, address_len: ^socklen_t) -> result {
	return errno_result(linux.getpeername_raw(linux.Fd(socket), address, cast(^u32)address_len))
}

/*
Get the socket name.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/getsockname.html ]]
*/
getsockname :: proc "c" (socket: FD, address: ^sockaddr, address_len: ^socklen_t) -> result {
	return errno_result(linux.getsockname_raw(linux.Fd(socket), address, cast(^u32)address_len))
}

/*
Retrieves the value for the option specified by option_name.

level: either `c.int(posix.Protocol(...))` to specify a protocol level or `posix.SOL_SOCKET`
to specify the socket local level.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/getsockopt.html ]]
*/
getsockopt :: proc "c" (
	socket:       FD,
	level:        c.int,
	option_name:  Sock_Option,
	option_value: rawptr,
	option_len:   ^socklen_t,
) -> result {
	return errno_result(linux.getsockopt_raw(linux.Fd(socket), int(level), int(option_name), option_value, cast(^u32)option_len))
}

/*
Sets the specified option.

level: either `c.int(posix.Protocol(...))` to specify a protocol level or `posix.SOL_SOCKET`
to specify the socket local level.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/setsockopt.html ]]
*/
setsockopt :: proc "c" (
	socket:       FD,
	level:        c.int,
	option_name:  Sock_Option,
	option_value: rawptr,
	option_len:   socklen_t,
) -> result {
	return errno_result(linux.setsockopt_raw(linux.Fd(socket), int(level), int(option_name), option_value, u32(option_len)))
}

/*
Mark the socket as a socket accepting connections.

backlog provides a hint to limit the number of connections on the listen queue.
Implementation may silently reduce the backlog, additionally `SOMAXCONN` specifies the maximum
an implementation has to support.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/listen.html ]]
*/
listen :: proc "c" (socket: FD, backlog: c.int) -> result {
	return errno_result(linux.listen(linux.Fd(socket), i32(backlog)))
}

/*
Receives a message from a socket.

Blocks (besides with O_NONBLOCK) if there is nothing to receive.

Returns: 0 when the peer shutdown with no more messages, -1 (setting errno) on failure, the amount of bytes received on success

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/recv.html ]]
*/
recv :: proc "c" (socket: FD, buffer: rawptr, length: c.size_t, flags: Msg_Flags) -> c.ssize_t {
	return recvfrom(socket, buffer, length, flags, nil, nil)
}

/*
Receives a message from a socket.

Equivalent to recv() but retrieves the source address too.

Returns: 0 when the peer shutdown with no more messages, -1 (setting errno) on failure, the amount of bytes received on success

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/recvfrom.html ]]
*/
recvfrom :: proc "c" (
	socket:      FD,
	buffer:      rawptr,
	length:      c.size_t,
	flags:       Msg_Flags,
	address:     ^sockaddr,
	address_len: ^socklen_t,
) -> c.ssize_t {
	// There are no recv and send system calls on some architectures, so
	// recvfrom and sendto with a nil address serve everywhere.
	n, err := linux.recvfrom_raw(
		linux.Fd(socket),
		buffer,
		uint(length),
		transmute(linux.Socket_Msg)flags,
		address,
		cast(^u32)address_len,
	)
	return errno_ssize(n, err)
}

/*
Receives a message from a socket.

Returns: 0 when the peer shutdown with no more messages, -1 (setting errno) on failure, the amount of bytes received on success

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/recvmsg.html ]]
*/
recvmsg :: proc "c" (socket: FD, message: ^msghdr, flags: Msg_Flags) -> c.ssize_t {
	n, err := linux.recvmsg(linux.Fd(socket), cast(^linux.Msg_Hdr)message, transmute(linux.Socket_Msg)flags)
	return errno_ssize(n, err)
}

/*
Sends a message on a socket.

Returns: -1 (setting errno) on failure, the amount of bytes received on success

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/send.html ]]
*/
send :: proc "c" (socket: FD, buffer: rawptr, length: c.size_t, flags: Msg_Flags) -> c.ssize_t {
	return sendto(socket, buffer, length, flags, nil, 0)
}

/*
Sends a message on a socket.

Returns: -1 (setting errno) on failure, the amount of bytes received on success

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/sendmsg.html ]]
*/
sendmsg :: proc "c" (socket: FD, message: ^msghdr, flags: Msg_Flags) -> c.ssize_t {
	n, err := linux.sendmsg(linux.Fd(socket), cast(^linux.Msg_Hdr)message, transmute(linux.Socket_Msg)flags)
	return errno_ssize(n, err)
}

/*
Sends a message on a socket.

If the socket is connectionless, the dest_addr is used to send to.

Returns: -1 (setting errno) on failure, the amount of bytes received on success

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/sendto.html ]]
*/
sendto :: proc "c" (
	socket:    FD,
	message:   rawptr,
	length:    c.size_t,
	flags:     Msg_Flags,
	dest_addr: ^sockaddr,
	dest_len:  socklen_t,
) -> c.ssize_t {
	n, err := linux.sendto_raw(
		linux.Fd(socket),
		message,
		uint(length),
		transmute(linux.Socket_Msg)flags,
		dest_addr,
		u32(dest_len),
	)
	return errno_ssize(n, err)
}

/*
Shuts down a socket end or both.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/shutdown.html ]]
*/
shutdown :: proc "c" (socket: FD, how: Shut) -> result {
	return errno_result(linux.shutdown(linux.Fd(socket), linux.Shutdown_How(int(how))))
}

/*
Determine wheter a socket is at the out-of-band mark.

Returns: -1 (setting errno) on failure, 0 if not at the mark, 1 if it is

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/sockatmark.html ]]
*/
sockatmark :: proc "c" (socket: FD) -> c.int {
	// The kernel reports the mark through the SIOCATMARK ioctl.
	atmark: c.int
	_, err := linux.ioctl(linux.Fd(socket), linux.SIOCATMARK, uintptr(&atmark))
	return errno_int(int(atmark), err)
}

/*
Create a pair of connected sockets.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/socketpair.html ]]
*/
socketpair :: proc "c" (domain: AF, type: Sock, protocol: Protocol, socket_vector: ^[2]FD) -> result {
	return errno_result(
		linux.socketpair(
			linux.Protocol_Family(int(domain)),
			linux.Socket_Type(int(type)),
			linux.Protocol(int(protocol)),
			cast(^[2]linux.Fd)socket_vector,
		),
	)
}
