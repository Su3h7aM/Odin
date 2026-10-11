#+build linux
package posix

import "base:runtime"
import "core:c"
import env "core:sys/_env"

_ :: runtime
_ :: c
_ :: env

when ODIN_NO_CRT {
	// getenv returns a borrowed pointer. Calls that mutate the environment can
	// invalidate it. Direct environ writes and caller edits to putenv strings must
	// be synchronized with environment operations by the caller.
	getenv :: proc "c" (name: cstring) -> cstring {
		return env.getenv(name)
	}

	// setenv copies name and value before changing the environment. Allocation
	// failure preserves the previous table and values.
	setenv :: proc "c" (envname: cstring, envval: cstring, overwrite: b32) -> result {
		context = runtime.default_context()
		return errno_result(env.setenv(envname, envval, bool(overwrite), runtime.heap_allocator()))
	}

	// unsetenv removes every occurrence of name, including inherited duplicates.
	unsetenv :: proc "c" (name: cstring) -> result {
		context = runtime.default_context()
		context = runtime.default_context()
		return errno_result(env.unsetenv(name, runtime.heap_allocator()))
	}

	// putenv adopts the caller's string without copying or freeing it. Later edits
	// to that storage are visible. Without '=', Linux putenv removes the name.
	putenv :: proc "c" (string: cstring) -> c.int {
		context = runtime.default_context()
		return c.int(errno_result(env.putenv(string, runtime.heap_allocator())))
	}

}
