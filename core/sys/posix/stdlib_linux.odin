#+build linux
package posix

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:sys/linux"

_ :: runtime

// The Linux implementation of the pseudo-terminal procedures of `stdlib.h`
// through system calls, without libc.
//
// A failure is reported the same way as for the libc procedures, with `errno`.
//
// The slave terminals live on devpts, which gives each one the owner and the
// 0620 mode of its opener when it is allocated, so `grantpt` has nothing to
// change.

// The master is a character device that allocates a new terminal pair for each
// open; `/dev/ptmx` is the devpts multiplexer.
@(private="file")
PTMX :: "/dev/ptmx"

// The slave names are `/dev/pts/` followed by the terminal number, which has at
// most ten decimal digits.
@(private="file")
PTS_PREFIX :: "/dev/pts/"

@(private="file", thread_local)
ptsname_buf: [len(PTS_PREFIX) + 10 + 1]byte

// The terminal number of the slave that the master `fd` belongs to, or the
// error number. A descriptor that is open but is not a master gives ENOTTY from
// the kernel, which POSIX reports as EINVAL for `grantpt` and `unlockpt`.
@(private="file")
pty_number :: proc "contextless" (fd: FD) -> (n: c.uint, err: linux.Errno) {
	_, err = linux.ioctl(linux.Fd(fd), linux.TIOCGPTN, uintptr(&n))
	return
}

/*
Opens an unused pseudo-terminal master device, returning a file descriptor that can be used to refer to it.

Returns: -1 (setting errno) on failure, an open file descriptor otherwise

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/posix_openpt.html ]]
*/
posix_openpt :: proc "c" (oflag: O_Flags) -> FD {
	fd, err := linux.open(PTMX, transmute(linux.Open_Flags)oflag)
	if err == .ENOSPC {
		// POSIX reports running out of terminals as EAGAIN.
		err = .EAGAIN
	}
	return errno_fd(fd, err)
}

/*
Changes the mode and ownership of the slave pseudo-terminal device associated with its master pseudo-terminal counterpart.

On Linux the kernel sets the owner and mode when the terminal is allocated, so this only checks that
`fildes` is a master pseudo-terminal.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/grantpt.html ]]
*/
grantpt :: proc "c" (fildes: FD) -> result {
	_, err := pty_number(fildes)
	if err == .ENOTTY {
		err = .EINVAL
	}
	return errno_result(err)
}

/*
Unlocks the slave pseudo-terminal device associated with the master to which fildes refers.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/unlockpt.html ]]
*/
unlockpt :: proc "c" (fildes: FD) -> result {
	unlock: c.int
	_, err := linux.ioctl(linux.Fd(fildes), linux.TIOCSPTLCK, uintptr(&unlock))
	if err == .ENOTTY {
		err = .EINVAL
	}
	return errno_result(err)
}

/*
Returns the name of the slave pseudo-terminal device associated with a master pseudo-terminal device.

Returns: nil (setting errno) on failure, the name on success, which may be invalidated on subsequent calls
from the same thread. The name is kept in storage of the calling thread, so threads do not overwrite each other's.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/ptsname.html ]]
*/
ptsname :: proc "c" (fildes: FD) -> cstring {
	n, err := pty_number(fildes)
	if err != .NONE {
		set_errno(Errno(err))
		return nil
	}

	digits: [10]byte
	at := len(digits)
	for {
		at -= 1
		digits[at] = byte('0' + n % 10)
		n /= 10
		if n == 0 {
			break
		}
	}

	length := copy(ptsname_buf[:], PTS_PREFIX)
	length += copy(ptsname_buf[length:], digits[at:])
	ptsname_buf[length] = 0
	return cstring(&ptsname_buf[0])
}

// The Linux implementation of the temporary file and directory procedures of
// `stdlib.h` through system calls, without libc.
//
// A failure is reported the same way as for the libc procedures, with `errno`.
// The retry and template-restoration policy below is compatible with musl, not
// imposed by POSIX.

@(private="file")
MKTEMP_ATTEMPTS :: 100

@(private="file")
MKTEMP_ALPHABET :: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

