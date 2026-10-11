#+build linux
#+private
package thread

import "base:runtime"
import "core:strings"
import "core:sys/linux"

_MAX_PTHREAD_NAME_LENGTH :: 16

// The kernel keeps thread names itself, so ordinary builds set and read
// them with prctl and procfs instead of libc's pthread_getname_np and
// pthread_setname_np. Thread creation still uses pthread.
linux_thread_set_name :: proc(name: string) {
	buf: [16]u8
	copy(buf[:15], name)
	linux.prctl(linux.PR_SET_NAME, uint(uintptr(&buf)))
}

linux_thread_self_name :: proc(allocator: runtime.Allocator, loc: runtime.Source_Code_Location) -> (name: string, err: runtime.Allocator_Error) {
	buf: [16]u8
	n: int
	if linux.prctl(linux.PR_GET_NAME, uint(uintptr(&buf))) == .NONE {
		for n < 15 && buf[n] != 0 {
			n += 1
		}
	}
	return strings.clone(string(buf[:n]), allocator, loc)
}

linux_thread_get_name :: proc(id: int, allocator: runtime.Allocator, loc: runtime.Source_Code_Location) -> (name: string, err: runtime.Allocator_Error) {
	buf: [16]u8
	n: int
	if id == int(linux.gettid()) {
		if linux.prctl(linux.PR_GET_NAME, uint(uintptr(&buf))) == .NONE {
			for n < 15 && buf[n] != 0 {
				n += 1
			}
		}
	} else if id > 0 {
		path: [64]u8
		length := copy(path[:], "/proc/self/task/")
		digits: [10]u8
		digit_at := len(digits)
		rest := uint(id)
		for {
			digit_at -= 1
			digits[digit_at] = u8(rest%10) + '0'
			rest /= 10
			if rest == 0 {
				break
			}
		}
		length += copy(path[length:], digits[digit_at:])
		copy(path[length:], "/comm")
		fd, open_err := linux.open(cstring(&path[0]), {.CLOEXEC})
		if open_err == .NONE {
			defer linux.close(fd)
			count, read_err := linux.read(fd, buf[:])
			if read_err == .NONE {
				n = count
				if n > 0 && buf[n-1] == '\n' {
					n -= 1
				}
			}
		}
	}
	return strings.clone(string(buf[:n]), allocator, loc)
}
