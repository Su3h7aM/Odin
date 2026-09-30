#+no-instrumentation
package sanitizer

@(private="file")
TSAN_ENABLED :: .Thread in ODIN_SANITIZER_FLAGS

/*
Creation and operation flags for an annotated mutex, mirroring the `__tsan_mutex_*`
flag constants.

`write_reentrant` and `read_reentrant` mark a mutex that may be locked again by the
thread that already holds it. `not_static` marks a mutex without static storage
duration: it must be passed to `thread_mutex_destroy` for tsan to honour the
destruction and report a later use of the mutex as an error. `read_lock`, `try_lock`,
`try_lock_failed`, `recursive_lock` and `recursive_unlock` describe the operation
being annotated and belong to the lock and unlock annotations rather than to creation.
*/
Thread_Mutex_Flag :: enum u32 {
	write_reentrant  = 1,
	read_reentrant   = 2,
	read_lock        = 3,
	try_lock         = 4,
	try_lock_failed  = 5,
	recursive_lock   = 6,
	recursive_unlock = 7,
	not_static       = 8,
}

Thread_Mutex_Flags :: distinct bit_set[Thread_Mutex_Flag; u32]

@(private="file")
@(default_calling_convention="system")
foreign {
	__tsan_acquire              :: proc(addr: rawptr) ---
	__tsan_release              :: proc(addr: rawptr) ---
	__tsan_mutex_create         :: proc(addr: rawptr, flags: u32) ---
	__tsan_mutex_destroy        :: proc(addr: rawptr, flags: u32) ---
	__tsan_mutex_pre_lock       :: proc(addr: rawptr, flags: u32) ---
	__tsan_mutex_post_lock      :: proc(addr: rawptr, flags: u32, recursion: i32) ---
	__tsan_mutex_pre_unlock     :: proc(addr: rawptr, flags: u32) -> i32 ---
	__tsan_mutex_post_unlock    :: proc(addr: rawptr, flags: u32) ---
	__tsan_read_range           :: proc(addr: rawptr, size: uint) ---
	__tsan_write_range          :: proc(addr: rawptr, size: uint) ---
	__tsan_ignore_thread_begin  :: proc() ---
	__tsan_ignore_thread_end    :: proc() ---
}

/*
Establishes a happens-before edge with a preceding `thread_release` on the same address.

Code instrumented with `-sanitize:thread` treats everything the releasing thread
did before its `thread_release` as visible to the calling thread afterwards.
This is how custom synchronization and allocators tell tsan about hand-offs it
cannot otherwise see, such as a memory mapping recycled by the operating system
between two unrelated threads. The edge is keyed by address: reuse at a
different address, including partial overlaps from different-sized mappings,
is not ordered by this pair.

When tsan is not enabled this procedure does nothing.
*/
@(no_sanitize_thread)
thread_acquire :: proc "contextless" (addr: rawptr) {
	when TSAN_ENABLED {
		__tsan_acquire(addr)
	}
}

/*
Establishes a happens-before edge with a following `thread_acquire` on the same address.

Code instrumented with `-sanitize:thread` treats everything the calling thread
did before this call as visible to whichever thread later calls `thread_acquire`
with the same address. Pair it with `thread_acquire` when ownership of a resource
passes between threads outside of tsan's view.

When tsan is not enabled this procedure does nothing.
*/
@(no_sanitize_thread)
thread_release :: proc "contextless" (addr: rawptr) {
	when TSAN_ENABLED {
		__tsan_release(addr)
	}
}

/*
Annotates the creation of a custom mutex at `addr`.

Code instrumented with `-sanitize:thread` only tracks a mutex that has been
annotated: the creation, lock, unlock and destruction annotations are what let it
report the set of held mutexes, detect mutex misuse and deadlocks, and skip the
individual atomic operations inside the lock implementation. `flags` carries the
creation values of `Thread_Mutex_Flag`: `write_reentrant`, `read_reentrant` and
`not_static`. Calling this is optional: the creation flags may instead be passed to
`thread_mutex_pre_lock` and `thread_mutex_post_lock`.

When tsan is not enabled this procedure does nothing.
*/
@(no_sanitize_thread)
thread_mutex_create :: proc "contextless" (addr: rawptr, flags: Thread_Mutex_Flags) {
	when TSAN_ENABLED {
		__tsan_mutex_create(addr, transmute(u32)flags)
	}
}

/*
Annotates the destruction of a custom mutex at `addr`.

Code instrumented with `-sanitize:thread` reports a later use of the mutex as an
error, as long as `.not_static` was previously set on the mutex. Without it the
destruction is ignored.

When tsan is not enabled this procedure does nothing.
*/
@(no_sanitize_thread)
thread_mutex_destroy :: proc "contextless" (addr: rawptr, flags: Thread_Mutex_Flags) {
	when TSAN_ENABLED {
		__tsan_mutex_destroy(addr, transmute(u32)flags)
	}
}

