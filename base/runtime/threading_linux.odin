#+private
package runtime

import "base:intrinsics"

when ODIN_ARCH == .amd64 {
	SYS_gettid :: uintptr(186)
} else when ODIN_ARCH == .arm32 {
	SYS_gettid :: uintptr(224)
} else when ODIN_ARCH == .arm64 {
	SYS_gettid :: uintptr(178)
} else when ODIN_ARCH == .i386 {
	SYS_gettid :: uintptr(224)
} else when ODIN_ARCH == .riscv64 {
	SYS_gettid :: uintptr(178)
} else {
	#panic("Syscall numbers related to threading are missing for this Linux architecture.")
}

_get_current_thread_id :: proc "contextless" () -> int {
	return int(intrinsics.syscall(SYS_gettid))
}

// Managed-thread exit cleanup for threads the Odin runtime did not create.
//
// On managed (CRT-linked) Linux builds, foreign threads — pthreads created
// directly, threads born in loader-phase C constructors, the initial thread
// when it exits without returning from main — never pass through
// core/thread's entry path, so its deferred cleanup never runs for them.
// This section arms a single process-wide pthread key whose destructor
// replays the same two steps the managed entry path performs: destroy this
// thread's default temporary allocator state, then run the thread-local
// cleaner list (which already covers the per-thread heap, the core/os
// temporary arenas, and the nbio event loop). Registration is lazy — the key
// is created and bound on first thread-local use (heap acquire, default temp
// use, cleaner registration) — so callbacks from pre-main C constructors are
// covered without depending on any Odin runtime initialization. Only libc,
// atomics, and raw syscalls are used on the arm path. Thread-pointer, errno,
// and signal ownership are unchanged.
when ODIN_OS == .Linux && !ODIN_NO_CRT {
	foreign import libc "system:c"

	// pthread_key_t on Linux (glibc and musl agree: unsigned int). Declared
	// locally because base/runtime cannot import core (so plain u32 stands
	// in for C's unsigned int); the canonical Odin declaration lives in
	// core/sys/posix/pthread.odin.
	Managed_PThread_Key :: distinct u32
	// pthread_once_t on Linux is an int, zero-initialized (PTHREAD_ONCE_INIT).
	Managed_Once :: distinct i32

	// Cancellation states on Linux (verified against the system pthread.h:
	// PTHREAD_CANCEL_ENABLE is 0, PTHREAD_CANCEL_DISABLE is 1).
	_MANAGED_CANCEL_ENABLE  :: i32(0)
	_MANAGED_CANCEL_DISABLE :: i32(1)

	@(default_calling_convention="c")
	foreign libc {
		@(link_name="pthread_key_create")
		_managed_key_create :: proc(key: ^Managed_PThread_Key, destructor: proc "c" (value: rawptr)) -> i32 ---
		@(link_name="pthread_setspecific")
		_managed_key_set :: proc(key: Managed_PThread_Key, value: rawptr) -> i32 ---
		@(link_name="pthread_once")
		_managed_once :: proc(once: ^Managed_Once, init: proc "c" ()) -> i32 ---
		@(link_name="pthread_setcancelstate")
		_managed_cancel_set :: proc(state: i32, oldstate: ^i32) -> i32 ---
	}

	// Once control for the process-wide cleanup key. pthread_once (rather
	// than a flag plus spin) is the primitive that stays correct when the
	// creating thread is cancelled: POSIX refunds the once control, so the
	// next arming thread retries creation instead of spinning forever.
	@(private)
	_managed_cleanup_once: Managed_Once
	@(private)
	_managed_cleanup_key: Managed_PThread_Key
	// Result of the once init routine, read by every arming thread after
	// pthread_once returns (which synchronizes with the init routine).
	@(private)
	_managed_key_create_code: i32
	// Per-thread arm flag. Thread-local storage starts zeroed, so a new
	// thread always arms even after an older thread with the same stack
	// addresses exited. Cleared when the destructor starts so that thread-
	// local use later in the same exit (for example by another library's
	// destructor) rebinds into a later destructor round instead of leaking.
	@(thread_local, private)
	_managed_cleanup_armed: bool

	// Failure of the cleanup arm path. The pthread bindings above report
	// C's errno-style int; the kind selects the diagnostic text and the
	// code preserves the actual pthread error number for the diagnostic.
	@(private)
	Managed_Cleanup_Kind :: enum {
		None,
		Create_Key,
		Bind_Thread,
		Protect_Cleanup,
		Init_Once,
	}
	@(private)
	Managed_Cleanup_Error :: struct {
		kind: Managed_Cleanup_Kind,
		code: i32,
	}

	// Once init routine: creates the cleanup key exactly once per process.
	// Runs with cancellation disabled by the caller, so it always runs to
	// completion; the pthread_once refund behavior additionally covers the
	// case where the routine itself could not finish.
	_managed_cleanup_key_init :: proc "c" () {
		_managed_key_create_code = _managed_key_create(&_managed_cleanup_key, _managed_thread_cleanup_destructor)
	}

	// Destructor for the cleanup key. Runs on the exiting thread for every
	// thread with a bound value: foreign threads, cancelled threads, and
	// managed threads whose entry-path defers already ran (those find every
	// cleaner bit set and do no second run). Binds a valid isolated
	// context: the heap allocator and the default temporary allocator both
	// work, so arbitrary existing cleaners can allocate. Temporary use
	// regrows the just-destroyed arena from the heap; the regrown state is
	// picked up by a later destructor round when use re-arms the thread.
	@(private)
	_managed_thread_cleanup_destructor :: proc "c" (value: rawptr) {
		_ = value
		context = default_context()

		// Disable cancellation across the whole teardown, failing fast with
		// the pthread error number (see the guard): the thread is exiting
		// and cleanup must not be interrupted.
		old_cancel := _managed_cancel_guard()

		// Disarm: glibc already associates NULL before calling, but other
		// libcs need the explicit store, and libc repeats destructor
		// rounds only while a destructor-bearing value remains set. A
		// failed disarm is safe by construction — cleanup below runs each
		// cleaner at most once per thread, so a repeat invocation only
		// covers state created since.
		_ = _managed_key_set(_managed_cleanup_key, nil)
		_managed_cleanup_armed = false

		// Same order as the managed thread entry deferred cleanup: the
		// default temporary allocator state first, then the cleaner list.
		when !NO_DEFAULT_TEMP_ALLOCATOR {
			default_temp_allocator_destroy(&global_default_temp_allocator_data)
		}
		_run_thread_local_cleaners_marked()

		// Drain: the marked pass above can leave fresh state behind. The
		// heap cleaner runs first in slot order, so temp/os destruction
		// after it — including a cleaner regrowing temp — can re-acquire a
		// heap that no further pass releases; likewise temp regrown after
		// the opening destroy is never reaped in a single round. Reap both
		// directly, temp first so its segments land in the heap the second
		// step releases. No callbacks run here and no completion bits or
		// registrations change: the destroy already runs unconditionally
		// above, and the heap release is a no-op unless the pass
		// re-acquired one. A later C destructor that allocates re-arms the
		// key into a fresh round on its own, which drains again the same way.
		when !NO_DEFAULT_TEMP_ALLOCATOR {
			default_temp_allocator_destroy(&global_default_temp_allocator_data)
		}
		heap_local_cleanup()

		_managed_cancel_restore(old_cancel)
	}

	// Idempotent arm of this thread's exit cleanup. Fast path is a single
	// thread-local load. The slow path disables cancellation across key
	// creation and binding: both take libc-internal locks, and an async
	// cancel landing inside would strand process-wide pthread state. A
	// racing thread waits inside pthread_once (a blocking primitive, not a
	// spin); if the creating thread were cancelled, once refunds and the
	// waiter retries creation itself.
	@(private)
	_managed_thread_cleanup_ensure :: proc "contextless" () -> Managed_Cleanup_Error {
		if _managed_cleanup_armed {
			return {}
		}
		old_cancel: i32
		if code := _managed_cancel_set(_MANAGED_CANCEL_DISABLE, &old_cancel); code != 0 {
			return Managed_Cleanup_Error{kind = .Protect_Cleanup, code = code}
		}
		err := Managed_Cleanup_Error{}
		if once_code := _managed_once(&_managed_cleanup_once, _managed_cleanup_key_init); once_code != 0 {
			err = Managed_Cleanup_Error{kind = .Init_Once, code = once_code}
		} else if create_code := _managed_key_create_code; create_code != 0 {
			err = Managed_Cleanup_Error{kind = .Create_Key, code = create_code}
		} else if bind_code := _managed_key_set(_managed_cleanup_key, rawptr(uintptr(1))); bind_code != 0 {
			err = Managed_Cleanup_Error{kind = .Bind_Thread, code = bind_code}
		} else {
			_managed_cleanup_armed = true
		}
		if restore_code := _managed_cancel_set(old_cancel, nil); restore_code != 0 && err.kind == .None {
			err = Managed_Cleanup_Error{kind = .Protect_Cleanup, code = restore_code}
		}
		return err
	}

	// Render a small integer to stderr without allocating, for fatal
	// diagnostics on paths where no allocator may be used.
	@(private)
	_write_decimal_to_stderr :: proc "contextless" (v: i32) {
		buf: [12]byte
		negative := v < 0
		n: u32 = u32(-i64(v)) if negative else u32(v)
		i := len(buf)
		if n == 0 {
			i -= 1
			buf[i] = '0'
		}
		for n > 0 {
			i -= 1
			buf[i] = byte(n % 10) + '0'
			n /= 10
		}
		if negative {
			i -= 1
			buf[i] = '-'
		}
		_, _ = _stderr_write(buf[i:])
	}

	// Arm step for call sites that cannot propagate failure (heap acquire,
	// default temp use, cleaner registration). Every failure mode carries
	// its pthread error number into the diagnostic: key creation and
	// binding fail only under process-wide resource exhaustion, and a
	// protection failure leaves cancellation handling inconsistent, so
	// continuing without cleanup would silently corrupt or leak every
	// foreign thread's state. Fail fast with a static diagnostic written
	// directly to stderr. The write itself is best-effort — the exit that
	// follows is unconditional — and neither step allocates nor touches any
	// context.
	@(private)
	_managed_thread_cleanup_ensure_or_die :: proc "contextless" () {
		err := _managed_thread_cleanup_ensure()
		if err.kind == .None {
			return
		}
		_managed_cleanup_fail(err)
	}

	// Fail fast with the given arm-path error. The pthread error number is
	// rendered into the diagnostic; the stderr write is best-effort and the
	// exit unconditional, using no allocator and no context.
	@(private)
	_managed_cleanup_fail :: proc "contextless" (err: Managed_Cleanup_Error) {
		msg := "runtime: pthread_key_create failed (errno "
		if err.kind == .Bind_Thread {
			msg = "runtime: pthread_setspecific failed (errno "
		} else if err.kind == .Protect_Cleanup {
			msg = "runtime: pthread_setcancelstate failed (errno "
		} else if err.kind == .Init_Once {
			msg = "runtime: pthread_once failed (errno "
		}
		_, _ = _stderr_write(transmute([]byte)(msg))
		_write_decimal_to_stderr(err.code)
		tail := "): cannot arm foreign-thread exit cleanup\n"
		_, _ = _stderr_write(transmute([]byte)(tail))
		_exit(134)
	}

// Disable cancellation across a guarded section, failing fast with the
// actual pthread error number on failure. An unprotected lock hold or
// teardown pass cannot be allowed to proceed, and the fixed callers
// (registry touch, snapshot, entry teardown, key destructor) cannot
// propagate the failure coherently, so the typed local fatal already
// used by the arm path carries the code into the diagnostic.
// Package-visible: the managed thread entry path in core thread guards
// its teardown with this pair.
}
