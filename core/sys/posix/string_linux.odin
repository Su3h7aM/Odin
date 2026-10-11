#+build linux
package posix

import "base:intrinsics"
import "core:c"

// The Linux implementation of the `string.h` error-message procedure,
// without libc.
//
// Messages follow musl's strerror table (src/errno/__strerror.h, MIT
// licensed). Numbers the table does not know report "Unknown error" like
// libc does. Every message is a string literal, so the result stays valid
// indefinitely.

_strerror :: proc "c" (errnum: Errno) -> cstring {
	switch errnum {
	case .NONE:            return "No error information"
	case .EPERM:           return "Operation not permitted"
	case .ENOENT:          return "No such file or directory"
	case .ESRCH:           return "No such process"
	case .EINTR:           return "Interrupted system call"
	case .EIO:             return "I/O error"
	case .ENXIO:           return "No such device or address"
	case .E2BIG:           return "Argument list too long"
	case .ENOEXEC:         return "Exec format error"
	case .EBADF:           return "Bad file descriptor"
	case .ECHILD:          return "No child process"
	case .EAGAIN:          return "Resource temporarily unavailable"
	case .ENOMEM:          return "Out of memory"
	case .EACCES:          return "Permission denied"
	case .EFAULT:          return "Bad address"
	case .EBUSY:           return "Resource busy"
	case .EEXIST:          return "File exists"
	case .EXDEV:           return "Cross-device link"
	case .ENODEV:          return "No such device"
	case .ENOTDIR:         return "Not a directory"
	case .EISDIR:          return "Is a directory"
	case .EINVAL:          return "Invalid argument"
	case .ENFILE:          return "Too many open files in system"
	case .EMFILE:          return "No file descriptors available"
	case .ENOTTY:          return "Not a tty"
	case .ETXTBSY:         return "Text file busy"
	case .EFBIG:           return "File too large"
	case .ENOSPC:          return "No space left on device"
	case .ESPIPE:          return "Invalid seek"
	case .EROFS:           return "Read-only file system"
	case .EMLINK:          return "Too many links"
	case .EPIPE:           return "Broken pipe"
	case .EDOM:            return "Domain error"
	case .ERANGE:          return "Result not representable"
	case .EDEADLK:         return "Resource deadlock would occur"
	case .ENAMETOOLONG:    return "Filename too long"
	case .ENOLCK:          return "No locks available"
	case .ENOSYS:          return "Function not implemented"
	case .ENOTEMPTY:       return "Directory not empty"
	case .ELOOP:           return "Symbolic link loop"
	case .ENOMSG:          return "No message of desired type"
	case .EIDRM:           return "Identifier removed"
	case .ENOSTR:          return "Device not a stream"
	case .ENODATA:         return "No data available"
	case .ETIME:           return "Device timeout"
	case .ENOSR:           return "Out of streams resources"
	case .ENOLINK:         return "Link has been severed"
	case .EPROTO:          return "Protocol error"
	case .EMULTIHOP:       return "Multihop attempted"
	case .EBADMSG:         return "Bad message"
	case .EOVERFLOW:       return "Value too large for data type"
	case .ENOTSOCK:        return "Not a socket"
	case .EDESTADDRREQ:    return "Destination address required"
	case .EMSGSIZE:        return "Message too large"
	case .EPROTOTYPE:      return "Protocol wrong type for socket"
	case .ENOPROTOOPT:     return "Protocol not available"
	case .EPROTONOSUPPORT: return "Protocol not supported"
	case .EOPNOTSUPP:      return "Not supported"
	case .EAFNOSUPPORT:    return "Address family not supported by protocol"
	case .EADDRINUSE:      return "Address in use"
	case .EADDRNOTAVAIL:   return "Address not available"
	case .ENETDOWN:        return "Network is down"
	case .ENETUNREACH:     return "Network unreachable"
	case .ENETRESET:       return "Connection reset by network"
	case .ECONNABORTED:    return "Connection aborted"
	case .ECONNRESET:      return "Connection reset by peer"
	case .ENOBUFS:         return "No buffer space available"
	case .EISCONN:         return "Socket is connected"
	case .ENOTCONN:        return "Socket not connected"
	case .ETIMEDOUT:       return "Operation timed out"
	case .ECONNREFUSED:    return "Connection refused"
	case .EHOSTUNREACH:    return "Host is unreachable"
	case .EALREADY:        return "Operation already in progress"
	case .EINPROGRESS:     return "Operation in progress"
	case .ESTALE:          return "Stale file handle"
	case .EDQUOT:          return "Quota exceeded"
	case .ECANCELED:       return "Operation canceled"
	case .EOWNERDEAD:      return "Previous owner died"
	case .ENOTRECOVERABLE: return "State not recoverable"
	case .EILSEQ:          return "Illegal byte sequence"
	case:                  return "Unknown error"
	}
}