// Largest multiple of the alphabet length below 256. Drawn bytes at or above
// it are discarded so every letter is equally likely.
@(private="file")
MKTEMP_LIMIT :: (256 / len(MKTEMP_ALPHABET)) * len(MKTEMP_ALPHABET)

// Replaces the six bytes at template[at] with random alphanumeric characters.
// Entropy errors fail explicitly; there is no userspace fallback generator.
@(private="file")
_mktemp_randomize :: proc "contextless" (template: [^]byte, at: int) -> linux.Errno {
	filled := 0
	alphabet := MKTEMP_ALPHABET
	for filled < 6 {
		rand: [8]u8
		got := 0
		for got < len(rand) {
			n, err := linux.getrandom(rand[got:], {})
			if err == .EINTR {
				continue
			}
			if err != .NONE {
				return err
			}
			// getrandom with no flags does not return short counts without an
			// error; guard against no progress anyway.
			if n <= 0 {
				return .EIO
			}
			got += n
		}
		for b in rand {
			if filled == 6 {
				break
			}
			if b < MKTEMP_LIMIT {
				template[at+filled] = alphabet[int(b) % len(alphabet)]
				filled += 1
			}
		}
	}
	return .NONE
}

// Returns the offset of the six trailing Xs. The template is NUL-terminated;
// anything else, including a nil template, is not a valid template.
@(private="file")
_mktemp_offset :: proc "contextless" (template: [^]byte) -> (at: int, ok: bool) {
	if template == nil {
		return 0, false
	}
	n := 0
	for template[n] != 0 {
		n += 1
	}
	if n < 6 {
		return 0, false
	}
	for i in 0..<6 {
		if template[n-6+i] != 'X' {
			return 0, false
		}
	}
	return n - 6, true
}

// Restores the Xs after a failure, as musl does.
@(private="file")
_mktemp_restore :: proc "contextless" (template: [^]byte, at: int) {
	for i in 0..<6 {
		template[at+i] = 'X'
	}
}

/*
Creates a directory with a unique name derived from template, with permissions
0700 subject to the process umask, and returns the modified template.
The last six bytes of template must be XXXXXX; otherwise it is left unchanged
and nil is returned with errno EINVAL.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/mkdtemp.html ]]
*/
mkdtemp :: proc "c" (template: [^]byte) -> cstring {
	at, ok := _mktemp_offset(template)
	if !ok {
		set_errno(.EINVAL)
		return nil
	}
	for _ in 0..<MKTEMP_ATTEMPTS {
		if rerr := _mktemp_randomize(template, at); rerr != .NONE {
			_mktemp_restore(template, at)
			set_errno(Errno(rerr))
			return nil
		}
		if merr := linux.mkdir(cstring(&template[0]), {.IRUSR, .IWUSR, .IXUSR}); merr == .NONE {
			return cstring(&template[0])
		} else if merr != .EEXIST {
			_mktemp_restore(template, at)
			set_errno(Errno(merr))
			return nil
		}
	}
	_mktemp_restore(template, at)
	set_errno(.EEXIST)
	return nil
}

/*
Creates a regular file with a unique name derived from template, with
permissions 0600 subject to the process umask, and returns a file descriptor
open for reading and writing. The file is created with O_CREAT and O_EXCL, so
the caller is the process that created it. The last six bytes of template must
be XXXXXX; otherwise it is left unchanged and -1 is returned with errno EINVAL.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/mkstemp.html ]]
*/
mkstemp :: proc "c" (template: cstring) -> FD {
	chars := ([^]byte)(template)
	at, ok := _mktemp_offset(chars)
	if !ok {
		set_errno(.EINVAL)
		return -1
	}
	for _ in 0..<MKTEMP_ATTEMPTS {
		if rerr := _mktemp_randomize(chars, at); rerr != .NONE {
			_mktemp_restore(chars, at)
			set_errno(Errno(rerr))
			return -1
		}
		fd, oerr := linux.open(template, {.RDWR, .CREAT, .EXCL}, {.IRUSR, .IWUSR})
		if oerr == .NONE {
			return FD(fd)
		} else if oerr != .EEXIST {
			_mktemp_restore(chars, at)
			set_errno(Errno(oerr))
			return -1
		}
	}
	_mktemp_restore(chars, at)
	set_errno(.EEXIST)
	return -1
}

