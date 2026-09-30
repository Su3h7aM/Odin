package runtime

import "base:intrinsics"

ODIN_VIRTUAL_MEMORY_SUPPORTED :: VIRTUAL_MEMORY_SUPPORTED

/*
Whether the sanitizer's interceptors see the calls this platform makes to give
memory back.

ThreadSanitizer keeps a shadow of every mapping a program has, and it learns
about mappings from its own interceptors of the C library. The Linux
implementation reaches the operating system through that library when the
sanitizer is asked for (see `virtual_memory_linux.odin`), so the sanitizer can
be told what happened. Where the memory is given back with a system call
instead, the shadow of the range would describe memory which another thread
maps and uses afterwards, so the pages are kept until the program ends.
*/
VIRTUAL_MEMORY_SANITIZER_INTERCEPTED :: ODIN_OS == .Linux

/*
The page size of the operating system, used for virtual memory allocations.
*/
page_size: int

/*
The superpage size of the operating system.

This may be zero if unavailable.
*/
superpage_size: int

/*
Returns the operating system's page size, setting up the virtual memory
layer first if nothing has yet. Global initializers may allocate before
runtime init procedures have run, so the setup here is lazy rather than
assumed.
*/
get_page_size :: proc "contextless" () -> int {
	if page_size == 0 {
		_init_virtual_memory()
	}
	return page_size
}

@(init, private)
init_virtual_memory :: proc "contextless" () {
	_init_virtual_memory()
}

/*
Allocate virtual memory from the operating system.

The address returned is guaranteed to point to data that is at least `size`
bytes large but may be larger, due to rounding `size` to the page size of the
system.
*/
@(require_results)
allocate_virtual_memory :: proc "contextless" (size: int) -> rawptr {
	return _allocate_virtual_memory(size)
}

/*
Allocate a superpage of virtual memory from the operating system.

This is a contiguous block of memory larger than what is normally distributed
by the operating system, sometimes with special performance properties related
to the Translation Lookaside Buffer.

The address will be a multiple of `superpage_size`, and the memory
pointed to will be at least as long as that.

The name derives from the superpage concept on the *BSD operating systems,
where it is known as huge pages on Linux and large pages on Windows.

This may return nil if a superpage size was unable to be retrieved from the
operating system or if the feature is otherwise unavailable.
*/
@(require_results)
allocate_virtual_memory_superpage :: proc "contextless" () -> rawptr {
	if superpage_size == 0 {
		return nil
	}
	return _allocate_virtual_memory_superpage()
}

/*
Allocate virtual memory from the operating system.

The address returned is guaranteed to be a multiple of `alignment` and point to
data that is at least `size` bytes large but may be larger, due to rounding
`size` to the page size of the system.

`alignment` must be a power of two.
*/
@(require_results)
allocate_virtual_memory_aligned :: proc "contextless" (size: int, alignment: int) -> rawptr {
	assert_contextless(is_power_of_two(alignment))
	return _allocate_virtual_memory_aligned(size, alignment)
}

/*
Free virtual memory allocated by any of the `allocate_*` procs.
*/
free_virtual_memory :: proc "contextless" (ptr: rawptr, size: int) {
	when .Thread not_in ODIN_SANITIZER_FLAGS || VIRTUAL_MEMORY_SANITIZER_INTERCEPTED {
		_free_virtual_memory(ptr, size)
	}
}

