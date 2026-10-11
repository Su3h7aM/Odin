#+build linux
#+private
package os

import "base:runtime"
import env "core:sys/_env"

_ :: runtime
_ :: env

when ODIN_NO_CRT {
	_lookup_env_alloc :: proc(key: string, allocator: runtime.Allocator) -> (value: string, found: bool) {
		value, found, _ = env.lookup_copy(key, allocator)
		return
	}

	_lookup_env_buf :: proc(buf: []u8, key: string) -> (value: string, err: Error) {
		found, fits: bool
		value, found, fits = env.lookup_into(key, buf)
		if !found {
			return "", .Env_Var_Not_Found
		}
		if !fits {
			return "", .Buffer_Full
		}
		return
	}

	_lookup_env :: proc{_lookup_env_alloc, _lookup_env_buf}

	_set_env :: proc(key, value: string) -> Error {
		err, allocation_error := env.setenv_text(key, value, true, runtime.heap_allocator())
		if allocation_error != nil {
			return allocation_error
		}
		if err != .NONE {
			return _get_platform_error(err)
		}
		return nil
	}

	_unset_env :: proc(key: string) -> bool {
		return env.unsetenv_text(key, runtime.heap_allocator()) == .NONE
	}

	_clear_env :: proc() {
		env.clear_environment()
	}

	_environ :: proc(allocator: runtime.Allocator) -> (environment: []string, err: Error) {
		snapshot := env.take_snapshot(runtime.heap_allocator()) or_return
		defer env.release_snapshot(snapshot)
		environment = make([]string, len(snapshot.values) - 1, allocator) or_return
		defer if err != nil {
			for entry in environment {
				delete(entry, allocator)
			}
			delete(environment, allocator)
			environment = nil
		}
		for entry, i in snapshot.values[:len(snapshot.values) - 1] {
			environment[i] = clone_string(string(entry), allocator) or_return
		}
		return
	}

	// The table and each string are independently owned by allocator, as in the
	// CRT implementation. The leaf snapshot is captured under the shared lock.
	export_cstring_environment :: proc(allocator: runtime.Allocator) -> (environment: []cstring, err: Error) {
		snapshot := env.take_snapshot(runtime.heap_allocator()) or_return
		defer env.release_snapshot(snapshot)
		environment = make([]cstring, len(snapshot.values), allocator) or_return
		defer if err != nil {
			for entry in environment {
				delete(entry, allocator)
			}
			delete(environment, allocator)
			environment = nil
		}
		for entry, i in snapshot.values[:len(snapshot.values) - 1] {
			environment[i] = clone_to_cstring(string(entry), allocator) or_return
		}
		return
	}

}