// The Linux noCRT implementation of the `stdlib.h` memory management and
// small integer arithmetic procedures, over the owned runtime heap
// allocator (which itself allocates from the kernel backend), without libc.
//
// The managed C profile keeps the libc aliases in stdlib_libc.odin, so an
// allocation from these procedures can be freed by linked C code and vice
// versa. The owned procedures below exist only where there is no libc to
// interoperate with. Nothing here interposes on libc symbols and nothing
// replaces the allocator of a managed program: the explicit C bindings in
// core:c/libc and the thread runtime are untouched.
when ODIN_NO_CRT {

// Linux malloc(3) hands out memory suitably aligned for any built-in type,
// which 16 bytes satisfy on 64-bit Linux and 8 on 32-bit. The runtime heap
// bins are only 8-aligned, so every allocation carries a fixed header
// holding the bin address and the user size, and the user pointer is
// aligned up past it.
@(private="file")
_NATIVE_MALLOC_ALIGNMENT :: 2 * align_of(uintptr)

@(private="file")
_NATIVE_MALLOC_HEADER_SIZE :: 16

// Largest user request this layer accepts: PTRDIFF_MAX minus the header
// and alignment slack, so the header arithmetic below cannot overflow.
// Larger requests fail with ENOMEM, as do requests the OS cannot back.
@(private="file")
_NATIVE_MALLOC_MAX :: max(int) - _NATIVE_MALLOC_HEADER_SIZE - _NATIVE_MALLOC_ALIGNMENT

// Maps a user request to the heap request and the size recorded in the
// header. A zero request still yields a unique allocation that free accepts.
@(private="file")
_native_malloc_total :: proc "contextless" (size: c.size_t) -> (total: int, stored: c.size_t, ok: bool) {
	if size > c.size_t(_NATIVE_MALLOC_MAX) {
		return 0, 0, false
	}
	stored = size
	if stored == 0 {
		stored = 1
	}
	total = int(stored) + _NATIVE_MALLOC_HEADER_SIZE + _NATIVE_MALLOC_ALIGNMENT - 1
	return total, stored, true
}

// Carves the aligned user pointer out of a bin, recording the bin address
// and user size in the 16 bytes before it.
@(private="file")
_native_malloc_pack :: proc "contextless" (bin: rawptr, size: c.size_t) -> rawptr {
	user := rawptr((uintptr(bin) + uintptr(_NATIVE_MALLOC_HEADER_SIZE + _NATIVE_MALLOC_ALIGNMENT - 1)) & ~uintptr(_NATIVE_MALLOC_ALIGNMENT - 1))
	header := cast([^]uintptr)rawptr(uintptr(user) - uintptr(_NATIVE_MALLOC_HEADER_SIZE))
	header[0] = uintptr(bin)
	header[1] = uintptr(size)
	return user
}

// Recovers the bin address and user size recorded by _native_malloc_pack.
@(private="file")
_native_malloc_unpack :: proc "contextless" (user: rawptr) -> (bin: rawptr, size: c.size_t) {
	header := cast([^]uintptr)rawptr(uintptr(user) - uintptr(_NATIVE_MALLOC_HEADER_SIZE))
	bin = rawptr(header[0])
	size = c.size_t(header[1])
	return bin, size
}

@(private="file")
_native_alloc :: proc "contextless" (size: c.size_t, zero: bool) -> rawptr {
	total, stored, ok := _native_malloc_total(size)
	if !ok {
		set_errno(.ENOMEM)
		return nil
	}
	bin := runtime.heap_alloc(total, zero)
	if bin == nil {
		// The operating system could not back the request.
		set_errno(.ENOMEM)
		return nil
	}
	return _native_malloc_pack(bin, stored)
}

/*
Allocates uninitialized space for an object of the given size, suitably
aligned for any fundamental type.

Returns: nil (setting errno to ENOMEM) when size exceeds PTRDIFF_MAX or the
operating system cannot back the request, a pointer to the space otherwise.
A zero size still returns a unique pointer that free accepts. Errno is left
untouched on success.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/malloc.html ]]
*/
malloc :: proc "c" (size: c.size_t) -> rawptr {
	return _native_alloc(size, false)
}

/*
Allocates zero-initialized space for an array of nmemb elements of the given
size, suitably aligned for any fundamental type.

Returns: nil (setting errno to ENOMEM) when the product overflows, exceeds
PTRDIFF_MAX, or the operating system cannot back the request, a pointer to
the zeroed space otherwise. A zero product still returns a unique pointer
that free accepts. Errno is left untouched on success.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/calloc.html ]]
*/
calloc :: proc "c" (nmemb, size: c.size_t) -> rawptr {
	if size != 0 && nmemb > c.size_t(_NATIVE_MALLOC_MAX) / size {
		set_errno(.ENOMEM)
		return nil
	}
	return _native_alloc(nmemb * size, true)
}

/*
Changes the size of the allocation ptr points to, preserving its contents up
to the smaller of the old and new sizes, and returns the (possibly moved)
pointer. The expanded tail is left uninitialized, as with malloc.

Returns: nil when ptr is nil and size is zero; otherwise a nil ptr behaves
like malloc(size), and a zero size frees ptr and returns nil. A failure
returns nil with the old allocation intact; an oversized request or a request
the operating system cannot back sets errno to ENOMEM. Errno is left
untouched on success.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/realloc.html ]]
*/
realloc :: proc "c" (ptr: rawptr, size: c.size_t) -> rawptr {
	if ptr == nil {
		return malloc(size)
	}
	if size == 0 {
		free(ptr)
		return nil
	}
	total, stored, ok := _native_malloc_total(size)
	if !ok {
		// The old allocation is left intact.
		set_errno(.ENOMEM)
		return nil
	}
	bin, old_stored := _native_malloc_unpack(ptr)
	old_total, _, _ := _native_malloc_total(old_stored)
	new_bin := runtime.heap_resize(bin, old_total, total, false)
	if new_bin == nil {
		// The old allocation is left intact.
		set_errno(.ENOMEM)
		return nil
	}
	return _native_malloc_pack(new_bin, stored)
}

/*
Frees the allocation ptr points to. A nil pointer is inert. The pointer must
be exactly what malloc, calloc, or realloc handed out on this profile, freed
exactly once; anything else is a programming error the heap allocator may
trap on, as with the C library.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/free.html ]]
*/
// Owned backing for the package-level free in stdlib_libc.odin, which
// dispatches here on Linux noCRT. Kept under a distinct name because a
// global when-block may not redeclare the builtin-shadowed free.
@(private)
_native_free :: proc "contextless" (ptr: rawptr) {
	if ptr == nil {
		return
	}
	bin, _ := _native_malloc_unpack(ptr)
	runtime.heap_free(bin)
}

}

