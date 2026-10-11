#+build linux
package posix

import "core:c"
import "core:sys/linux"

// The Linux implementation of sysconf(3) through system calls, without libc.
//
// Dynamic values come from the kernel: resource limits for ARG_MAX,
// CHILD_MAX, OPEN_MAX and SIGQUEUE_MAX; the auxiliary vector for PAGESIZE and
// MINSIGSTKSZ; sysinfo for the page counts; the cpu list and the affinity
// mask for the processor counts; CLK_TCK is 100 on every Linux. The rest are
// the constants getconf(1) reports on Linux: names it does not know fail
// with EINVAL, and unsupported options return -1 without touching errno.

// Reads a resource limit. Returns false with errno set on failure.
@(private="file")
_rlimit_cur :: proc "contextless" (kind: linux.RLimit_Kind) -> (uint, bool) {
	lim: linux.RLimit
	if err := linux.getrlimit(kind, &lim); err != .NONE {
		set_errno(Errno(err))
		return 0, false
	}
	return lim.cur, true
}

// A resource limit, or -1 without touching errno when it is infinite.
@(private="file")
_rlimit_or_negone :: proc "contextless" (kind: linux.RLimit_Kind) -> c.long {
	v, ok := _rlimit_cur(kind)
	if !ok {
		return -1
	}
	if v == max(uint) {
		return -1
	}
	return c.long(v)
}

// Reads one native word at the offset. An entry is a pair of words: 8 bytes on 32-bit, 16 on 64-bit.
@(private="file")
_auxv_word :: proc "contextless" (buf: []byte, at: int) -> uint {
	raw: [size_of(uint)]byte
	copy(raw[:], buf[at:at + size_of(uint)])
	return transmute(uint)raw
}

// Reads AT_PAGESZ and AT_MINSIGSTKSZ from the process auxiliary vector.
// Open and read errors set errno. A missing PAGESZ entry is EINVAL; a
// missing MINSIGSTKSZ comes back 0.
@(private="file")
_auxv_vals :: proc "contextless" () -> (pagesz, minsigstksz: uint, ok: bool) {
	fd := open("/proc/self/auxv", {})
	if fd == -1 {
		return 0, 0, false
	}
	defer close(fd)
	buf: [1024]byte
	n := read(fd, ([^]byte)(&buf[0]), len(buf))
	if n <= 0 {
		if n == 0 {
			set_errno(.EINVAL)
		}
		return 0, 0, false
	}
	nn := int(n)
	i := 0
	for i + 2 * size_of(uint) <= nn {
		typ := _auxv_word(buf[:], i)
		val := _auxv_word(buf[:], i + size_of(uint))
		if typ == 0 {
			break
		}
		if typ == 6 {
			pagesz = val
		}
		if typ == 51 {
			minsigstksz = val
		}
		i += 2 * size_of(uint)
	}
	if pagesz == 0 {
		set_errno(.EINVAL)
		return 0, 0, false
	}
	return pagesz, minsigstksz, true
}

// Counts the set bits in the calling thread's affinity mask.
@(private="file")
_cpu_affinity_count :: proc "contextless" () -> int {
	mask: [16]u64
	_, err := linux.sched_getaffinity(0, size_of(mask), rawptr(&mask))
	if err != .NONE {
		set_errno(Errno(err))
		return -1
	}
	count := 0
	for i in 0..<len(mask) {
		w := mask[i]
		for w != 0 {
			count += int(w & 1)
			w >>= 1
		}
	}
	return count
}

// Counts the configured CPUs from the "0-15" style list. Falls back to the
// affinity count when the list is missing, setting errno only then.
@(private="file")
_cpu_possible_count :: proc "contextless" () -> int {
	fd := open("/sys/devices/system/cpu/possible", {})
	if fd == -1 {
		return _cpu_affinity_count()
	}
	defer close(fd)
	buf: [256]byte
	n := read(fd, ([^]byte)(&buf[0]), len(buf))
	if n <= 0 {
		if n == 0 {
			set_errno(.EINVAL)
		}
		return _cpu_affinity_count()
	}
	nn := int(n)
	if buf[nn - 1] != '\n' {
		set_errno(.EINVAL)
		return _cpu_affinity_count()
	}
	count := 0
	i := 0
	for i < nn {
		if buf[i] < '0' || buf[i] > '9' {
			set_errno(.EINVAL)
			return _cpu_affinity_count()
		}
		lo := 0
		for i < nn && buf[i] >= '0' && buf[i] <= '9' {
			lo = lo * 10 + int(buf[i] - '0')
			i += 1
		}
		hi := lo
		if i < nn && buf[i] == '-' {
			i += 1
			if i >= nn || buf[i] < '0' || buf[i] > '9' {
				set_errno(.EINVAL)
				return _cpu_affinity_count()
			}
			hi = 0
			for i < nn && buf[i] >= '0' && buf[i] <= '9' {
				hi = hi * 10 + int(buf[i] - '0')
				i += 1
			}
		}
		if hi < lo {
			set_errno(.EINVAL)
			return _cpu_affinity_count()
		}
		count += hi - lo + 1
		if i < nn && buf[i] == ',' {
			i += 1
			continue
		}
		if i < nn && buf[i] == '\n' {
			break
		}
		set_errno(.EINVAL)
		return _cpu_affinity_count()
	}
	return count
}

