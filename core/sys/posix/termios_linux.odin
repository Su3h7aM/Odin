#+build linux
package posix

import "core:c"
import "core:sys/linux"

// The Linux implementation of the terminal control procedures of `termios.h`
// through system calls, without libc.
//
// A failure is reported the same way as for the libc procedures, with `errno`.

// tcgetattr and tcsetattr hand the caller's `termios` straight to the TCGETS
// and TCSETS ioctls. Its first 36 bytes are the kernel layout in
// `linux.Termios`; the remaining control characters and the baud rate fields
// are untouched by the kernel. The cfget/cfset procedures below use the
// kernel baud-rate bits in c_cflag, not the trailing speed fields.
#assert(size_of(termios) == 60)
#assert(offset_of(termios, c_iflag) == offset_of(linux.Termios, iflag))
#assert(offset_of(termios, c_oflag) == offset_of(linux.Termios, oflag))
#assert(offset_of(termios, c_cflag) == offset_of(linux.Termios, cflag))
#assert(offset_of(termios, c_lflag) == offset_of(linux.Termios, lflag))
#assert(offset_of(termios, c_line) == offset_of(linux.Termios, line))
#assert(offset_of(termios, c_cc) == offset_of(linux.Termios, cc))

// TCSETSW and TCSETSF follow TCSETS, so tcsetattr adds the action to the request.
#assert(linux.TCSETSW == linux.TCSETS+1)
#assert(linux.TCSETSF == linux.TCSETS+2)
#assert(int(TC_Optional_Action.TCSANOW) == 0)
#assert(int(TC_Optional_Action.TCSADRAIN) == 1)
#assert(int(TC_Optional_Action.TCSAFLUSH) == 2)

// The input baud rate field holds the same value as the output field, shifted
// left 16 bits, which the cfget/cfset procedures rely on.
#assert(u32(linux.CIBAUD)/u32(linux.CBAUD) == 0x10000)

/*
Get the input baud rate.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/cfgetispeed.html ]]
*/
cfgetispeed :: proc "c" (termios_p: ^termios) -> speed_t {
	cflag := u32(transmute(tcflag_t)termios_p.c_cflag)
	rate := (cflag & u32(linux.CIBAUD)) / (u32(linux.CIBAUD) / u32(linux.CBAUD))
	// A zero input-speed field uses the output speed, including after
	// cfsetispeed(B0). This is also how the kernel decodes TCGETS flags.
	if rate == 0 {
		rate = cflag & u32(linux.CBAUD)
	}
	return speed_t(rate)
}

/*
Set the input baud rate.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/cfsetispeed.html ]]
*/
cfsetispeed :: proc "c" (termios_p: ^termios, rate: speed_t) -> result {
	if u32(rate) & ~u32(linux.CBAUD) != 0 {
		set_errno(.EINVAL)
		return .FAIL
	}
	cflag := u32(transmute(tcflag_t)termios_p.c_cflag)
	set := u32(rate) * (u32(linux.CIBAUD) / u32(linux.CBAUD))
	termios_p.c_cflag = transmute(CControl_Flags)tcflag_t((cflag & ~u32(linux.CIBAUD)) | set)
	return .OK
}

/*
Get the output baud rate.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/cfgetospeed.html ]]
*/
cfgetospeed :: proc "c" (termios_p: ^termios) -> speed_t {
	cflag := u32(transmute(tcflag_t)termios_p.c_cflag)
	return speed_t(cflag & u32(linux.CBAUD))
}

/*
Set the output baud rate.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/cfsetospeed.html ]]
*/
cfsetospeed :: proc "c" (termios_p: ^termios, rate: speed_t) -> result {
	if u32(rate) & ~u32(linux.CBAUD) != 0 {
		set_errno(.EINVAL)
		return .FAIL
	}
	cflag := u32(transmute(tcflag_t)termios_p.c_cflag)
	termios_p.c_cflag = transmute(CControl_Flags)tcflag_t((cflag & ~u32(linux.CBAUD)) | u32(rate))
	return .OK
}

/*
Wait for transmission of output.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/tcdrain.html ]]
*/
tcdrain :: proc "c" (fildes: FD) -> result {
	_, err := linux.ioctl(linux.Fd(fildes), linux.TCSBRK, 1)
	return errno_result(err)
}

/*
Suspend or restart the transmission or reception of data.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/tcflow.html ]]
*/
tcflow :: proc "c" (fildes: FD, action: TC_Action) -> result {
	_, err := linux.ioctl(linux.Fd(fildes), linux.TCXONC, uintptr(action))
	return errno_result(err)
}

/*
Flush non-transmitted output data, non-read input data, or both.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/tcflush.html ]]
*/
tcflush :: proc "c" (fildes: FD, queue_selector: TC_Queue) -> result {
	_, err := linux.ioctl(linux.Fd(fildes), linux.TCFLSH, uintptr(queue_selector))
	return errno_result(err)
}

/*
Get the parameters associated with the terminal.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/tcgetattr.html ]]
*/
tcgetattr :: proc "c" (fildes: FD, termios_p: ^termios) -> result {
	_, err := linux.ioctl(linux.Fd(fildes), linux.TCGETS, uintptr(termios_p))
	return errno_result(err)
}

/*
Get the process group ID for the session leader for the controlling terminal.

Returns: -1 (setting errno) on failure, the pid otherwise

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/tcgetsid.html ]]
*/
tcgetsid :: proc "c" (fildes: FD) -> pid_t {
	sid: linux.Pid
	_, err := linux.ioctl(linux.Fd(fildes), linux.TIOCGSID, uintptr(&sid))
	return errno_pid(sid, err)
}

/*
Send a break for a specific duration.

A zero duration sends the standard break; a nonzero one is
implementation-defined, so the duration is ignored and TCSBRK with 0 sends
the standard break in both cases (3-termios.md).

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/tcsendbreak.html ]]
*/
tcsendbreak :: proc "c" (fildes: FD, duration: c.int) -> result {
	_, err := linux.ioctl(linux.Fd(fildes), linux.TCSBRK, 0)
	return errno_result(err)
}

/*
Set the parameters associated with the terminal.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/tcsetattr.html ]]
*/
tcsetattr :: proc "c" (fildes: FD, optional_actions: TC_Optional_Action, termios_p: ^termios) -> result {
	act := int(optional_actions)
	if act < 0 || act > 2 {
		set_errno(.EINVAL)
		return .FAIL
	}
	_, err := linux.ioctl(linux.Fd(fildes), linux.TCSETS+u32(act), uintptr(termios_p))
	return errno_result(err)
}
