#+build linux
package posix

import "core:c"
import "core:sys/linux"

// The Linux implementation of the `sys/utsname.h` procedure through a system
// call, without libc.
//
// A failure is reported the same way as for the libc procedure, with `errno`.

// `utsname` matches the kernel layout field for field.
#assert(size_of(utsname) == size_of(linux.UTS_Name))
#assert(offset_of(utsname, sysname)      == offset_of(linux.UTS_Name, sysname))
#assert(offset_of(utsname, nodename)     == offset_of(linux.UTS_Name, nodename))
#assert(offset_of(utsname, release)      == offset_of(linux.UTS_Name, release))
#assert(offset_of(utsname, version)      == offset_of(linux.UTS_Name, version))
#assert(offset_of(utsname, machine)      == offset_of(linux.UTS_Name, machine))
#assert(offset_of(utsname, __domainname) == offset_of(linux.UTS_Name, domainname))

/*
Stores information identifying the current system in the given structure.

Returns: non-negative on success, -1 (setting errno) on failure

NOTE: have a look at `core:sys/info` for similar/better system information.

Example:
	uname: posix.utsname
	posix.uname(&uname)
	fmt.printfln("%#v", uname)

Possible Output:
	utsname{
		sysname = Darwin,
		nodename = Laytans-MacBook-Pro.local,
		release = 23.5.0,
		version = Darwin Kernel Version 23.5.0: Wed May  1 20:16:51 PDT 2024; root:xnu-11331.111.3~1/RELEASE_ARM64_T8103,
		machine = arm64,
	}

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/uname.html ]]
*/
uname :: proc "c" (uname: ^utsname) -> c.int {
	if err := linux.uname(cast(^linux.UTS_Name)uname); err != .NONE {
		set_errno(Errno(err))
		return -1
	}
	return 0
}
