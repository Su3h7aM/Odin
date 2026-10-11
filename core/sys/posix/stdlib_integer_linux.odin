#+build linux
package posix

import "core:c"

_ :: c

// The Linux noCRT implementation of the `stdlib.h` integer conversion
// procedures, without libc. Whitespace, signs, base prefixes, and digit
// values follow the C locale, which is the native profile default. The
// managed C profile keeps the libc aliases in stdlib_libc.odin, where
// conversions share the C locale with linked code.
when ODIN_NO_CRT {

// C-locale whitespace for conversions: space and \t through \r.
@(private="file")
_strto_is_space :: proc "contextless" (c: u8) -> bool {
	return c == ' ' || (c >= '\t' && c <= '\r')
}

// Digit value in any supported base, or not a digit.
@(private="file")
_strto_digit :: proc "contextless" (c: u8) -> (u32, bool) {
	switch {
	case c >= '0' && c <= '9':
		return u32(c - '0'), true
	case c >= 'a' && c <= 'z':
		return u32(c - 'a') + 10, true
	case c >= 'A' && c <= 'Z':
		return u32(c - 'A') + 10, true
	}
	return 0, false
}

// Base validity per Linux strtol(3): 0 selects binary, octal, hex, or
// decimal by prefix; anything else must lie in 2..36.
@(private="file")
_strto_base_ok :: proc "contextless" (base: c.int) -> bool {
	return base == 0 || (base >= 2 && base <= 36)
}

// Stores the end pointer: the first character past the conversion, or the
// original string when nothing converted.
@(private="file")
_strto_end :: proc "contextless" (nptr: cstring, endptr: ^[^]c.char, k: int) {
	if endptr == nil {
		return
	}
	if nptr == nil {
		endptr^ = nil
		return
	}
	endptr^ = cast([^]c.char)rawptr(&([^]u8)(nptr)[k])
}

// Runs the conversion: whitespace, sign, base prefix, and digits. The
// magnitude accumulates against limit, so callers clamp by width without
// overflowing; digits past the limit still advance the end position.
// end counts from the start of nptr; any reports whether anything
// converted.
@(private="file")
_strto_core :: proc "contextless" (p: [^]u8, base: c.int, limit: u64, is_signed: bool) -> (mag: u64, neg: bool, end: int, any: bool, overflow: bool) {
	if p == nil {
		return 0, false, 0, false, false
	}
	i := 0
	for _strto_is_space(p[i]) {
		i += 1
	}
	if p[i] == '+' {
		i += 1
	} else if p[i] == '-' {
		neg = true
		i += 1
	}
	b: u32
	if base == 0 {
		// A 0x or 0b prefix only selects hex or binary when a matching
		// digit follows; otherwise the leading zero parses as octal.
		if p[i] == '0' {
			if p[i+1] == 'x' || p[i+1] == 'X' {
				if d, ok := _strto_digit(p[i+2]); ok && d < 16 {
					i += 2
					b = 16
				} else {
					b = 8
				}
			} else if p[i+1] == 'b' || p[i+1] == 'B' {
				if d, ok := _strto_digit(p[i+2]); ok && d < 2 {
					i += 2
					b = 2
				} else {
					b = 8
				}
			} else {
				b = 8
			}
		} else {
			b = 10
		}
	} else {
		// Callers admit only 2..36.
		b = u32(base)
		if b == 16 && p[i] == '0' && (p[i+1] == 'x' || p[i+1] == 'X') {
			if d, ok := _strto_digit(p[i+2]); ok && d < 16 {
				i += 2
			}
		} else if b == 2 && p[i] == '0' && (p[i+1] == 'b' || p[i+1] == 'B') {
			if d, ok := _strto_digit(p[i+2]); ok && d < 2 {
				i += 2
			}
		}
	}
	lim := limit
	if is_signed && neg {
		// Callers pass at most max(i64); one more cannot overflow.
		lim += 1
	}
	cutoff := lim / u64(b)
	cutlim := lim % u64(b)
	start := i
	for {
		d, ok := _strto_digit(p[i])
		if !ok || d >= b {
			break
		}
		if mag > cutoff || (mag == cutoff && u64(d) > cutlim) {
			overflow = true
		} else {
			mag = mag*u64(b) + u64(d)
		}
		i += 1
	}
	return mag, neg, i, i > start, overflow
}

/*
Converts the initial part of a string to a long, in the given base.

Returns: the converted value, clamped to LONG_MAX or LONG_MIN with errno
set to ERANGE past the range, or 0 with errno set to EINVAL for a base
outside 0..36 excluding 1. When nothing converts, endptr takes the
original string and errno is untouched, as on success.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/strtol.html ]]
*/
strtol :: proc "c" (nptr: cstring, endptr: ^[^]c.char, base: c.int) -> c.long {
	if !_strto_base_ok(base) {
		set_errno(.EINVAL)
		_strto_end(nptr, endptr, 0)
		return 0
	}
	mag, neg, end, any, overflow := _strto_core(([^]u8)(nptr), base, u64(max(c.long)), true)
	if !any {
		_strto_end(nptr, endptr, 0)
		return 0
	}
	_strto_end(nptr, endptr, end)
	if overflow {
		set_errno(.ERANGE)
		if neg {
			return min(c.long)
		}
		return max(c.long)
	}
	if neg {
		// The magnitude is at most one past the maximum here.
		if mag == u64(max(c.long)) + 1 {
			return min(c.long)
		}
		return -c.long(mag)
	}
	return c.long(mag)
}

/*
Converts the initial part of a string to a long long, in the given base,
with the same contract as strtol but the long long range.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/strtoll.html ]]
*/
strtoll :: proc "c" (nptr: cstring, endptr: ^[^]c.char, base: c.int) -> c.longlong {
	if !_strto_base_ok(base) {
		set_errno(.EINVAL)
		_strto_end(nptr, endptr, 0)
		return 0
	}
	mag, neg, end, any, overflow := _strto_core(([^]u8)(nptr), base, u64(max(c.longlong)), true)
	if !any {
		_strto_end(nptr, endptr, 0)
		return 0
	}
	_strto_end(nptr, endptr, end)
	if overflow {
		set_errno(.ERANGE)
		if neg {
			return min(c.longlong)
		}
		return max(c.longlong)
	}
	if neg {
		if mag == u64(max(c.longlong)) + 1 {
			return min(c.longlong)
		}
		return -c.longlong(mag)
	}
	return c.longlong(mag)
}

/*
Converts the initial part of a string to an unsigned long, in the given
base. A sign still applies: a leading minus negates the magnitude modulo
the width, so "-1" converts without error.

Returns: the converted value, or ULONG_MAX with errno set to ERANGE past
the range. The endptr and errno contract matches strtol.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/strtoul.html ]]
*/
strtoul :: proc "c" (nptr: cstring, endptr: ^[^]c.char, base: c.int) -> c.ulong {
	if !_strto_base_ok(base) {
		set_errno(.EINVAL)
		_strto_end(nptr, endptr, 0)
		return 0
	}
	mag, neg, end, any, overflow := _strto_core(([^]u8)(nptr), base, max(u64), false)
	if !any {
		_strto_end(nptr, endptr, 0)
		return 0
	}
	_strto_end(nptr, endptr, end)
	if overflow {
		set_errno(.ERANGE)
		return max(c.ulong)
	}
	if neg {
		return c.ulong(0 - mag)
	}
	return c.ulong(mag)
}

/*
Converts the initial part of a string to an unsigned long long, in the
given base, with the same contract as strtoul but the unsigned long long
range.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/strtoull.html ]]
*/
strtoull :: proc "c" (nptr: cstring, endptr: ^[^]c.char, base: c.int) -> c.ulonglong {
	if !_strto_base_ok(base) {
		set_errno(.EINVAL)
		_strto_end(nptr, endptr, 0)
		return 0
	}
	mag, neg, end, any, overflow := _strto_core(([^]u8)(nptr), base, max(u64), false)
	if !any {
		_strto_end(nptr, endptr, 0)
		return 0
	}
	_strto_end(nptr, endptr, end)
	if overflow {
		set_errno(.ERANGE)
		return max(c.ulonglong)
	}
	if neg {
		return c.ulonglong(0 - mag)
	}
	return c.ulonglong(mag)
}

/*
Converts a decimal string to an int, saturating past the int range. Like
the library, no error is reported through errno; a prior errno value is
left exactly as found.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/atoi.html ]]
*/
atoi :: proc "c" (nptr: cstring) -> c.int {
	saved := get_errno()
	defer set_errno(saved)
	v := strtol(nptr, nil, 10)
	if v > c.long(max(c.int)) {
		return max(c.int)
	}
	if v < c.long(min(c.int)) {
		return min(c.int)
	}
	return c.int(v)
}

/*
Converts a decimal string to a long. Like the library, no error is
reported through errno; a prior errno value is left exactly as found.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/atol.html ]]
*/
atol :: proc "c" (nptr: cstring) -> c.long {
	saved := get_errno()
	defer set_errno(saved)
	return strtol(nptr, nil, 10)
}

/*
Converts a decimal string to a long long. Like the library, no error is
reported through errno; a prior errno value is left exactly as found.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/atoll.html ]]
*/
atoll :: proc "c" (nptr: cstring) -> c.longlong {
	saved := get_errno()
	defer set_errno(saved)
	return strtoll(nptr, nil, 10)
}

}
