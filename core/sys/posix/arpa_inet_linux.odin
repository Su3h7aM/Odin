#+build linux
package posix

// The Linux implementation of the address conversion procedures of
// `arpa/inet.h` without libc. These are pure userland formatters and parsers
// over the address types; only failures set `errno`, as with libc.

@(private="file", thread_local)
NTOA_BUF: [16]byte

// Appends the decimal form of a byte at out[at:], returning the new offset.
@(private="file")
_put_decimal :: proc "contextless" (out: []u8, at: int, v: u8) -> int {
	if v >= 100 {
		out[at] = u8('0') + v / 100
		out[at+1] = u8('0') + (v / 10) % 10
		out[at+2] = u8('0') + v % 10
		return at + 3
	} else if v >= 10 {
		out[at] = u8('0') + v / 10
		out[at+1] = u8('0') + v % 10
		return at + 2
	}
	out[at] = u8('0') + v
	return at + 1
}

// Appends the shortest hexadecimal form of a 16-bit group, no leading zeros.
@(private="file")
_put_hex :: proc "contextless" (out: []u8, at: int, v: u16) -> int {
	idx := at
	started := false
	for k in 0..<4 {
		shift := uint(12 - 4*k)
		d := u8((v >> shift) & 0xF)
		if d != 0 || started || shift == 0 {
			started = true
			out[idx] = (u8('0') + d) if d < 10 else (u8('a') + d - 10)
			idx += 1
		}
	}
	return idx
}

// Appends a string, returning the new offset.
@(private="file")
_put_text :: proc "contextless" (out: []u8, at: int, s: string) -> int {
	for i in 0..<len(s) {
		out[at+i] = s[i]
	}
	return at + len(s)
}

// Formats eight IPv6 groups with longest-run "::" compression. The first
// longest run wins; a single zero group stays expanded. Compatible
// (::a.b.c.d) and mapped (::ffff:a.b.c.d) tails use dotted decimal, as the
// conventional formatters do. Returns the text length without the terminator.
@(private="file")
_put_ipv6 :: proc "contextless" (out: []u8, groups: [8]u16) -> int {
	best_at, best_len := -1, 0
	at, ln := -1, 0
	for i in 0..<8 {
		if groups[i] == 0 {
			if ln == 0 {
				at = i
			}
			ln += 1
			if ln > best_len {
				best_at, best_len = at, ln
			}
		} else {
			ln = 0
		}
	}

	n := 0
	if best_at == 0 && (best_len == 6 || (best_len == 5 && groups[5] == 0xffff)) {
		n = _put_text(out, n, "::")
		if best_len == 5 {
			n = _put_text(out, n, "ffff:")
		}
		tail := [4]u8{u8(groups[6] >> 8), u8(groups[6]), u8(groups[7] >> 8), u8(groups[7])}
		n = _put_decimal(out, n, tail[0])
		for i in 1..<4 {
			out[n] = '.'
			n = _put_decimal(out, n+1, tail[i])
		}
		return n
	}

	first := true
	i := 0
	for i < 8 {
		if i == best_at && best_len > 1 {
			out[n] = ':'
			out[n+1] = ':'
			n += 2
			i += best_len
			first = true
			continue
		}
		if !first {
			out[n] = ':'
			n += 1
		}
		n = _put_hex(out, n, groups[i])
		first = false
		i += 1
	}
	return n
}

// Parses exactly ddd.ddd.ddd.ddd over s[at:end], each part one to three
// decimal digits of value at most 255. Leading zeros are decimal, as with
// libc.
@(private="file")
_parse_ipv4 :: proc "contextless" (s: [^]u8, at, end: int, out: ^[4]u8) -> bool {
	pos := at
	for part in 0..<4 {
		if pos >= end {
			return false
		}
		digits, v := 0, 0
		for pos < end && s[pos] >= '0' && s[pos] <= '9' {
			if digits == 3 {
				return false
			}
			v = v*10 + int(s[pos]-'0')
			digits += 1
			pos += 1
		}
		if digits == 0 || v > 255 {
			return false
		}
		out[part] = u8(v)
		if part < 3 {
			if pos >= end || s[pos] != '.' {
				return false
			}
			pos += 1
		}
	}
	return pos == end
}

// Parses one to four hexadecimal digits into a 16-bit group.
@(private="file")
_parse_hex16 :: proc "contextless" (s: [^]u8, at, end: int) -> (u16, bool) {
	if end - at < 1 || end - at > 4 {
		return 0, false
	}
	v := 0
	for i in at..<end {
		c := s[i]
		d: int
		if c >= '0' && c <= '9' {
			d = int(c-'0')
		} else if c >= 'a' && c <= 'f' {
			d = int(c-'a') + 10
		} else if c >= 'A' && c <= 'F' {
			d = int(c-'A') + 10
		} else {
			return 0, false
		}
		v = v*16 + d
	}
	return u16(v), true
}

