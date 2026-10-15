#+build linux amd64
package tests_core_posix

import "core:sys/linux"
import "core:sys/posix"
import "core:testing"

@(test)
test_lockf_shared_lock_conflict :: proc(t: ^testing.T) {
	name :: "/tmp/odin-lockf-XXXXXX"
	template: [len(name)+1]byte
	copy(template[:], name)
	fd := posix.mkstemp(cstring(&template[0]))
	if !testing.expect(t, fd >= 0) {
		return
	}
	defer posix.close(fd)
	posix.unlink(cstring(&template[0]))

	lock := posix.flock{l_type = .RDLCK, l_whence = 0, l_len = 1}
	if !testing.expect_value(t, posix.fcntl(fd, .SETLK, &lock), 0) {
		return
	}
	child := posix.fork()
	if child == 0 {
		// Stay allocation-free after fork. A shared lock must conflict
		// with the write lock that lockf would acquire.
		if posix.lockf(fd, .TEST, 1) != .FAIL || posix.errno() != .EACCES {
			posix._exit(1)
		}
		posix._exit(0)
	}
	if !testing.expect(t, child > 0) {
		return
	}
	status: i32
	waited: posix.pid_t
	for {
		waited = posix.waitpid(child, &status, {})
		if waited != -1 || posix.errno() != .EINTR {
			break
		}
	}
	testing.expect_value(t, waited, child)
	testing.expect(t, posix.WIFEXITED(status))
	testing.expect_value(t, posix.WEXITSTATUS(status), 0)
}

@(test)
test_termios_input_speed :: proc(t: ^testing.T) {
	fd := posix.posix_openpt({.RDWR, .NOCTTY})
	if !testing.expect(t, fd >= 0) {
		return
	}
	defer posix.close(fd)

	attrs: posix.termios
	if !testing.expect_value(t, posix.tcgetattr(fd, &attrs), posix.result.OK) {
		return
	}
	kernel: linux.Termios2
	_, err := linux.ioctl(linux.Fd(fd), linux.TCGETS2, uintptr(&kernel))
	if !testing.expect_value(t, err, linux.Errno.NONE) {
		return
	}
	// A new PTY has zero input baud bits, which the kernel resolves to
	// the output speed. Check its numeric rate independently with TCGETS2.
	testing.expect_value(t, kernel.cflag & linux.CIBAUD, u32(0))
	testing.expect_value(t, kernel.ispeed, u32(38400))
	testing.expect_value(t, posix.cfgetispeed(&attrs), posix.speed_t(posix.B38400))

	// An explicit input rate must not use the output fallback.
	testing.expect_value(t, posix.cfsetispeed(&attrs, posix.speed_t(posix.B19200)), posix.result.OK)
	if !testing.expect_value(t, posix.tcsetattr(fd, .TCSANOW, &attrs), posix.result.OK) {
		return
	}
	testing.expect_value(t, posix.tcgetattr(fd, &attrs), posix.result.OK)
	_, err = linux.ioctl(linux.Fd(fd), linux.TCGETS2, uintptr(&kernel))
	testing.expect_value(t, err, linux.Errno.NONE)
	testing.expect_value(t, kernel.ispeed, u32(19200))
	testing.expect_value(t, kernel.ospeed, u32(38400))
	testing.expect_value(t, posix.cfgetispeed(&attrs), posix.speed_t(posix.B19200))
}