/*
Determines the current value of configurable system limit or options.

Returns: value on success, -1 (setting errno) on failure, -1 (no errno) if the variable should be taken from limits

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/sysconf.html ]]
*/
sysconf :: proc "c" (name: SC) -> c.long {
	switch name {
	case ._ARG_MAX:
		v, ok := _rlimit_cur(.STACK)
		if !ok {
			return -1
		}
		// execve(2), Linux bprm_stack_limits: min(3/4 * _STK_LIM,
		// stack / 4), with ARG_MAX (128 KiB) as the floor. Infinity
		// is still bounded by the 8 MiB kernel stack limit.
		return c.long(max(uint(128 * 1024), min(v / 4, uint(6 * 1024 * 1024))))
	case ._CHILD_MAX:
		return _rlimit_or_negone(.NPROC)
	case ._OPEN_MAX:
		return _rlimit_or_negone(.NOFILE)
	case ._SIGQUEUE_MAX:
		return _rlimit_or_negone(.SIGPENDING)
	case ._PAGE_SIZE:
		// _PAGESIZE is the same number and resolves here by value.
		pagesz, _, ok := _auxv_vals()
		if !ok {
			return -1
		}
		return c.long(pagesz)
	// The processor and page counts are Linux-only numbers the shared enum
	// cannot name; they are handled by number in the fallback below.
	case ._CLK_TCK:
		return 100
	// _MINSIGSTKSZ is handled by number in the fallback below.
	case ._HOST_NAME_MAX:
		return 64
	case ._TTY_NAME_MAX:
		return 32
	case ._LOGIN_NAME_MAX:
		return 256
	case ._IOV_MAX:
		// _UIO_MAXIOV is the same number and resolves here by value.
		return 1024
	case ._NGROUPS_MAX:
		return 65536
	// _NZERO is handled by number in the fallback below.
	case ._STREAM_MAX:
		return 16
	case ._AIO_PRIO_DELTA_MAX:
		return 20
	case ._MQ_PRIO_MAX:
		return 32768
	case ._RTSIG_MAX:
		return 32
	case ._SEM_VALUE_MAX:
		return c.long(max(c.int))
	case ._DELAYTIMER_MAX:
		return c.long(max(c.int))
	case ._ATEXIT_MAX:
		return max(c.long)
	// _PASS_MAX is handled by number in the fallback below.
	case ._GETGR_R_SIZE_MAX:
		return 1024
	case ._GETPW_R_SIZE_MAX:
		return 1024
	case ._BC_BASE_MAX:
		return 99
	case ._BC_DIM_MAX:
		return 2048
	case ._BC_SCALE_MAX:
		return 99
	case ._BC_STRING_MAX:
		return 1000
	case ._COLL_WEIGHTS_MAX:
		return 255
	case ._EXPR_NEST_MAX:
		return 32
	case ._LINE_MAX:
		return 2048
	case ._RE_DUP_MAX:
		return 32767
	case ._2_VERSION:
		return 200809
	case ._2_C_BIND:
		return 200809
	case ._2_C_DEV:
		return 200809
	case ._2_CHAR_TERM:
		return 200809
	case ._2_FORT_RUN:
		return 200809
	case ._2_LOCALEDEF:
		return 200809
	case ._2_SW_DEV:
		return 200809
	case ._THREADS:
		return 200809
	case ._THREAD_SAFE_FUNCTIONS:
		return 200809
	case ._THREAD_DESTRUCTOR_ITERATIONS:
		return 4
	case ._THREAD_KEYS_MAX:
		return 1024
	case ._THREAD_STACK_MIN:
		return 16384
	case ._THREAD_ATTR_STACKADDR:
		return 200809
	case ._THREAD_ATTR_STACKSIZE:
		return 200809
	case ._THREAD_PRIORITY_SCHEDULING:
		return 200809
	case ._THREAD_PRIO_INHERIT:
		return 200809
	case ._THREAD_PRIO_PROTECT:
		return 200809
	case ._THREAD_PROCESS_SHARED:
		return 200809
	case ._VERSION:
		return 200809
	case ._XOPEN_VERSION:
		return 700
	// _XOPEN_XCU_VERSION is handled by number in the fallback below.
	case ._XOPEN_UNIX:
		return 1
	case ._XOPEN_ENH_I18N:
		return 1
	case ._XOPEN_SHM:
		return 1
	// _XOPEN_XPG2/3/4 are handled by number in the fallback below.
	// _XBS5_LP64_OFF64 is handled by number in the fallback below.
	// _XOPEN_LEGACY is handled by number in the fallback below.
	case ._XOPEN_REALTIME:
		return 1
	case ._XOPEN_REALTIME_THREADS:
		return 1
	case ._REGEXP:
		return 1
	case ._SHELL:
		return 1
	case ._V6_LP64_OFF64:
		return 1
	// _V7_LP64_OFF64 is handled by number in the fallback below.
	case ._JOB_CONTROL:
		return 1
	case ._SAVED_IDS:
		return 1
	case ._PRIORITY_SCHEDULING,
	     ._TIMERS,
	     ._PRIORITIZED_IO,
	     ._SYNCHRONIZED_IO,
	     ._FSYNC,
	     ._MAPPED_FILES,
	     ._MEMLOCK,
	     ._MEMLOCK_RANGE,
	     ._MEMORY_PROTECTION,
	     ._MESSAGE_PASSING,
	     ._REALTIME_SIGNALS,
	     ._SEMAPHORES,
	     ._SHARED_MEMORY_OBJECTS,
	     ._ADVISORY_INFO,
	     ._BARRIERS,
	     ._CLOCK_SELECTION,
	     ._CPUTIME,
	     ._THREAD_CPUTIME,
	     ._MONOTONIC_CLOCK,
	     ._READER_WRITER_LOCKS,
	     ._SPIN_LOCKS,
	     ._SPAWN,
	     ._TIMEOUTS,
	     ._IPV6,
	     ._RAW_SOCKETS:
		return 200809
	case ._ASYNCHRONOUS_IO,
	     ._AIO_LISTIO_MAX,
	     ._AIO_MAX,
	     ._MQ_OPEN_MAX,
	     ._SEM_NSEMS_MAX,
	     ._TIMER_MAX,
	     ._2_FORT_DEV,
	     ._2_PBS,
	     ._2_PBS_ACCOUNTING,
	     ._2_PBS_LOCATE,
	     ._2_PBS_MESSAGE,
	     ._2_PBS_TRACK,
	     ._2_PBS_CHECKPOINT,
	     ._SYMLOOP_MAX,
	     ._V6_ILP32_OFF32,
	     ._V6_ILP32_OFFBIG,
	     ._V6_LPBIG_OFFBIG,
	     ._TRACE,
	     ._TRACE_EVENT_FILTER,
	     ._TRACE_INHERIT,
	     ._TRACE_LOG,
	     ._TRACE_EVENT_NAME_MAX,
	     ._TRACE_NAME_MAX,
	     ._TRACE_SYS_MAX,
	     ._TRACE_USER_EVENT_MAX,
	     ._SPORADIC_SERVER,
	     ._THREAD_SPORADIC_SERVER,
	     ._TYPED_MEMORY_OBJECTS,
	     ._2_UPE,
	     ._TZNAME_MAX,
	     ._THREAD_THREADS_MAX,
	     ._XOPEN_STREAMS,
	     ._XOPEN_CRYPT:
		return -1
	case ._SS_REPL_MAX:
		set_errno(.EINVAL)
		return -1
	case:
		// The shared enum cannot name Linux-only numbers, so they are
		// matched here by their Linux values.
		switch int(name) {
		case 83: // _SC_NPROCESSORS_CONF
			if n := _cpu_possible_count(); n >= 0 {
				return c.long(n)
			}
			return -1
		case 84: // _SC_NPROCESSORS_ONLN
			if n := _cpu_affinity_count(); n >= 0 {
				return c.long(n)
			}
			return -1
		case 85, 86: // _SC_PHYS_PAGES, _SC_AVPHYS_PAGES
			pagesz, _, ok := _auxv_vals()
			if !ok {
				return -1
			}
			si: linux.Sys_Info
			if err := linux.sysinfo(&si); err != .NONE {
				set_errno(Errno(err))
				return -1
			}
			if int(name) == 85 {
				return c.long(si.totalram * uint(si.mem_unit) / pagesz)
			}
			return c.long(si.freeram * uint(si.mem_unit) / pagesz)
		case 88: // _SC_PASS_MAX
			return 8192
		case 90: // _SC_XOPEN_XCU_VERSION
			return 4
		case 98, 99, 100: // _SC_XOPEN_XPG2, _SC_XOPEN_XPG3, _SC_XOPEN_XPG4
			return 1
		case 109: // _SC_NZERO
			return 20
		case 127: // _SC_XBS5_LP64_OFF64
			return 1
		case 129: // _SC_XOPEN_LEGACY
			return 1
		case 239: // _SC_V7_LP64_OFF64
			return 1
		case 249: // _SC_MINSIGSTKSZ
			_, minsig, ok := _auxv_vals()
			if !ok || minsig == 0 {
				return -1
			}
			return c.long(minsig)
		case 125, 126, 128, // _SC_XBS5_ILP32_OFF32, _SC_XBS5_ILP32_OFFBIG, _SC_XBS5_LPBIG_OFFBIG
		     174, // _SC_STREAMS
		     237, 238, 240, // _SC_V7_ILP32_OFF32, _SC_V7_ILP32_OFFBIG, _SC_V7_LPBIG_OFFBIG
		     250: // _SC_SIGSTKSZ
			return -1
		case:
			set_errno(.EINVAL)
			return -1
		}
	}
}
