#+build linux
package posix

import "core:c"
import "core:sys/linux"

// The Linux implementation of realpath(3) through system calls, without libc.
// Components resolve left to right against lstat: '.', '..', and symbolic
// links expand textually, anything else the kernel reports surfaces as-is.

// Nested symbolic links the kernel follows before reporting ELOOP.
@(private="file")
_REALPATH_MAX_LINKS :: 40

/*
Derives, from the pathname file_name, an absolute pathname that resolves to
the same directory entry, without '.', '..', or symbolic links. Relative
paths resolve against the working directory. Every component must exist; a
trailing slash requires the result to be a directory.

If resolved_name is not nil it must hold at least PATH_MAX bytes and takes
the result. Otherwise the result is allocated with malloc and owned by the
caller. Returns nil (setting errno) on failure.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/realpath.html ]]
[[ More; https://man7.org/linux/man-pages/man3/realpath.3.html ]]
*/
realpath :: proc "c" (file_name: cstring, resolved_name: [^]byte = nil) -> cstring {
	if file_name == nil {
		set_errno(.EINVAL)
		return nil
	}
	name := string(file_name)
	if len(name) == 0 {
		set_errno(.ENOENT)
		return nil
	}

	// Absolute working path, NUL room included. Two buffers alternate so a
	// link expansion never overlaps its own remainder.
	bufs: [2][PATH_MAX]byte
	cur := 0
	rest_len := len(name)
	if name[0] == '/' {
		if len(name) >= PATH_MAX {
			set_errno(.ENAMETOOLONG)
			return nil
		}
		copy(bufs[0][:], name)
	} else {
		cwd: [PATH_MAX]byte
		m, cerr := linux.getcwd(cwd[:])
		if cerr != .NONE {
			set_errno(Errno(cerr))
			return nil
		}
		if m <= 1 || cwd[0] != '/' {
			// The kernel prefixes "(unreachable)" when the working
			// directory is outside the process root.
			set_errno(.ENOENT)
			return nil
		}
		cwd_len := m - 1
		if cwd_len + 1 + len(name) >= PATH_MAX {
			set_errno(.ENAMETOOLONG)
			return nil
		}
		at := copy(bufs[0][:], cwd[:cwd_len])
		bufs[0][at] = '/'
		copy(bufs[0][at+1:], name)
		rest_len = cwd_len + 1 + len(name)
	}

	out: [PATH_MAX]byte
	out_len := 0
	link: [PATH_MAX]byte
	links := 0
	trailing := false
	rest := string(bufs[cur][:rest_len])
	st: linux.Stat
	for len(rest) > 0 {
		for len(rest) > 0 && rest[0] == '/' {
			rest = rest[1:]
		}
		if len(rest) == 0 {
			trailing = true
			break
		}
		end := 0
		for end < len(rest) && rest[end] != '/' {
			end += 1
		}
		comp := rest[:end]
		tail := rest[end:]
		prev_len := out_len

		need := out_len + 1 + len(comp)
		if need >= PATH_MAX {
			set_errno(.ENAMETOOLONG)
			return nil
		}
		out[out_len] = '/'
		copy(out[out_len+1:], comp)
		out_len = need
		out[out_len] = 0

		if lerr := linux.lstat(cstring(&out[0]), &st); lerr != .NONE {
			set_errno(Errno(lerr))
			return nil
		}
		if linux.S_ISLNK(st.mode) {
			links += 1
			if links > _REALPATH_MAX_LINKS {
				set_errno(.ELOOP)
				return nil
			}
			rn, rerr := linux.readlink(cstring(&out[0]), link[:])
			if rerr != .NONE {
				set_errno(Errno(rerr))
				return nil
			}
			target := string(link[:rn])
			// The remainder keeps its separators so a trailing slash
			// survives the expansion.
			if len(target) + len(tail) >= PATH_MAX {
				set_errno(.ENAMETOOLONG)
				return nil
			}
			out_len = prev_len
			if target[0] == '/' {
				out_len = 0
			}
			cur = 1 - cur
			at := copy(bufs[cur][:], target)
			copy(bufs[cur][at:], tail)
			rest = string(bufs[cur][:at+len(tail)])
			trailing = false
			continue
		}
		if comp == ".." {
			// Drop the appended ".." and its parent; root has no parent.
			out_len = prev_len
			for out_len > 0 && out[out_len-1] != '/' {
				out_len -= 1
			}
			if out_len > 0 {
				out_len -= 1
			}
		} else if comp == "." {
			out_len = prev_len
		}
		rest = tail
		trailing = false
		for len(rest) > 0 && rest[0] == '/' {
			rest = rest[1:]
			trailing = true
		}
	}
	if out_len == 0 {
		out[0] = '/'
		out_len = 1
	}
	out[out_len] = 0
	if trailing {
		if serr := linux.stat(cstring(&out[0]), &st); serr != .NONE {
			set_errno(Errno(serr))
			return nil
		}
		if !linux.S_ISDIR(st.mode) {
			set_errno(.ENOTDIR)
			return nil
		}
	}

	if resolved_name != nil {
		copy(resolved_name[:out_len+1], out[:out_len+1])
		return cstring(resolved_name)
	}
	buf := malloc(c.size_t(out_len) + 1)
	if buf == nil {
		set_errno(.ENOMEM)
		return nil
	}
	copy(([^]byte)(buf)[:out_len+1], out[:out_len+1])
	return cstring(buf)
}