// The Linux implementations of the `string.h` length, comparison, copy,
// search, span, duplication and tokenization procedures, without libc.
// Byte order and edge behavior follow POSIX; where POSIX leaves details to
// the implementation, musl's choices are used. Locale-sensitive collation
// and case folding are deliberately not provided here.

strlen :: proc "c" (s: cstring) -> c.size_t {
	n := 0
	p := ([^]byte)(s)
	for p[n] != 0 {
		n += 1
	}
	return c.size_t(n)
}

strnlen :: proc "c" (s: cstring, maxlen: c.size_t) -> c.size_t {
	p := ([^]byte)(s)
	n := 0
	for c.size_t(n) < maxlen && p[n] != 0 {
		n += 1
	}
	return c.size_t(n)
}

memcmp :: proc "c" (s1, s2: rawptr, n: c.size_t) -> c.int {
	a := ([^]u8)(s1)
	b := ([^]u8)(s2)
	for i := 0; i < int(n); i += 1 {
		if a[i] != b[i] {
			return c.int(a[i]) - c.int(b[i])
		}
	}
	return 0
}

strcmp :: proc "c" (s1, s2: cstring) -> c.int {
	a := ([^]byte)(s1)
	b := ([^]byte)(s2)
	i := 0
	for a[i] == b[i] {
		if a[i] == 0 {
			return 0
		}
		i += 1
	}
	return c.int(a[i]) - c.int(b[i])
}

strncmp :: proc "c" (s1, s2: cstring, n: c.size_t) -> c.int {
	a := ([^]byte)(s1)
	b := ([^]byte)(s2)
	i := 0
	for c.size_t(i) < n {
		if a[i] != b[i] {
			return c.int(a[i]) - c.int(b[i])
		}
		if a[i] == 0 {
			return 0
		}
		i += 1
	}
	return 0
}

memcpy :: proc "c" (s1, s2: rawptr, n: c.size_t) -> rawptr {
	intrinsics.mem_copy_non_overlapping(s1, s2, int(n))
	return s1
}

memmove :: proc "c" (s1, s2: rawptr, n: c.size_t) -> rawptr {
	intrinsics.mem_copy(s1, s2, int(n))
	return s1
}

memccpy :: proc "c" (s1, s2: rawptr, ch: c.int, n: c.size_t) -> rawptr {
	d := ([^]u8)(s1)
	s := ([^]u8)(s2)
	v := u8(ch)
	for i := 0; i < int(n); i += 1 {
		d[i] = s[i]
		if s[i] == v {
			return rawptr(&d[i + 1])
		}
	}
	return nil
}

memset :: proc "c" (s: rawptr, ch: c.int, n: c.size_t) -> rawptr {
	p := ([^]u8)(s)
	v := u8(ch)
	for i := 0; i < int(n); i += 1 {
		p[i] = v
	}
	return s
}

strcpy :: proc "c" (s1: [^]byte, s2: cstring) -> [^]byte {
	s := ([^]byte)(s2)
	i := 0
	for {
		s1[i] = s[i]
		if s[i] == 0 {
			break
		}
		i += 1
	}
	return s1
}

strncpy :: proc "c" (s1: [^]byte, s2: cstring, n: c.size_t) -> [^]byte {
	m := int(n)
	s := ([^]byte)(s2)
	i := 0
	for i < m && s[i] != 0 {
		s1[i] = s[i]
		i += 1
	}
	for i < m {
		s1[i] = 0
		i += 1
	}
	return s1
}

stpcpy :: proc "c" (s1: [^]byte, s2: cstring) -> [^]byte {
	s := ([^]byte)(s2)
	i := 0
	for s[i] != 0 {
		s1[i] = s[i]
		i += 1
	}
	s1[i] = 0
	return ([^]byte)(&s1[i])
}

stpncpy :: proc "c" (s1: [^]byte, s2: cstring, n: c.size_t) -> [^]byte {
	m := int(n)
	s := ([^]byte)(s2)
	i := 0
	for i < m && s[i] != 0 {
		s1[i] = s[i]
		i += 1
	}
	end := i
	for i < m {
		s1[i] = 0
		i += 1
	}
	return ([^]byte)(&s1[end])
}

strcat :: proc "c" (s1: [^]byte, s2: cstring) -> [^]byte {
	s := ([^]byte)(s2)
	i := 0
	for s1[i] != 0 {
		i += 1
	}
	j := 0
	for s[j] != 0 {
		s1[i] = s[j]
		i += 1
		j += 1
	}
	s1[i] = 0
	return s1
}

strncat :: proc "c" (s1: [^]byte, s2: cstring, n: c.size_t) -> [^]byte {
	m := int(n)
	s := ([^]byte)(s2)
	i := 0
	for s1[i] != 0 {
		i += 1
	}
	j := 0
	for j < m && s[j] != 0 {
		s1[i] = s[j]
		i += 1
		j += 1
	}
	s1[i] = 0
	return s1
}

