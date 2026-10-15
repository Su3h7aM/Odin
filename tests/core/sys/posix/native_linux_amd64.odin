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
			posix._Exit(1)
		}
		posix._Exit(0)
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

@(test)
test_rename_replaces_destination :: proc(t: ^testing.T) {
	old_template := [len("/tmp/odin-rename-old-XXXXXX")+1]byte{}
	new_template := [len("/tmp/odin-rename-new-XXXXXX")+1]byte{}
	copy(old_template[:], "/tmp/odin-rename-old-XXXXXX")
	copy(new_template[:], "/tmp/odin-rename-new-XXXXXX")
	old_name := cstring(&old_template[0])
	new_name := cstring(&new_template[0])
	old_fd := posix.mkstemp(old_name)
	if !testing.expect(t, old_fd >= 0) {
		return
	}
	defer posix.close(old_fd)
	defer posix.unlink(old_name)
	new_fd := posix.mkstemp(new_name)
	if !testing.expect(t, new_fd >= 0) {
		return
	}
	defer posix.close(new_fd)
	defer posix.unlink(new_name)

	before, after: linux.Stat
	if !testing.expect_value(t, linux.fstat(linux.Fd(old_fd), &before), linux.Errno.NONE) {
		return
	}
	if !testing.expect_value(t, posix.rename(old_name, new_name), 0) {
		return
	}
	if testing.expect_value(t, linux.stat(new_name, &after), linux.Errno.NONE) {
		testing.expect_value(t, after.dev, before.dev)
		testing.expect_value(t, after.ino, before.ino)
	}
	testing.expect_value(t, linux.stat(old_name, &after), linux.Errno.ENOENT)
	testing.expect_value(t, posix.rename(old_name, new_name), -1)
	testing.expect_value(t, posix.errno(), posix.Errno.ENOENT)
}

@(test)
test_interface_name_index :: proc(t: ^testing.T) {
	index := posix.if_nametoindex("lo")
	if !testing.expect(t, index != 0) {
		return
	}
	name: [posix.IF_NAMESIZE]byte
	if testing.expect_value(t, posix.if_indextoname(index, raw_data(name[:])), cstring(&name[0])) {
		testing.expect_value(t, string(cstring(&name[0])), "lo")
	}
	testing.expect_value(t, posix.if_nametoindex(""), 0)
	testing.expect_value(t, posix.errno(), posix.Errno.ENODEV)
	testing.expect_value(t, posix.if_indextoname(0, raw_data(name[:])), cstring(nil))
	testing.expect_value(t, posix.errno(), posix.Errno.ENXIO)
}
