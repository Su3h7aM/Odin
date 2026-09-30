package nocrt_smoke

import "base:runtime"
import "core:os"
import "core:sys/linux"

// Exercises core:os (env roundtrip through the -no-crt path) with zero C runtime.
// Fails to link if anything pulls in libc.
main :: proc() {
	os.set_env("ODIN_CI_SMOKE", "a")
	os.set_env("ODIN_CI_SMOKE", "a longer value that resizes the entry")
	v, ok := os.lookup_env("ODIN_CI_SMOKE", runtime.heap_allocator())
	assert(ok && v == "a longer value that resizes the entry")
	os.unset_env("ODIN_CI_SMOKE")

	msg := "no-crt ok\n"
	linux.write(linux.STDOUT_FILENO, transmute([]byte)msg)
}