// The arithmetic, search, and sort procedures below need no libc state, so
// Linux uses these owned implementations on both profiles. Only the
// allocation family, the generator, and the locale-sharing conversions
// above stay behind ODIN_NO_CRT.

// The small integer arithmetic below is pure computation with the C operand
// widths and wrap-around, so it matches the library bit for bit, including
// a trapping divide by zero and a wrapping absolute value of the minimum.

/*
Returns the absolute value of j.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/abs.html ]]
*/
abs :: proc "c" (j: c.int) -> c.int {
	if j < 0 {
		return -j
	}
	return j
}

/*
Returns the absolute value of j.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/labs.html ]]
*/
labs :: proc "c" (j: c.long) -> c.long {
	if j < 0 {
		return -j
	}
	return j
}

/*
Returns the absolute value of j.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/llabs.html ]]
*/
llabs :: proc "c" (j: c.longlong) -> c.longlong {
	if j < 0 {
		return -j
	}
	return j
}

/*
Divides numer by denom, returning the quotient and remainder.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/div.html ]]
*/
div :: proc "c" (numer, denom: c.int) -> div_t {
	return div_t{numer / denom, numer % denom}
}

/*
Divides numer by denom, returning the quotient and remainder.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/ldiv.html ]]
*/
ldiv :: proc "c" (numer, denom: c.long) -> ldiv_t {
	return ldiv_t{numer / denom, numer % denom}
}

/*
Divides numer by denom, returning the quotient and remainder.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/lldiv.html ]]
*/
lldiv :: proc "c" (numer, denom: c.longlong) -> lldiv_t {
	return lldiv_t{numer / denom, numer % denom}
}

