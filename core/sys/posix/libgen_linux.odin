#+build linux
package posix

// The Linux implementation of the `dirname` procedure of `libgen.h` without
// libc, following POSIX and the SUS table in the `libgen` documentation:
//
//	"usr" -> ".", "usr/" -> ".", "" -> ".", "/" -> "/", "//" -> "/",
//	"///" -> "/", "/usr/" -> "/", "/usr/lib" -> "/usr",
//	"//usr//lib//" -> "//usr", ".." -> "."
//
// A failure is reported the same way as for the libc procedure, with `errno`
// (only EINVAL for a nil path here).

// Static answer for paths without a slash. Writable storage, since the C
// contract permits the result to be modified; in practice it is only read.
@(private="file")
DOT: [2]u8 = {'.', 0}

/*
Takes a string that contains a pathname, and returns a string that is a
pathname of the parent directory of that file.

NOTE: may modify input, so don't give it string literals. A nil path or a
path without a slash returns static "." storage instead.

Returns: a string that might be a modification of the input string or static
storage overwritten by subsequent calls

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/dirname.html ]]
*/
dirname :: proc "c" (path: cstring) -> cstring {
	if path == nil {
		set_errno(.EINVAL)
		return cstring(&DOT[0])
	}
	p := ([^]byte)(path)

	// Length of the NUL-terminated input.
	n := 0
	for p[n] != 0 {
		n += 1
	}
	if n == 0 {
		return cstring(&DOT[0])
	}

	// Strip trailing slashes, keeping one character so "/" stays "/".
	for n > 1 && p[n-1] == '/' {
		n -= 1
	}
	p[n] = 0

	// Find the last remaining slash.
	end := -1
	for i := n - 1; i >= 0; i -= 1 {
		if p[i] == '/' {
			end = i
			break
		}
	}
	if end == -1 {
		// No slash: the parent is ".", and the input stays as it was.
		return cstring(&DOT[0])
	}

	// Strip trailing slashes of the directory part, keeping one character.
	for end > 0 && p[end-1] == '/' {
		end -= 1
	}
	if end == 0 {
		p[1] = 0
	} else {
		p[end] = 0
	}
	return cstring(&p[0])
}

// Static answer for empty input. Writable storage, since the C contract
// permits the result to be modified; in practice it is only read.
@(private="file")
BASE_DOT: [2]u8 = {'.', 0}

/*
Takes the pathname pointed to by path and returns a pointer to the final
component of the pathname, deleting any trailing '/' characters. This is the
POSIX variant: "/usr/" answers "usr" and "/" answers "/".

NOTE: may modify input, so don't give it string literals. A nil or empty path
answers static "." storage instead.

Returns: a string that might be a modification of the input string or static
storage overwritten by subsequent calls

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/basename.html ]]
*/
basename :: proc "c" (path: cstring) -> cstring {
	if path == nil {
		set_errno(.EINVAL)
		return cstring(&BASE_DOT[0])
	}
	p := ([^]byte)(path)

	n := 0
	for p[n] != 0 {
		n += 1
	}
	if n == 0 {
		return cstring(&BASE_DOT[0])
	}

	// Trailing slashes are not part of the name; keep one character so "/"
	// stays "/".
	for n > 1 && p[n-1] == '/' {
		n -= 1
	}
	p[n] = 0

	last := -1
	for i := n - 1; i >= 0; i -= 1 {
		if p[i] == '/' {
			last = i
			break
		}
	}
	if last == -1 {
		return cstring(&p[0])
	}
	if last+1 == n {
		return cstring(&p[0])
	}
	return cstring(&p[last+1])
}
