#+no-instrumentation
package sanitizer

@(private="file")
TSAN_ENABLED :: .Thread in ODIN_SANITIZER_FLAGS

@(private="file")
@(default_calling_convention="system")
foreign {
	__tsan_acquire :: proc(addr: rawptr) ---
	__tsan_release :: proc(addr: rawptr) ---
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
