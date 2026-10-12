#+private
#+build !darwin
#+build !freebsd
#+build !linux
#+build !netbsd
#+build !openbsd
#+build !windows
package runtime

VIRTUAL_MEMORY_SUPPORTED :: false

_init_virtual_memory :: proc "contextless" () { }

_allocate_virtual_memory :: proc "contextless" (size: int) -> rawptr {
	unimplemented_contextless("Virtual memory is not supported on this platform.")
}

_allocate_virtual_memory_superpage :: proc "contextless" () -> rawptr {
	unimplemented_contextless("Virtual memory is not supported on this platform.")
}

_allocate_virtual_memory_aligned :: proc "contextless" (size: int, alignment: int) -> rawptr {
	unimplemented_contextless("Virtual memory is not supported on this platform.")
}

_free_virtual_memory :: proc "contextless" (ptr: rawptr, size: int) {
	unimplemented_contextless("Virtual memory is not supported on this platform.")
}

_decommit_virtual_memory :: proc "contextless" (ptr: rawptr, size: int) -> (decommitted: bool) {
	// Nothing was ever handed out by the operating system, so there is nothing
	// for it to take back.
	return false
}

_protect_virtual_memory :: proc "contextless" (ptr: rawptr, size: int) -> (protected: bool) {
	// Not yet supported on this platform. The caller treats protection as a
	// hint, so the memory simply stays accessible.
	return false
}

_resize_virtual_memory_in_place :: proc "contextless" (ptr: rawptr, old_size: int, new_size: int) -> (resized: bool) {
	// Nothing was ever handed out by the operating system, so there is nothing
	// to extend.
	return false
}

_resize_virtual_memory :: proc "contextless" (ptr: rawptr, old_size: int, new_size: int, alignment: int) -> rawptr {
	unimplemented_contextless("Virtual memory is not supported on this platform.")
}
