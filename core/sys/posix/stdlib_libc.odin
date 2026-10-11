#+build linux, windows, darwin, netbsd, openbsd, freebsd
package posix

import "base:intrinsics"

import "core:c"
import "core:c/libc"

when ODIN_OS == .Windows {
	foreign import lib "system:libucrt.lib"
} else when ODIN_OS == .Darwin {
	foreign import lib "system:System"
} else {
	foreign import lib "system:c"
}

_ :: c
_ :: lib

// stdlib.h - standard library definitions

atof          :: libc.atof
strtod        :: libc.strtod
strtof        :: libc.strtof

// Linux noCRT takes the owned integer conversions in
// stdlib_integer_linux.odin. Every other profile keeps the libc aliases,
// where conversions share the C locale with linked code.
when ODIN_OS != .Linux || !ODIN_NO_CRT {
	atoi     :: libc.atoi
	atol     :: libc.atol
	atoll    :: libc.atoll
	strtol   :: libc.strtol
	strtoll  :: libc.strtoll
	strtoul  :: libc.strtoul
	strtoull :: libc.strtoull
}

// Linux noCRT takes the owned generator in stdlib_linux.odin. Every other
// profile keeps the libc aliases, where C code shares the generator state.
when ODIN_OS != .Linux || !ODIN_NO_CRT {
	rand     :: libc.rand
	srand    :: libc.srand
}

// Linux noCRT takes the owned heap implementations in stdlib_linux.odin.
// Every other profile keeps the libc aliases, so linked C code can free
// what these procedures return and vice versa.
when ODIN_OS != .Linux || !ODIN_NO_CRT {
	calloc    :: libc.calloc
	malloc    :: libc.malloc
	realloc   :: libc.realloc
}

abort         :: libc.abort
atexit        :: libc.atexit
at_quick_exit :: libc.at_quick_exit
exit          :: libc.exit
_Exit         :: libc._Exit
when ODIN_OS != .Linux || !ODIN_NO_CRT {
	getenv :: libc.getenv
}
quick_exit    :: libc.quick_exit
system        :: libc.system

// Linux uses the owned search and sort in stdlib_linux.odin on both
// profiles; these need no libc state. Every other OS keeps the aliases.
when ODIN_OS != .Linux {
	bsearch  :: libc.bsearch
	qsort    :: libc.qsort
}

mblen         :: libc.mblen
mbtowc        :: libc.mbtowc
wctomb        :: libc.wctomb

mbstowcs      :: libc.mbstowcs
wcstombs      :: libc.wcstombs

// Linux noCRT frees through the owned heap in stdlib_linux.odin.
free :: #force_inline proc "c" (ptr: $T) where intrinsics.type_is_pointer(T) || intrinsics.type_is_multi_pointer(T) || T == cstring {
	when ODIN_OS == .Linux && ODIN_NO_CRT {
		_native_free(rawptr(ptr))
	} else {
		libc.free(rawptr(ptr))
	}
}

foreign lib {

	/*
	Uses the string argument to set environment variable values. 

	Returns: 0 on success, non-zero (setting errno) on failure

	Example:
		if posix.putenv("HOME=/usr/home") != 0 {
			fmt.panicf("putenv failure: %v", posix.strerror(posix.errno()))
		}

	[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/putenv.html ]]
	*/
	when ODIN_OS != .Linux || !ODIN_NO_CRT {
		@(link_name=LPUTENV)
		putenv :: proc(string: cstring) -> c.int ---
	}
}

EXIT_FAILURE :: libc.EXIT_FAILURE
EXIT_SUCCESS :: libc.EXIT_SUCCESS

RAND_MAX   :: libc.RAND_MAX
MB_CUR_MAX :: libc.MB_CUR_MAX

div_t   :: libc.div_t
ldiv_t  :: libc.ldiv_t
lldiv_t :: libc.lldiv_t

when ODIN_OS == .Windows {
	@(private) LPUTENV :: "_putenv"
} else when ODIN_OS == .NetBSD {
	@(private) LPUTENV :: "__putenv50"
} else {
	@(private) LPUTENV :: "putenv"
}
