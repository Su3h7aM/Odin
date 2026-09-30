/*
The `sanitizer` package implements various procedures for interacting with sanitizers
from user code.

An odin project can be linked with various sanitizers to help identify various different
bugs. These sanitizers are:

## Address

Enabled with `-sanitize:address` when building an odin project.

The address sanitizer (asan) is a runtime memory error detector used to help find common memory
related bugs. Typically asan interacts with libc but Odin code can be marked up to interact
with the asan runtime to extend the memory error detection outside of libc using this package.
For more information about asan see: https://clang.llvm.org/docs/AddressSanitizer.html

Procedures can be made exempt from asan when marked up with @(no_sanitize_address)

## Memory

Enabled with `-sanitize:memory` when building an odin project.

The memory sanitizer is another runtime memory error detector with the sole purpose to catch the
use of uninitialized memory. This is not a very common bug in Odin as by default everything is
set to zero when initialised (ZII).
For more information about the memory sanitizer see: https://clang.llvm.org/docs/MemorySanitizer.html

## Thread

Enabled with `-sanitize:thread` when building an odin project.

The thread sanitizer is a runtime data race detector. It can be used to detect if multiple threads
are concurrently writing and accessing a memory location without proper syncronisation.
For more information about the thread sanitizer see: https://clang.llvm.org/docs/ThreadSanitizer.html

Procedures can be made exempt from tsan when marked up with @(no_sanitize_thread).
Custom synchronization and allocators can describe hand-offs tsan cannot otherwise
see with `thread_release` and `thread_acquire`.

## Groups

Beyond the hand-off pair, each sanitizer contributes a group of annotations. The
thread group adds custom mutex annotations (`thread_mutex_create` through
`thread_mutex_post_unlock`) with `Thread_Mutex_Flags`, the bulk access pair
`thread_read_range`/`thread_write_range`, and `thread_ignore_begin`/`thread_ignore_end`
for work a thread owns privately. The memory group adds the poison side of msan
(`memory_poison`), the C string and initialized-range helpers
(`memory_unpoison_string`, `memory_check_initialized`). The address group adds
`address_set_error_report_callback` and the fake stack pair. The common group adds
`print_stack_trace`, `set_report_path`, and the contiguous container annotations
`container_annotate`/`container_verify`, which are asan-only.

*/
package sanitizer