// Parses colon-separated groups of s[at:end] as pairs of bytes into
// out[fill:], returning the group count. The last span may instead hold
// dotted-decimal IPv4, which counts as two groups, unless allow_v4 forbids
// it. Any empty span or bad digit fails. Writes stay inside out.
@(private="file")
_parse_groups :: proc "contextless" (s: [^]u8, at, end: int, out: ^[16]u8, fill: int, allow_v4: bool) -> (count: int, ok: bool) {
	if at == end {
		return 0, true
	}
	start := at
	for {
		stop := start
		for stop < end && s[stop] != ':' && s[stop] != '.' {
			stop += 1
		}
		if stop < end && s[stop] == '.' {
			if !allow_v4 {
				return 0, false
			}
			dot := stop
			for dot < end && s[dot] != ':' {
				dot += 1
			}
			if dot != end {
				return 0, false
			}
			if fill + 2*count + 3 >= 16 {
				return 0, false
			}
			v4: [4]u8
			if !_parse_ipv4(s, start, end, &v4) {
				return 0, false
			}
			for i in 0..<4 {
				out[fill+2*count+i] = v4[i]
			}
			return count + 2, true
		}
		if fill + 2*count + 1 >= 16 {
			return 0, false
		}
		g, good := _parse_hex16(s, start, stop)
		if !good {
			return 0, false
		}
		out[fill+2*count] = u8(g >> 8)
		out[fill+2*count+1] = u8(g)
		count += 1
		if stop == end {
			return count, true
		}
		// A single colon separates; "::" and edges are handled by the caller.
		if stop+1 >= end || s[stop+1] == ':' {
			return 0, false
		}
		start = stop + 1
	}
}

// Parses preferred, compressed, and embedded-IPv4 forms. Only one "::" may
// occur, and with "::" the explicit groups must leave room for at least one
// compressed group.
@(private="file")
_parse_ipv6 :: proc "contextless" (s: [^]u8, n: int, out: ^[16]u8) -> bool {
	if n == 0 {
		return false
	}
	// Locate "::" and reject a second one.
	dc := -1
	for i in 0..<n-1 {
		if s[i] == ':' && s[i+1] == ':' {
			dc = i
			break
		}
	}
	if dc != -1 {
		for i in dc+2..<n-1 {
			if s[i] == ':' && s[i+1] == ':' {
				return false
			}
		}
	}
	raw: [16]u8
	if dc == -1 {
		count, ok := _parse_groups(s, 0, n, &raw, 0, true)
		if !ok || count != 8 {
			return false
		}
	} else {
		head, ok := _parse_groups(s, 0, dc, &raw, 0, false)
		if !ok {
			return false
		}
		tmp: [16]u8
		tail, tail_ok := _parse_groups(s, dc+2, n, &tmp, 0, true)
		if !tail_ok {
			return false
		}
		if head + tail >= 8 {
			return false
		}
		for i in 0..<2*tail {
			raw[16-2*tail+i] = tmp[i]
		}
	}
	for i in 0..<16 {
		out[i] = raw[i]
	}
	return true
}

// Converts the Internet host address given in network byte order to a string
// in IPv4 dotted-decimal notation. The string lives in per-thread storage
// overwritten by later calls on the same thread.
//
// [[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/inet_ntoa.html ]]
inet_ntoa :: proc "c" (addr: in_addr) -> cstring {
	v := u32(addr.s_addr)
	b := [4]u8{u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)}
	n := _put_decimal(NTOA_BUF[:], 0, b[0])
	for i in 1..<4 {
		NTOA_BUF[n] = '.'
		n = _put_decimal(NTOA_BUF[:], n+1, b[i])
	}
	NTOA_BUF[n] = 0
	return cstring(&NTOA_BUF[0])
}

// Converts a numeric address into a text string. The caller provides at least
// INET_ADDRSTRLEN bytes for IPv4 and INET6_ADDRSTRLEN for IPv6. `dst` is only
// written on success.
//
// Returns: `dst` on success, nil (setting errno) on failure
//
// [[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/inet_ntop.html ]]
inet_ntop :: proc "c" (af: AF, src: rawptr, dst: [^]byte, size: socklen_t) -> cstring {
	if src == nil || dst == nil {
		set_errno(.EFAULT)
		return nil
	}
	if af != .INET && af != .INET6 {
		set_errno(.EAFNOSUPPORT)
		return nil
	}
	// Format into a stack buffer; `dst` is only touched on success.
	buf: [INET6_ADDRSTRLEN]byte
	n := 0
	if af == .INET {
		bytes := ([^]u8)(src)
		n = _put_decimal(buf[:], n, bytes[0])
		for i in 1..<4 {
			buf[n] = '.'
			n = _put_decimal(buf[:], n+1, bytes[i])
		}
	} else {
		bytes := ([^]u8)(src)
		groups: [8]u16
		for i in 0..<8 {
			groups[i] = u16(bytes[2*i]) << 8 | u16(bytes[2*i+1])
		}
		n = _put_ipv6(buf[:], groups)
	}
	if n+1 > int(size) {
		set_errno(.ENOSPC)
		return nil
	}
	for i in 0..<n {
		dst[i] = buf[i]
	}
	dst[n] = 0
	return cstring(dst)
}

// Converts an address in standard text presentation form into numeric binary
// form in network byte order. Only dotted-decimal IPv4 is accepted for
// AF_INET; AF_INET6 does not recognize bare IPv4. `dst` is only written on
// success.
//
// Returns: 1 on success, 0 for an invalid address, -1 (setting errno) for an
// invalid family
//
// [[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/inet_pton.html ]]
inet_pton :: proc "c" (af: AF, src: cstring, dst: rawptr) -> pton_result {
	if af != .INET && af != .INET6 {
		set_errno(.EAFNOSUPPORT)
		return .AFNOSUPPORT
	}
	if src == nil || dst == nil {
		return .INVALID
	}
	s := ([^]u8)(src)
	n := 0
	for s[n] != 0 {
		n += 1
	}
	if af == .INET {
		var4: [4]u8
		if !_parse_ipv4(s, 0, n, &var4) {
			return .INVALID
		}
		d := ([^]u8)(dst)
		for i in 0..<4 {
			d[i] = var4[i]
		}
		return .SUCCESS
	}
	var6: [16]u8
	if !_parse_ipv6(s, n, &var6) {
		return .INVALID
	}
	d := ([^]u8)(dst)
	for i in 0..<16 {
		d[i] = var6[i]
	}
	return .SUCCESS
}
