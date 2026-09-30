#+no-instrumentation
package sanitizer

@(private="file")
ASAN_ENABLED :: .Address in ODIN_SANITIZER_FLAGS

@(private="file")
@(default_calling_convention="system")
foreign {
	__asan_poison_memory_region   :: proc(address: rawptr, size: uint) ---
	__asan_unpoison_memory_region :: proc(address: rawptr, size: uint) ---
	__asan_region_is_poisoned    :: proc(begin: rawptr, size: uint) -> rawptr ---
	__asan_address_is_poisoned   :: proc(addr: rawptr) -> i32 ---
}

/*
Marks the region covering `[ptr, ptr+len)` as unaddressable.

Code instrumented with `-sanitize:address` is forbidden from accessing any
address within the region. This procedure is not thread-safe because no two
threads can poison or unpoison memory in the same memory region simultaneously.

When asan is not enabled this procedure does nothing.
*/
@(no_sanitize_address)
address_poison_rawptr :: proc "contextless" (ptr: rawptr, len: int) {
	when ASAN_ENABLED {
		assert_contextless(len >= 0)
		__asan_poison_memory_region(ptr, uint(len))
	}
}

@(no_sanitize_address)
address_poison_rawptr_uint :: proc "contextless" (ptr: rawptr, len: uint) {
	when ASAN_ENABLED {
		__asan_poison_memory_region(ptr, len)
	}
}

/*
Marks the region covering `[ptr, ptr+len)` as addressable.

Code instrumented with `-sanitize:address` is allowed to access any address
within the region again. This procedure is not thread-safe because no two
threads can poison or unpoison memory in the same memory region simultaneously.

When asan is not enabled this procedure does nothing.
*/
@(no_sanitize_address)
address_unpoison_rawptr :: proc "contextless" (ptr: rawptr, len: int) {
	when ASAN_ENABLED {
		assert_contextless(len >= 0)
		__asan_unpoison_memory_region(ptr, uint(len))
	}
}

@(no_sanitize_address)
address_unpoison_rawptr_uint :: proc "contextless" (ptr: rawptr, len: uint) {
	when ASAN_ENABLED {
		__asan_unpoison_memory_region(ptr, len)
	}
}

address_poison :: proc {
	address_poison_rawptr,
	address_poison_rawptr_uint,
}

address_unpoison :: proc {
	address_unpoison_rawptr,
	address_unpoison_rawptr_uint,
}

/*
Checks if the memory region covered by `[ptr, ptr+len)` is poisoned.

If it is poisoned this procedure returns the address which would result in an
asan error. When asan is not enabled this procedure returns `nil`.
*/
@(no_sanitize_address)
address_region_is_poisoned_rawptr :: proc "contextless" (ptr: rawptr, len: int) -> rawptr {
	when ASAN_ENABLED {
		assert_contextless(len >= 0)
		return __asan_region_is_poisoned(ptr, uint(len))
	} else {
		return nil
	}
}

address_region_is_poisoned :: proc {
	address_region_is_poisoned_rawptr,
}

/*
Checks if the address is poisoned.

When asan is not enabled this procedure returns `false`.
*/
@(no_sanitize_address)
address_is_poisoned :: proc "contextless" (address: rawptr) -> bool {
	when ASAN_ENABLED {
		return __asan_address_is_poisoned(address) != 0
	} else {
		return false
	}
}