/*
Return the pages backing `ptr` to the operating system while keeping the address
space itself reserved.

When this returns true, the pages are guaranteed to read as zero the next time
they are used. Use this instead of `free_virtual_memory` to shrink the resident
set of a reservation that is expected to be used again.

Only whole pages inside the range can be given back, so the bytes of the pages
which are shared with something outside of the range are cleared instead.

The return value reports whether the operating system guarantees zero-filled
pages on subsequent access. A false result does not imply the pages were kept
unchanged: the advice may have discarded them without guaranteeing their
contents. Bytes at the edges of the range are cleared even when the return value
is false. If the range contains no whole pages, those edge bytes are still
cleared and false is returned.
*/
@(require_results)
decommit_virtual_memory :: proc "contextless" (ptr: rawptr, size: int) -> (decommitted: bool) {
	when VIRTUAL_MEMORY_SUPPORTED {
		if size <= 0 {
			return
		}

		align := uint(page_size)
		if align == 0 {
			align = 4 * Kilobyte
		}
		begin  := uint(uintptr(ptr))
		finish := begin + uint(size)
		start  := (begin + align-1) & ~(align-1)
		end    := finish & ~(align-1)

		if end <= start {
			return
		}

		// The pages at the edges cannot be given back without taking memory
		// along with them that belongs to someone else.
		if start > begin {
			intrinsics.mem_zero(ptr, int(start - begin))
		}
		if end < finish {
			intrinsics.mem_zero(rawptr(uintptr(ptr) + uintptr(end - begin)), int(finish - end))
		}

		// NOTE: The sanitizer is only told about pages which are given back when
		// its interceptors can see the call; see
		// `VIRTUAL_MEMORY_SANITIZER_INTERCEPTED`.
		when .Thread not_in ODIN_SANITIZER_FLAGS || VIRTUAL_MEMORY_SANITIZER_INTERCEPTED {
			return _decommit_virtual_memory(rawptr(uintptr(start)), int(end - start))
		}
	}
	return
}

/*
Make the pages at `ptr` inaccessible, so that any read or write to them faults.

`ptr` and `size` must be multiples of the page size. The pages stay part of the
reservation they are in and are given back along with it by
`free_virtual_memory`, which is what makes them a guard against an overflow
running off the end of the memory in front of them.

Returns whether the operating system protected them. This is a hint for
hardening, not a requirement for correctness, so memory management on top of it
must remain correct when it is false.
*/
@(require_results)
protect_virtual_memory :: proc "contextless" (ptr: rawptr, size: int) -> (protected: bool) {
	when VIRTUAL_MEMORY_SUPPORTED {
		assert_contextless(size > 0 && uintptr(ptr) % uintptr(get_page_size()) == 0 && size % get_page_size() == 0)
		return _protect_virtual_memory(ptr, size)
	}
	return
}

/*
Make the memory at `ptr` larger without moving it.

Returns false if the memory could not be extended, in which case it is left
exactly as it was and the caller has to make a copy somewhere else.

`new_size` must be larger than `old_size`.
*/
@(require_results)
resize_virtual_memory_in_place :: proc "contextless" (ptr: rawptr, old_size: int, new_size: int) -> (resized: bool) {
	when VIRTUAL_MEMORY_SUPPORTED {
		assert_contextless(old_size < new_size)
		return _resize_virtual_memory_in_place(ptr, old_size, new_size)
	}
	return false
}

/*
Resize virtual memory allocated by `allocate_virtual_memory`.

**Caveats:**

- `new_size` must not be zero.
- If `old_size` and `new_size` are the same, nothing happens.
- The resulting behavior is undefined if `old_size` is incorrect.
- If the address is changed, `alignment` will be ensured.
- `alignment` should be the same value used when the memory was allocated.
- Resizing memory returned by `allocate_virtual_memory_superpage` is not
  well-defined. The memory may be resized, but it may no longer be backed by a
  superpage.
*/
@(require_results)
resize_virtual_memory :: proc "contextless" (ptr: rawptr, old_size: int, new_size: int, alignment: int = 0) -> rawptr {
	// * This is due to a restriction of mremap on Linux.
	assert_contextless(new_size != 0, "Cannot resize virtual memory address to zero.")
	// * The statement about undefined behavior of incorrect `old_size` is due to
	//   how VirtualFree works on Windows.
	if old_size == new_size {
		return ptr
	}
	return _resize_virtual_memory(ptr, old_size, new_size, alignment)
}
