#+build linux, darwin, netbsd, openbsd, freebsd
package posix

import "core:c"

_ :: c

when ODIN_OS == .Darwin {
	foreign import lib "system:System"
} else {
	foreign import lib "system:c"
}

// string.h - string operations

// NOTE: most of the symbols in this header are not useful in Odin and have been left out.
// The locale-sensitive strcoll, strxfrm and strerror_l, and the global-state
// strtok, stay with the C library; see `core:c/libc` for the explicit bindings.

foreign lib {
	/*
	Map the signal number to an implementation-defined string.

	Returns: a string that may be invalidated by subsequent calls

	[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/strsignal.html ]]
	*/
	strsignal :: proc(sig: Signal) -> cstring ---
}

// The remaining procedures below have owned Linux implementations in
// string_linux.odin. Every other target keeps the libc bindings here.
when ODIN_OS != .Linux {
	foreign lib {
		/*
		Compute the length of the string, not including the terminating null byte.

		[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/strlen.html ]]
		*/
		strlen :: proc(s: cstring) -> c.size_t ---

		/*
		Compute the length of the string, but at most maxlen bytes.

		[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/strlen.html ]]
		*/
		strnlen :: proc(s: cstring, maxlen: c.size_t) -> c.size_t ---

		/*
		Compare two memory areas byte by byte as unsigned characters.

		Returns: negative, zero, or positive when s1 compares smaller than, equal to, or greater than s2

		[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/memcmp.html ]]
		*/
		memcmp :: proc(s1, s2: rawptr, n: c.size_t) -> c.int ---

		/*
		Compare two strings byte by byte as unsigned characters.

		Returns: negative, zero, or positive when s1 compares smaller than, equal to, or greater than s2

		[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/strcmp.html ]]
		*/
		strcmp :: proc(s1, s2: cstring) -> c.int ---

		/*
		Compare at most n bytes of two strings as unsigned characters.

		Returns: negative, zero, or positive when s1 compares smaller than, equal to, or greater than s2

		[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/strncmp.html ]]
		*/
		strncmp :: proc(s1, s2: cstring, n: c.size_t) -> c.int ---

		/*
		Copy n bytes between non-overlapping areas.

		Returns: s1

		[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/memcpy.html ]]
		*/
		memcpy :: proc(s1, s2: rawptr, n: c.size_t) -> rawptr ---

		/*
		Copy n bytes between possibly overlapping areas.

		Returns: s1

		[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/memmove.html ]]
		*/
		memmove :: proc(s1, s2: rawptr, n: c.size_t) -> rawptr ---

		/*
		Copy bytes until the byte c is found (included) or n bytes are copied.

		Returns: a pointer just past the copied c in s1, or nil when c was not found

		[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/memccpy.html ]]
		*/
		memccpy :: proc(s1, s2: rawptr, ch: c.int, n: c.size_t) -> rawptr ---

		/*
		Fill n bytes with the byte c.

		Returns: s

		[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/memset.html ]]
		*/
		memset :: proc(s: rawptr, ch: c.int, n: c.size_t) -> rawptr ---

		/*
		Copy a string including its terminating null byte.

		Returns: s1. The areas must not overlap.

		[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/strcpy.html ]]
		*/
		strcpy :: proc(s1: [^]byte, s2: cstring) -> [^]byte ---

		/*
		Copy at most n bytes, padding the remainder with null bytes.

		Returns: s1. The result is null-terminated only when the source fits.

		[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/strncpy.html ]]
		*/
		strncpy :: proc(s1: [^]byte, s2: cstring, n: c.size_t) -> [^]byte ---

		/*
		Copy a string including its terminating null byte.

		Returns: a pointer to the terminating null byte in s1.

		[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/stpcpy.html ]]
		*/
		stpcpy :: proc(s1: [^]byte, s2: cstring) -> [^]byte ---

		/*
		Copy at most n bytes without padding, stopping at the source terminator.

		Returns: a pointer to the terminating null byte, or s1+n when the source is longer.

		[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/stpncpy.html ]]
		*/
		stpncpy :: proc(s1: [^]byte, s2: cstring, n: c.size_t) -> [^]byte ---

		/*
		Append a string including its terminating null byte after the string in s1.

		Returns: s1.

		[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/strcat.html ]]
		*/
		strcat :: proc(s1: [^]byte, s2: cstring) -> [^]byte ---

		/*
		Append at most n non-null bytes and always null-terminate.

		Returns: s1.

		[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/strncat.html ]]
		*/
		strncat :: proc(s1: [^]byte, s2: cstring, n: c.size_t) -> [^]byte ---

		/*
		Find the first occurrence of the byte c in the first n bytes.

		Returns: a pointer to it, or nil when absent

		[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/memchr.html ]]
		*/
		memchr :: proc(s: rawptr, ch: c.int, n: c.size_t) -> rawptr ---

		/*
		Find the first occurrence of the byte c, including the terminator.

		Returns: a pointer to it, or nil when absent

		[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/strchr.html ]]
		*/
		strchr :: proc(s: cstring, ch: c.int) -> [^]byte ---

		/*
		Find the last occurrence of the byte c, including the terminator.

		Returns: a pointer to it, or nil when absent

		[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/strrchr.html ]]
		*/
		strrchr :: proc(s: cstring, ch: c.int) -> [^]byte ---

		/*
		Find the first occurrence of the string needle. An empty needle matches.

		Returns: a pointer to it, or nil when absent

		[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/strstr.html ]]
		*/
		strstr :: proc(haystack, needle: cstring) -> [^]byte ---

		/*
		Measure the leading bytes of s1 that are all in s2.

		[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/strspn.html ]]
		*/
		strspn :: proc(s1, s2: cstring) -> c.size_t ---

		/*
		Measure the leading bytes of s1 that are all outside s2.

		[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/strcspn.html ]]
		*/
		strcspn :: proc(s1, s2: cstring) -> c.size_t ---

		/*
		Find the first byte of s1 that is in s2.

		Returns: a pointer to it, or nil when absent

		[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/strpbrk.html ]]
		*/
		strpbrk :: proc(s1, s2: cstring) -> [^]byte ---

		/*
		Duplicate a string with posix.malloc. Free the result with posix.free.

		Returns: the copy, or nil on allocation failure

		[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/strdup.html ]]
		*/
		strdup :: proc(s: cstring) -> [^]byte ---

		/*
		Duplicate at most n bytes with posix.malloc, always null-terminated.
		Free the result with posix.free.

		Returns: the copy, or nil on allocation failure

		[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/strdup.html ]]
		*/
		strndup :: proc(s: cstring, n: c.size_t) -> [^]byte ---

		/*
		Split s into tokens separated by bytes of delim, keeping the resume
		state in saveptr instead of hidden global state. s must point to
		mutable memory; it is overwritten with null bytes. A nil s resumes
		from saveptr; a nil saveptr only yields the first token.

		Returns: the next token, or nil when exhausted

		[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/strtok.html ]]
		*/
		strtok_r :: proc(s: [^]byte, delim: cstring, saveptr: ^cstring) -> [^]byte ---
	}
}

// Linux noCRT takes the owned strerror_r in string_linux.odin, which reports
// C-locale messages. Every other profile keeps the libc XSI binding, so a
// managed program's LC_MESSAGES state keeps working.
when ODIN_OS != .Linux || !ODIN_NO_CRT {
	foreign lib {
		/*
		Map the error number to a locale-dependent error message string and put it in the buffer.

		Returns: .NONE on success, .ERANGE when the buffer is too small,
		.EINVAL when errnum is neither a valid error number nor zero

		[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/strerror_r.html ]]
		*/
		strerror_r :: proc(errnum: Errno, strerrbuf: [^]byte, buflen: c.size_t) -> Errno ---
	}
}