// Address of element i in an array at base with the given element width.
@(private="file")
_native_at :: proc "contextless" (base: rawptr, i, size: c.size_t) -> rawptr {
	return rawptr(uintptr(base) + uintptr(i) * uintptr(size))
}

// Exchanges two elements byte by byte, so no element buffer is needed.
@(private="file")
_native_swap :: proc "contextless" (a, b: rawptr, size: c.size_t) {
	pa := cast([^]u8)a
	pb := cast([^]u8)b
	for i in 0..<size {
		pa[i], pb[i] = pb[i], pa[i]
	}
}

// Restores the heap property below root in a count-element heap, driving
// the larger child up. Pointers handed to compar address the array itself.
@(private="file")
_native_sift :: proc "contextless" (base: rawptr, root, count, size: c.size_t, compar: proc "c" (lhs, rhs: rawptr) -> c.int) {
	r := root
	for {
		child := r * 2 + 1
		if child >= count {
			return
		}
		if child + 1 < count && compar(_native_at(base, child, size), _native_at(base, child + 1, size)) < 0 {
			child += 1
		}
		if compar(_native_at(base, r, size), _native_at(base, child, size)) < 0 {
			_native_swap(_native_at(base, r, size), _native_at(base, child, size), size)
			r = child
		} else {
			return
		}
	}
}

/*
Sorts an array of nmemb elements of the given width in place, ordering
pairs as compar reports. The sort is not stable: equal elements may come
out in any order. Uses heapsort, so the stack stays flat and no memory is
allocated whatever the input.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/qsort.html ]]
*/
qsort :: proc "c" (base: rawptr, nmemb, size: c.size_t, compar: proc "c" (lhs, rhs: rawptr) -> c.int) {
	if nmemb < 2 || size == 0 {
		return
	}
	i := nmemb / 2
	for i > 0 {
		i -= 1
		_native_sift(base, i, nmemb, size, compar)
	}
	end := nmemb - 1
	for end > 0 {
		_native_swap(base, _native_at(base, end, size), size)
		_native_sift(base, 0, end, size, compar)
		end -= 1
	}
}

/*
Searches a sorted array of nmemb elements of the given width for an element
compar reports as equal to key, using binary search.

Returns: nil when no element matches, a pointer into the array otherwise.
Which match comes back when several are equal is unspecified.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/bsearch.html ]]
*/
bsearch :: proc "c" (key, base: rawptr, nmemb, size: c.size_t, compar: proc "c" (lhs, rhs: rawptr) -> c.int) -> rawptr {
	lo: c.size_t
	hi := nmemb
	for lo < hi {
		mid := lo + (hi - lo) / 2
		el := _native_at(base, mid, size)
		c := compar(key, el)
		if c == 0 {
			return el
		}
		if c < 0 {
			hi = mid
		} else {
			lo = mid + 1
		}
	}
	return nil
}

// The generator keeps shared C state with linked code, so it stays behind
// ODIN_NO_CRT with the allocation family.
when ODIN_NO_CRT {

// Shared generator state. Starts at 1, matching the srand(1) behavior
// rand has before any srand call. Updated with atomics so threads share
// one sequence without tearing the state.
@(private="file")
_rand_state: u64 = 1

// 64-bit linear generator; the multiplier is Knuth's MMIX constant. The
// high 31 bits fill RAND_MAX exactly.
@(private="file")
_RAND_MULT :: 6364136223846793005

/*
Returns the next pseudo-random number in [0, RAND_MAX]. The sequence is
shared by all threads and deterministic for a given srand seed.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/rand.html ]]
*/
rand :: proc "c" () -> c.int {
	for {
		old := intrinsics.atomic_load(&_rand_state)
		new := old * _RAND_MULT + 1
		if _, ok := intrinsics.atomic_compare_exchange_strong(&_rand_state, old, new); ok {
			return c.int(new >> 33)
		}
	}
}

/*
Reseeds the shared pseudo-random sequence; rand behaves as if srand(1) ran
before any call here.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/srand.html ]]
*/
srand :: proc "c" (seed: c.uint) {
	intrinsics.atomic_store(&_rand_state, u64(seed))
}

}