memchr :: proc "c" (s: rawptr, ch: c.int, n: c.size_t) -> rawptr {
	p := ([^]u8)(s)
	v := u8(ch)
	for i := 0; i < int(n); i += 1 {
		if p[i] == v {
			return rawptr(&p[i])
		}
	}
	return nil
}

strchr :: proc "c" (s: cstring, ch: c.int) -> [^]byte {
	p := ([^]byte)(s)
	v := u8(ch)
	i := 0
	for {
		if p[i] == v {
			return ([^]byte)(&p[i])
		}
		if p[i] == 0 {
			return nil
		}
		i += 1
	}
}

strrchr :: proc "c" (s: cstring, ch: c.int) -> [^]byte {
	p := ([^]byte)(s)
	v := u8(ch)
	last: [^]byte = nil
	i := 0
	for {
		if p[i] == v {
			last = ([^]byte)(&p[i])
		}
		if p[i] == 0 {
			break
		}
		i += 1
	}
	return last
}

strstr :: proc "c" (haystack, needle: cstring) -> [^]byte {
	n := ([^]byte)(needle)
	if n[0] == 0 {
		return ([^]byte)(haystack)
	}
	h := ([^]byte)(haystack)
	nlen := strlen(needle)
	i := 0
	for h[i] != 0 {
		if h[i] == n[0] && strncmp(cstring(&h[i]), needle, nlen) == 0 {
			return ([^]byte)(&h[i])
		}
		i += 1
	}
	return nil
}

strspn :: proc "c" (s1, s2: cstring) -> c.size_t {
	a := ([^]byte)(s1)
	n := 0
	for a[n] != 0 {
		if strchr(s2, c.int(a[n])) == nil {
			break
		}
		n += 1
	}
	return c.size_t(n)
}

strcspn :: proc "c" (s1, s2: cstring) -> c.size_t {
	a := ([^]byte)(s1)
	n := 0
	for a[n] != 0 {
		if strchr(s2, c.int(a[n])) != nil {
			break
		}
		n += 1
	}
	return c.size_t(n)
}

strpbrk :: proc "c" (s1, s2: cstring) -> [^]byte {
	a := ([^]byte)(s1)
	i := 0
	for a[i] != 0 {
		if strchr(s2, c.int(a[i])) != nil {
			return ([^]byte)(&a[i])
		}
		i += 1
	}
	return nil
}

strdup :: proc "c" (s: cstring) -> [^]byte {
	p := ([^]byte)(malloc(strlen(s) + 1))
	if p == nil {
		return nil
	}
	return strcpy(p, s)
}

strndup :: proc "c" (s: cstring, n: c.size_t) -> [^]byte {
	m := int(strnlen(s, n))
	p := ([^]byte)(malloc(c.size_t(m) + 1))
	if p == nil {
		return nil
	}
	a := ([^]byte)(s)
	for i := 0; i < m; i += 1 {
		p[i] = a[i]
	}
	p[m] = 0
	return p
}

strtok_r :: proc "c" (s: [^]byte, delim: cstring, saveptr: ^cstring) -> [^]byte {
	base := s
	if base == nil {
		if saveptr == nil || saveptr^ == nil {
			return nil
		}
		base = ([^]byte)(saveptr^)
	}
	i := int(strspn(cstring(&base[0]), delim))
	if base[i] == 0 {
		if saveptr != nil {
			saveptr^ = nil
		}
		return nil
	}
	j := i + int(strcspn(cstring(&base[i]), delim))
	if base[j] != 0 {
		base[j] = 0
		if saveptr != nil {
			saveptr^ = cstring(&base[j + 1])
		}
	} else if saveptr != nil {
		saveptr^ = cstring(&base[j])
	}
	return ([^]byte)(&base[i])
}

// The noCRT Linux strerror_r over the C-locale table. Managed Linux keeps
// the libc XSI binding in string.odin so a program's LC_MESSAGES state
// keeps working.
@(private="file")
_strerror_is_fallback :: proc "contextless" (msg: cstring) -> bool {
	m := ([^]byte)(msg)
	want_c := cstring("Unknown error")
	want := ([^]byte)(want_c)
	i := 0
	for want[i] != 0 {
		if m[i] != want[i] {
			return false
		}
		i += 1
	}
	return m[i] == 0
}

when ODIN_NO_CRT {
strerror_r :: proc "c" (errnum: Errno, strerrbuf: [^]byte, buflen: c.size_t) -> Errno {
	// Messages come from the same C-locale table as posix.strerror.
	// POSIX encourages EINVAL with an "unknown error" message when errnum
	// is neither a valid error number nor zero.
	msg := _strerror(errnum)
	need := int(strlen(msg)) + 1
	if int(buflen) < need {
		return .ERANGE
	}
	if strerrbuf == nil {
		return .EFAULT
	}
	src := ([^]byte)(msg)
	for i := 0; i < need; i += 1 {
		strerrbuf[i] = src[i]
	}
	if _strerror_is_fallback(msg) {
		return .EINVAL
	}
	return .NONE
}
}
