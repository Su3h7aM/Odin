#+private
package os

import "core:sys/linux"

_pipe :: proc() -> (r, w: ^File, err: Error) {
	fds: [2]linux.Fd
	errno := linux.pipe2(&fds, {.CLOEXEC})
	if errno != .NONE {
		return nil, nil,_get_platform_error(errno)
	}
	defer if err != nil {
		if r != nil {
			close(r)
		} else {
			linux.close(fds[0])
		}
		linux.close(fds[1])
	}

	// `_new_file` does not take the descriptor on failure, so this closes what
	// it was given, and the read end if the write end is the one that failed.
	r, err = _new_file(uintptr(fds[0]), "", file_allocator())
	if err != nil {
		return nil, nil, err
	}
	w, err = _new_file(uintptr(fds[1]), "", file_allocator())
	if err != nil {
		return nil, nil, err
	}

	return
}

@(require_results)
_pipe_has_data :: proc(r: ^File) -> (ok: bool, err: Error) {
	if r == nil || r.impl == nil {
		return false, nil
	}
	fd := linux.Fd((^File_Impl)(r.impl).fd)
	poll_fds := []linux.Poll_Fd {
		linux.Poll_Fd {
			fd = fd,
			events = {.IN, .HUP},
		},
	}
	n, errno := linux.poll(poll_fds, 0)
	if n != 1 || errno != nil {
		return false, _get_platform_error(errno)
	}
	pipe_events := poll_fds[0].revents
	if pipe_events >= {.IN} {
		return true, nil
	}
	if pipe_events >= {.HUP} {
		return false, .Broken_Pipe
	}
	return false, nil
}