#+no-instrumentation
package sanitizer

@(private="file")
ASAN_ENABLED :: .Address in ODIN_SANITIZER_FLAGS

@(private="file")
SANITIZER_ENABLED :: ODIN_SANITIZER_FLAGS != {}

@(private="file")
@(default_calling_convention="system")
foreign {
	__sanitizer_print_stack_trace             :: proc() ---
	__sanitizer_set_report_path               :: proc(path: cstring) ---
	__sanitizer_annotate_contiguous_container :: proc(beg, end, old_mid, new_mid: rawptr) ---
	__sanitizer_verify_contiguous_container   :: proc(beg, mid, end: rawptr) -> i32 ---
}

/*
Prints the stack trace leading to this call, using the sanitizer's own symbolizer.

The trace is written where the enabled sanitizer writes its reports. This is useful
from a debugger and from a check that cannot rely on Odin's own stack trace support.
`__sanitizer_print_stack_trace` is defined by every sanitizer runtime, so this
procedure covers all three of them.

When no sanitizer is enabled this procedure does nothing.
*/
print_stack_trace :: proc "contextless" () {
	when SANITIZER_ENABLED {
		__sanitizer_print_stack_trace()
	}
}

/*
Tells the sanitizer to write its reports to `path.<pid>` instead of to `stderr`.

Both the address and the memory runtime define this entry point, so the call is
made whenever any sanitizer is enabled. `path` must outlive the call and is not
copied.

When no sanitizer is enabled this procedure does nothing.
*/
set_report_path :: proc "contextless" (path: cstring) {
	when SANITIZER_ENABLED {
		__sanitizer_set_report_path(path)
	}
}

/*
Annotates the spare capacity of a contiguous container, such as `core:container`'s
`Queue` or `Priority_Queue`.

The container owns `[beg, end)`; `[beg, new_mid)` holds the current elements and
`[new_mid, end)` is the spare capacity, which the annotation marks as unaddressable
for asan. `old_mid` and `new_mid` are the middle of the container before and after
the operation being annotated, so the initial and final states of a container that
grows from the end pass `end` as the middle. This is the annotation that catches an
out-of-bounds write into spare capacity, which asan cannot otherwise see.

When asan is not enabled this procedure does nothing.
*/
@(no_sanitize_address)
container_annotate :: proc "contextless" (beg, end, old_mid, new_mid: rawptr) {
	when ASAN_ENABLED {
		__sanitizer_annotate_contiguous_container(beg, end, old_mid, new_mid)
	}
}

/*
Checks that the contiguous container `[beg, end)` with element boundary `mid` is
annotated as `container_annotate` would have left it.

Returns `true` when `[beg, mid)` is addressable and `[mid, end)` is unaddressable,
otherwise it returns `false`. The check touches only the granules around `beg`,
`mid` and `end`, so it is cheap but not exhaustive.

When asan is not enabled this procedure returns `false`.
*/
@(no_sanitize_address)
container_verify :: proc "contextless" (beg, mid, end: rawptr) -> bool {
	when ASAN_ENABLED {
		return __sanitizer_verify_contiguous_container(beg, mid, end) != 0
	} else {
		return false
	}
}
