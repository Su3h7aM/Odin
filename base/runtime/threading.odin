package runtime

import "base:intrinsics"

Thread_Local_Cleaner_Odin :: #type proc "odin" ()
Thread_Local_Cleaner_Contextless :: #type proc "contextless" ()

Thread_Local_Cleaner :: union #shared_nil {Thread_Local_Cleaner_Odin, Thread_Local_Cleaner_Contextless}

@(private="file")
thread_local_cleaners: [8]Thread_Local_Cleaner

// The thread ID is cached here to save time from making syscalls with every
// call.
@(thread_local) local_thread_id: int

// Return the current thread ID.
@(require_results)
get_current_thread_id :: proc "contextless" () -> int {
	if local_thread_id == 0 {
		local_thread_id = _get_current_thread_id()
		assert_contextless(local_thread_id != 0, "_get_current_thread_id returned 0.")
	}
	return local_thread_id
}

// Add a procedure that will be run at the end of a thread for the purpose of
// deallocating state marked as `thread_local`.
//
// Intended to be called in an `init` procedure of a package with
// dynamically-allocated memory that is stored in `thread_local` variables.
//
// On managed Linux builds the cleaners also run from a pthread-key
// destructor on threads the runtime did not create. Each cleaner runs at
// most once per thread: per-thread completion bits record every run, and
// resource reacquisition clears the matching bit so a reacquired resource
// is released again. The destructor binds a valid context with working
// heap and temporary allocators, so cleaners may allocate; state allocated
// during cleanup is picked up by a later destructor round.
add_thread_local_cleaner :: proc "contextless" (p: Thread_Local_Cleaner) {
	// Protection matrix: Linux-managed (all arch) and Linux-native amd64
	// publish every scan and store under the registration lock below
	// (each slot is a multiword union). Every other profile keeps the
	// original lock-free direct scan/store: no new locks, guarded or
	// otherwise, outside the protected pair. Duplicate registrations are
	// preserved (first nil slot wins) on all profiles.
	when ODIN_OS == .Linux && (!ODIN_NO_CRT || ODIN_ARCH == .amd64) {
		// The full check escapes the lock and panicking happens after
		// unlock, since neither may run under it.
		when !ODIN_NO_CRT {
			// One cancellation-protected operation: the outer disable
			// spans the store below and the key ensure/bind after it.
			// The store's lock has no internal cancellation guard, so
			// the disable must already hold when the lock is taken; a
			// kill in between could otherwise strand the lock or tear
			// the multiword union. The lock is still dropped before key
			// initialization runs.
			outer := _managed_cancel_guard()
		}
		idx := _cleaner_reg_store(p)
		if idx < 0 {
			when !ODIN_NO_CRT {
				_managed_cancel_restore(outer)
			}
			panic_contextless("There are no more thread-local cleaner slots available.")
		}
		when !ODIN_NO_CRT {
			// A thread registering thread-local state needs exit cleanup even
			// if it never touches the heap or the default temporary allocator.
			// Still inside the outer span: registered-but-unbound state
			// is never observable, and key initialization runs without
			// the registration lock held.
			_managed_thread_cleanup_ensure_or_die()
			_managed_cancel_restore(outer)
		}
	} else {
		for i in 0..<len(thread_local_cleaners) {
			if thread_local_cleaners[i] == nil {
				thread_local_cleaners[i] = p
				return
			}
		}
		panic_contextless("There are no more thread-local cleaner slots available.")
	}
}

// Run all of the thread-local cleaner procedures.
//
// Intended to be called by the internals of a threading API at the end of a
// thread's lifetime.
run_thread_local_cleaners :: proc "odin" () {
	// Protected profiles (Linux-managed all arch, Linux-native amd64)
	// load each slot coherently under the profile guard and run the
	// callback only after drop/unmask: per-slot loads preserve the
	// legacy dynamic behavior (a cleaner appended mid-run is still
	// seen) while no torn multiword union is ever invoked. No marks:
	// the explicit manual call runs every registered cleaner. All
	// other profiles keep the original direct iteration.
	// Managed manual cleanup additionally marks each slot before its
	// callback (without ever skipping on marks), so a later automatic
	// pass skips what manual cleanup already ran; native manual
	// cleanup neither marks nor skips, per the native protocol.
	when ODIN_OS == .Linux && (!ODIN_NO_CRT || ODIN_ARCH == .amd64) {
		when !ODIN_NO_CRT {
			// Managed: the fail-fast disable spans the whole manual
			// pass, so no cancel can land between a slot's mark and
			// its callback; the registry lock itself is still held
			// only for each single-slot load, never across a
			// callback. The nested load guards re-disable (no-op)
			// and restore (no-op) coherently inside the outer span.
			outer := _managed_cancel_guard()
			for i in 0..<len(thread_local_cleaners) {
				p := _cleaner_reg_load(i)
				if p == nil {
					break
				}
				_managed_cleaner_done[i] = true
				switch v in p {
				case Thread_Local_Cleaner_Odin:        v()
				case Thread_Local_Cleaner_Contextless: v()
				}
			}
			_managed_cancel_restore(outer)
		} else {
			// Linux-native amd64: per-slot reserved mask across each
			// short copy only; callbacks run unmasked with no marks,
			// per the native protocol.
			for i in 0..<len(thread_local_cleaners) {
				p := _cleaner_reg_load(i)
				if p == nil {
					break
				}
				switch v in p {
				case Thread_Local_Cleaner_Odin:        v()
				case Thread_Local_Cleaner_Contextless: v()
				}
			}
		}
	} else {
		for p in thread_local_cleaners {
			if p == nil {
				break
			}
			switch v in p {
			case Thread_Local_Cleaner_Odin:        v()
			case Thread_Local_Cleaner_Contextless: v()
			}
		}
	}
}