/*
Annotates the start of a lock operation on the custom mutex at `addr`.

Call it immediately before the mutex is actually acquired, and pair it with
`thread_mutex_post_lock` immediately after. `flags` carries `.read_lock` for a read
lock and `.try_lock` for a try lock, plus the creation flags described by
`thread_mutex_create`. The annotated code itself is not checked for correctness,
so the pair must cover the real acquire.

When tsan is not enabled this procedure does nothing.
*/
@(no_sanitize_thread)
thread_mutex_pre_lock :: proc "contextless" (addr: rawptr, flags: Thread_Mutex_Flags) {
	when TSAN_ENABLED {
		__tsan_mutex_pre_lock(addr, transmute(u32)flags)
	}
}

/*
Annotates the end of a lock operation on the custom mutex at `addr`.

`flags` must repeat `.read_lock` and `.try_lock` from the matching
`thread_mutex_pre_lock`, and add `.try_lock_failed` when the lock attempt failed
and `.recursive_lock` when the lock acquired several recursion levels at once.
`recursion` is the number of levels acquired, and is `0` for a normal lock.

When tsan is not enabled this procedure does nothing.
*/
@(no_sanitize_thread)
thread_mutex_post_lock :: proc "contextless" (addr: rawptr, flags: Thread_Mutex_Flags, recursion: i32) {
	when TSAN_ENABLED {
		__tsan_mutex_post_lock(addr, transmute(u32)flags, recursion)
	}
}

/*
Annotates the start of an unlock operation on the custom mutex at `addr`.

Call it immediately before the mutex is actually released, and pair it with
`thread_mutex_post_unlock` immediately after. `flags` carries `.read_lock` for a
read unlock and `.recursive_unlock` when the unlock releases all recursion levels
at once. The returned number of released recursion levels is passed as the
`recursion` argument of the next `thread_mutex_post_lock` for the same mutex.

When tsan is not enabled this procedure returns `0`.
*/
@(no_sanitize_thread)
thread_mutex_pre_unlock :: proc "contextless" (addr: rawptr, flags: Thread_Mutex_Flags) -> i32 {
	when TSAN_ENABLED {
		return __tsan_mutex_pre_unlock(addr, transmute(u32)flags)
	} else {
		return 0
	}
}

/*
Annotates the end of an unlock operation on the custom mutex at `addr`.

`flags` must repeat `.read_lock` from the matching `thread_mutex_pre_unlock`, and
is otherwise empty. It must be called immediately after the mutex is released, so
that the code that follows is checked again.

When tsan is not enabled this procedure does nothing.
*/
@(no_sanitize_thread)
thread_mutex_post_unlock :: proc "contextless" (addr: rawptr, flags: Thread_Mutex_Flags) {
	when TSAN_ENABLED {
		__tsan_mutex_post_unlock(addr, transmute(u32)flags)
	}
}

/*
Annotates a read of the region covering `[addr, addr+size)`.

Code instrumented with `-sanitize:thread` instruments ordinary memory accesses
itself, so this is only needed where it cannot see the access, such as a bulk copy
performed by uninstrumented code. A read ordered before a `thread_write_range` of
the same region is reported as a data race.

When tsan is not enabled this procedure does nothing.
*/
@(no_sanitize_thread)
thread_read_range :: proc "contextless" (addr: rawptr, size: uint) {
	when TSAN_ENABLED {
		__tsan_read_range(addr, size)
	}
}

/*
Annotates a write of the region covering `[addr, addr+size)`.

Code instrumented with `-sanitize:thread` instruments ordinary memory accesses
itself, so this is only needed where it cannot see the access, such as a bulk copy
performed by uninstrumented code. A write unordered against any access of the same
region is reported as a data race.

When tsan is not enabled this procedure does nothing.
*/
@(no_sanitize_thread)
thread_write_range :: proc "contextless" (addr: rawptr, size: uint) {
	when TSAN_ENABLED {
		__tsan_write_range(addr, size)
	}
}

/*
Starts a region of the calling thread that tsan does not check for races.

Use it around work on data the thread is known to own exclusively, such as a
private scratch allocator or a thread-local cache, to keep tsan's reports focused.
Every call must be balanced by `thread_ignore_end`, and the annotations inside the
region must not establish happens-before edges relied upon elsewhere.

When tsan is not enabled this procedure does nothing.
*/
@(no_sanitize_thread)
thread_ignore_begin :: proc "contextless" () {
	when TSAN_ENABLED {
		__tsan_ignore_thread_begin()
	}
}

/*
Ends the region started by `thread_ignore_begin`, resuming tsan's race checking.

When tsan is not enabled this procedure does nothing.
*/
@(no_sanitize_thread)
thread_ignore_end :: proc "contextless" () {
	when TSAN_ENABLED {
		__tsan_ignore_thread_end()
	}
}
