#+no-instrumentation
package sanitizer

@(private="file")
MSAN_ENABLED :: .Memory in ODIN_SANITIZER_FLAGS

@(private="file")
@(default_calling_convention="system")
foreign {
	__msan_unpoison                 :: proc(addr: rawptr, size: uint) ---
	__msan_unpoison_string          :: proc(str: cstring) ---
	__msan_poison                   :: proc(addr: rawptr, size: uint) ---
	__msan_check_mem_is_initialized :: proc(addr: rawptr, size: uint) ---
}

/*
Marks a slice as fully initialized.

Code instrumented with `-sanitize:memory` will be permitted to access any
address within the slice as if it had already been initialized.

When msan is not enabled this procedure does nothing.
*/
@(no_sanitize_memory)
memory_unpoison_slice :: proc "contextless" (region: $T/[]$E) {
	when MSAN_ENABLED {
		__msan_unpoison(raw_data(region),  size_of(E) * len(region))
	}
}

/*
Marks a pointer as fully initialized.

Code instrumented with `-sanitize:memory` will be permitted to access memory
within the region the pointer points to as if it had already been initialized.

When msan is not enabled this procedure does nothing.
*/
@(no_sanitize_memory)
memory_unpoison_ptr :: proc "contextless" (ptr: ^$T) {
	when MSAN_ENABLED {
		__msan_unpoison(ptr, size_of(T))
	}
}

/*
Marks the region covering `[ptr, ptr+len)` as fully initialized.

Code instrumented with `-sanitize:memory` will be permitted to access memory
within this range as if it had already been initialized.

When msan is not enabled this procedure does nothing.
*/
@(no_sanitize_memory)
memory_unpoison_rawptr :: proc "contextless" (ptr: rawptr, len: int) {
	when MSAN_ENABLED {
		__msan_unpoison(ptr, uint(len))
	}
}

/*
Marks the region covering `[ptr, ptr+len)` as fully initialized.

Code instrumented with `-sanitize:memory` will be permitted to access memory
within this range as if it had already been initialized.

When msan is not enabled this procedure does nothing.
*/
@(no_sanitize_memory)
memory_unpoison_rawptr_uint :: proc "contextless" (ptr: rawptr, len: uint) {
	when MSAN_ENABLED {
		__msan_unpoison(ptr, len)
	}
}

memory_unpoison :: proc {
	memory_unpoison_slice,
	memory_unpoison_ptr,
	memory_unpoison_rawptr,
	memory_unpoison_rawptr_uint,
}

/*
Marks a C string as fully initialized.

Code instrumented with `-sanitize:memory` will be permitted to read the string
up to and including its terminating zero byte as if it had already been
initialized. Use this for text produced outside of msan's view, such as a string
returned from an uninstrumented C library.

When msan is not enabled this procedure does nothing.
*/
@(no_sanitize_memory)
memory_unpoison_string :: proc "contextless" (str: cstring) {
	when MSAN_ENABLED {
		__msan_unpoison_string(str)
	}
}

/*
Marks a slice as uninitialized.

Code instrumented with `-sanitize:memory` reports a use of uninitialized memory
when any address within the slice is read before it is written. This is how an
allocator hands out memory whose contents msan should not trust, for example the
payload of a recycled block.

When msan is not enabled this procedure does nothing.
*/
@(no_sanitize_memory)
memory_poison_slice :: proc "contextless" (region: $T/[]$E) {
	when MSAN_ENABLED {
		__msan_poison(raw_data(region), size_of(E) * len(region))
	}
}

/*
Marks the region the pointer points to as uninitialized.

Code instrumented with `-sanitize:memory` reports a use of uninitialized memory
when any address within that region is read before it is written.

When msan is not enabled this procedure does nothing.
*/
@(no_sanitize_memory)
memory_poison_ptr :: proc "contextless" (ptr: ^$T) {
	when MSAN_ENABLED {
		__msan_poison(ptr, size_of(T))
	}
}

/*
Marks the region covering `[ptr, ptr+len)` as uninitialized.

Code instrumented with `-sanitize:memory` reports a use of uninitialized memory
when any address within the region is read before it is written.

When msan is not enabled this procedure does nothing.
*/
@(no_sanitize_memory)
memory_poison_rawptr :: proc "contextless" (ptr: rawptr, len: int) {
	when MSAN_ENABLED {
		__msan_poison(ptr, uint(len))
	}
}

/*
Marks the region covering `[ptr, ptr+len)` as uninitialized.

Code instrumented with `-sanitize:memory` reports a use of uninitialized memory
when any address within the region is read before it is written.

When msan is not enabled this procedure does nothing.
*/
@(no_sanitize_memory)
memory_poison_rawptr_uint :: proc "contextless" (ptr: rawptr, len: uint) {
	when MSAN_ENABLED {
		__msan_poison(ptr, len)
	}
}

memory_poison :: proc {
	memory_poison_slice,
	memory_poison_ptr,
	memory_poison_rawptr,
	memory_poison_rawptr_uint,
}

/*
Checks that the region covering `[ptr, ptr+len)` is fully initialized.

Code instrumented with `-sanitize:memory` reports an error and terminates the
process if any address within the region is still uninitialized. Use it at a
boundary where the program requires initialized data, such as before handing
memory to uninstrumented code, rather than to read the shadow state.

When msan is not enabled this procedure does nothing.
*/
@(no_sanitize_memory)
memory_check_initialized :: proc "contextless" (ptr: rawptr, len: uint) {
	when MSAN_ENABLED {
		__msan_check_mem_is_initialized(ptr, len)
	}
}