// Linux-managed per-thread cleaner completion state. The global registry
// above stays intact: registrations are never consumed, deduplicated, or
// reordered. These bits record, per thread, which slots already ran, so
// each cleaner runs at most once per thread across the entry-path defers
// and every destructor round. Zero-initialized thread-local storage means
// a new thread always starts with nothing completed.
//
// Stable slot publication (protected profiles only: Linux-managed all
// arch, Linux-native amd64): each slot is a multiword union, so every
// scan, store, and single-slot load happens under the registration
// spinlock below. Callbacks and key initialization never run under it:
// the lock covers only bounded straight-line single-slot work. Readers
// load one slot at a time and invoke the callback only after drop (and
// unmask on native amd64), so a cleaner appended mid-run is still seen
// exactly as with the legacy direct iteration. All other profiles keep
// the original lock-free direct access and never touch this lock.
@(private="file")
_cleaner_reg_lock: u32

@(private="file")
_cleaner_reg_lock_take :: proc "contextless" () {
	// Linux-native amd64 masks the reserved owned-cancellation pair
	// before taking the lock, so a force-terminated holder can neither
	// strand it nor leave a half-held registry; the mask counter nests
	// and foreign threads (nil TLS) mask nothing. Linux-managed callers
	// hold the fail-fast libc disable instead (see the guarded touch
	// and load below). No other profile uses this lock.
	when ODIN_OS == .Linux && ODIN_NO_CRT && ODIN_ARCH == .amd64 {
		_owned_cancel_mask_self()
	}
	for intrinsics.atomic_exchange(&_cleaner_reg_lock, u32(1)) != 0 {
		intrinsics.cpu_relax()
	}
}

@(private="file")
_cleaner_reg_lock_drop :: proc "contextless" () {
	// Unlock strictly before unmasking: a replayed cancel must never
	// observe the lock held.
	intrinsics.atomic_exchange(&_cleaner_reg_lock, u32(0))
	when ODIN_OS == .Linux && ODIN_NO_CRT && ODIN_ARCH == .amd64 {
		_owned_cancel_unmask_self()
	}
}

// Store in the first nil slot, preserving duplicates. Returns the slot
// index, or -1 when full (the caller panics outside the lock).
@(private="file")
_cleaner_reg_store :: proc "contextless" (p: Thread_Local_Cleaner) -> int {
	_cleaner_reg_lock_take()
	idx := -1
	for i in 0..<len(thread_local_cleaners) {
		if thread_local_cleaners[i] == nil {
			idx = i
			break
		}
	}
	if idx >= 0 {
		thread_local_cleaners[idx] = p
	}
	_cleaner_reg_lock_drop()
	return idx
}

// Scan for the cleaner, clear every matching completion bit, and append
// when absent. Returns true when the registry is full and the cleaner is
// missing (the caller panics outside the lock; the process is aborting, so
// no cancellation state needs restoring on that path).
@(private="file")
_cleaner_reg_touch :: proc "contextless" (cleaner: Thread_Local_Cleaner) -> (full: bool) {
	_cleaner_reg_lock_take()
	matched := false
	first_nil := -1
	for i in 0..<len(thread_local_cleaners) {
		if thread_local_cleaners[i] == cleaner {
			matched = true
			when ODIN_OS == .Linux && !ODIN_NO_CRT {
				_managed_cleaner_done[i] = false
			}
		} else if first_nil < 0 && thread_local_cleaners[i] == nil {
			first_nil = i
		}
	}
	if !matched && first_nil >= 0 {
		thread_local_cleaners[first_nil] = cleaner
	}
	_cleaner_reg_lock_drop()
	return !matched && first_nil < 0
}

// Coherent single-slot load for the protected profiles. The guard covers
// only the bounded load: Linux-managed disables libc cancellation
// fail-fast across it, Linux-native amd64 is covered by the reserved
// mask inside the lock pair. The caller runs the callback only after
// drop (and unmask), never under the lock.
when ODIN_OS == .Linux && (!ODIN_NO_CRT || ODIN_ARCH == .amd64) {
	@(private="file")
	_cleaner_reg_load :: proc "contextless" (i: int) -> Thread_Local_Cleaner {
		when !ODIN_NO_CRT {
			old := _managed_cancel_guard()
		}
		_cleaner_reg_lock_take()
		p := thread_local_cleaners[i]
		_cleaner_reg_lock_drop()
		when !ODIN_NO_CRT {
			_managed_cancel_restore(old)
		}
		return p
	}
}

