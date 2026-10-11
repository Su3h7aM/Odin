#+build linux amd64, linux arm64, linux riscv64
package posix

import "core:c"
import "core:sys/linux"

// The Linux implementation of the resource limit procedures of `sys/resource.h`
// through system calls, without libc.
//
// `prlimit` with pid 0 operates on the calling process, so one system call
// covers both procedures on every architecture.
//
// A failure is reported the same way as for the libc procedures, with `errno`.

// `rlimit` is the same two words as the kernel's `RLimit` on 64 bit Linux.
#assert(size_of(rlimit) == size_of(linux.RLimit))
#assert(offset_of(rlimit, rlim_cur) == offset_of(linux.RLimit, cur))
#assert(offset_of(rlimit, rlim_max) == offset_of(linux.RLimit, max))

// `Resource` is cast to the kernel's `RLimit_Kind`, which needs them to agree.
#assert(int(Resource.CORE)   == int(linux.RLimit_Kind.CORE))
#assert(int(Resource.CPU)    == int(linux.RLimit_Kind.CPU))
#assert(int(Resource.DATA)   == int(linux.RLimit_Kind.DATA))
#assert(int(Resource.FSIZE)  == int(linux.RLimit_Kind.FSIZE))
#assert(int(Resource.NOFILE) == int(linux.RLimit_Kind.NOFILE))
#assert(int(Resource.STACK)  == int(linux.RLimit_Kind.STACK))
#assert(int(Resource.AS)     == int(linux.RLimit_Kind.AS))

getrlimit :: proc "c" (resource: Resource, rlp: ^rlimit) -> result {
	return errno_result(linux.prlimit64(0, linux.RLimit_Kind(resource), nil, cast(^linux.RLimit)rlp))
}

setrlimit :: proc "c" (resource: Resource, rlp: ^rlimit) -> result {
	return errno_result(linux.prlimit64(0, linux.RLimit_Kind(resource), cast(^linux.RLimit)rlp, nil))
}

// `Which_Prio` and `Which_Usage` carry the kernel's numbers. The wrapper
// around getpriority already converts the kernel's 20-minus-nice form, so
// these report plain nice values with errno set only on failure.
#assert(int(Which_Prio.PROCESS) == int(linux.Priority_Which.PROCESS))
#assert(int(Which_Prio.PGRP)    == int(linux.Priority_Which.PGRP))
#assert(int(Which_Prio.USER)    == int(linux.Priority_Which.USER))
#assert(int(Which_Usage.SELF)     == int(linux.RUsage_Who.SELF))
#assert(int(Which_Usage.CHILDREN) == int(linux.RUsage_Who.CHILDREN))

// `rusage` matches the kernel's `RUsage` field for field.
#assert(size_of(rusage) == size_of(linux.RUsage))
#assert(offset_of(rusage, ru_utime)   == offset_of(linux.RUsage, utime))
#assert(offset_of(rusage, ru_stime)   == offset_of(linux.RUsage, stime))
#assert(offset_of(rusage, ru_maxrss)  == offset_of(linux.RUsage, maxrss_word))
#assert(offset_of(rusage, ru_nivcsw)  == offset_of(linux.RUsage, nivcsw_word))

/*
Returns: -1 (setting errno) on failure, the value otherwise

Example:
	pid := posix.getpid()
	posix.set_errno(.NONE)
	prio := posix.getpriority(.PROCESS, pid)
	if err := posix.errno(); prio == -1 && err != .NONE {
		// Handle error...
	}

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/getpriority.html ]]
*/
getpriority :: proc "c" (which: Which_Prio, who: id_t) -> c.int {
	prio, err := linux.getpriority(linux.Priority_Which(which), i32(who))
	if err != .NONE {
		set_errno(Errno(err))
		return -1
	}
	return c.int(prio)
}

/*
Sets the nice value of the process, process group or user given.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/getpriority.html ]]
*/
setpriority :: proc "c" (which: Which_Prio, who: id_t, value: c.int) -> result {
	return errno_result(linux.setpriority(linux.Priority_Which(which), i32(who), i32(value)))
}

/*
Get resource usage.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/getrusage.html ]]
*/
getrusage :: proc "c" (who: Which_Usage, rusage: ^rusage) -> result {
	return errno_result(linux.getrusage(linux.RUsage_Who(who), cast(^linux.RUsage)rusage))
}