// Idempotent internal registration with per-thread completion tracking.
// Ensures the cleaner is registered (appending when missing) and, on
// Linux-managed builds, clears every matching completion bit so a
// reacquired resource is released again at the next cleanup. All matching
// slots are handled independently: duplicate registrations are preserved,
// and completion stays per slot, never per unique procedure. Available on
// every platform so first acquisition can register lazily (including
// loader-phase threads and native builds); only the bit operations are
// Linux-managed-gated.
_managed_thread_cleanup_reactivate :: proc "contextless" (cleaner: Thread_Local_Cleaner) {
	// Protected profiles touch the registry locked under the profile
	// guard: fail-fast libc disable on Linux-managed, the reserved
	// mask inside the lock pair on Linux-native amd64. The touch and
	// the ensuing key ensure/bind share one outer disable span, so no
	// cancel can land with state registered but the key unbound; the
	// registration lock is never held across pthread initialization.
	// All other profiles keep the original direct duplicate-preserving
	// append with no lock and no lifecycle mutation beyond it.
	when ODIN_OS == .Linux && (!ODIN_NO_CRT || ODIN_ARCH == .amd64) {
		when !ODIN_NO_CRT {
			outer := _managed_cancel_guard()
		}
		full := _cleaner_reg_touch(cleaner)
		when !ODIN_NO_CRT {
			if full {
				_managed_cancel_restore(outer)
				panic_contextless("There are no more thread-local cleaner slots available.")
			}
			// Arming is part of lazy registration: a thread whose only
			// lifecycle event is a first acquisition (never an explicit
			// add_) still needs the key bound, or the destructor never
			// fires for it. Runs unlocked, inside the outer span; the
			// nested guards inside ensure re-disable (no-op) and
			// restore (no-op) coherently.
			_managed_thread_cleanup_ensure_or_die()
			_managed_cancel_restore(outer)
		} else {
			if full {
				panic_contextless("There are no more thread-local cleaner slots available.")
			}
		}
	} else {
		matched := false
		first_nil := -1
		for i in 0..<len(thread_local_cleaners) {
			if thread_local_cleaners[i] == cleaner {
				matched = true
			} else if first_nil < 0 && thread_local_cleaners[i] == nil {
				first_nil = i
			}
		}
		if !matched {
			if first_nil >= 0 {
				thread_local_cleaners[first_nil] = cleaner
			} else {
				panic_contextless("There are no more thread-local cleaner slots available.")
			}
		}
	}
}

when ODIN_OS == .Linux && !ODIN_NO_CRT {
	@(thread_local, private)
	_managed_cleaner_done: [8]bool

	// Disable cancellation across a guarded section, failing fast with
	// the actual pthread error number on failure. An unprotected lock
	// hold or teardown pass cannot be allowed to proceed, and the fixed
	// callers (registry touch, slot load, manual pass, entry teardown,
	// key destructor) cannot propagate the failure coherently, so the
	// typed local fatal already used by the arm path carries the code
	// into the diagnostic. Defined here (not in threading_linux.odin,
	// which is #+private) because the managed thread entry path in core
	// thread guards its teardown with this pair.
	_managed_cancel_guard :: proc "contextless" () -> (old: i32) {
		if code := _managed_cancel_set(_MANAGED_CANCEL_DISABLE, &old); code != 0 {
			_managed_cleanup_fail(Managed_Cleanup_Error{kind = .Protect_Cleanup, code = code})
		}
		return old
	}

	// Restore a state saved by the guard. A failed restore fails fast
	// the same way: leaving the thread in the wrong cancelability
	// after a protected section is not a residual callers can absorb.
	_managed_cancel_restore :: proc "contextless" (old: i32) {
		if code := _managed_cancel_set(old, nil); code != 0 {
			_managed_cleanup_fail(Managed_Cleanup_Error{kind = .Protect_Cleanup, code = code})
		}
	}
	// Run every cleaner that has not yet run on this thread, marking each
	// slot before running it. Marking first bounds each cleaner to a single
	// invocation per thread. Each slot is loaded coherently under the
	// fail-fast guard and the lock, then the callback runs after unlock
	// and restore; a cleaner registered during the run lands in a later
	// slot whose bit is unset and still runs exactly once, matching the
	// legacy dynamic behavior.
	// Runs with the caller's context: the entry path calls with the
	// thread's context, the destructor binds a valid one first.
	_run_thread_local_cleaners_marked :: proc "odin" () {
		for i in 0..<len(thread_local_cleaners) {
			p := _cleaner_reg_load(i)
			if p == nil {
				break
			}
			if _managed_cleaner_done[i] {
				continue
			}
			_managed_cleaner_done[i] = true
			switch v in p {
			case Thread_Local_Cleaner_Odin:        v()
			case Thread_Local_Cleaner_Contextless: v()
			}
		}
	}
}
