#+private
package os

import "base:runtime"

import "core:sync"
import "core:strings"

_ :: runtime
_ :: sync
_ :: strings

when !ODIN_NO_CRT {
	// TODO: Override the libc environment functions' weak linkage to
	//       allow us to interact with 3rd party code that DOES link
	//       to libc. Otherwise, our environment can be out of sync.

	// NOTE: This environment is maintained by Odin, not libc. Changes made
	// through core:os are not visible to libc's getenv when libc is linked,
	// and changes made through libc are not visible here.

	_Env_Entry :: struct {
		text:  string, // NUL-terminated KEY=VALUE, excluding the terminator
		owned: bool,
	}

	// All environment state is guarded by _env_mutex.
	_env: [dynamic]_Env_Entry
	_env_mutex: sync.Mutex
	_env_initialized: bool

	// The caller must hold _env_mutex, including while using the returned value.
	_lookup :: proc(key: string) -> (value: string, idx: int) {
		for entry, i in _env {
			if k, v := _kv_from_entry(entry.text); k == key {
				return v, i
			}
		}
		return "", -1
	}

	_lookup_env_alloc :: proc(key: string, allocator: runtime.Allocator) -> (value: string, found: bool) {
		sync.guard(&_env_mutex)
		if _build_env() != nil {
			return
		}

		if v, idx := _lookup(key); idx != -1 {
			found = true
			value, _ = clone_string(v, allocator)
		}
		return
	}

	_lookup_env_buf :: proc(buf: []u8, key: string) -> (value: string, err: Error) {
		sync.guard(&_env_mutex)
		_build_env() or_return

		if v, idx := _lookup(key); idx != -1 {
			if len(buf) >= len(v) {
				copy(buf, v)
				return string(buf[:len(v)]), nil
			}
			return "", .Buffer_Full
		}
		return "", .Env_Var_Not_Found
	}

	_lookup_env :: proc{_lookup_env_alloc, _lookup_env_buf}

	_set_env :: proc(key, value: string) -> Error {
		if key == "" || strings.index_byte(key, '=') != -1 {
			return _get_platform_error(.EINVAL)
		}
		sync.guard(&_env_mutex)
		_build_env() or_return

		old_value, idx := _lookup(key)
		if idx != -1 && old_value == value {
			return nil
		}

		// Allocate before replacing the old entry so failures leave it intact.
		bytes := make([]u8, len(key) + len(value) + 2, runtime.heap_allocator()) or_return
		copy(bytes, key)
		bytes[len(key)] = '='
		copy(bytes[len(key) + 1:], value)
		entry := _Env_Entry{string(bytes[:len(bytes) - 1]), true}
		if idx != -1 {
			_free_env_entry(_env[idx])
			_env[idx] = entry
		} else {
			if _, err := append(&_env, entry); err != nil {
				_free_env_entry(entry)
				return err
			}
		}
		return nil
	}

	_unset_env :: proc(key: string) -> bool {
		if key == "" || strings.index_byte(key, '=') != -1 {
			return false
		}
		sync.guard(&_env_mutex)
		if _build_env() != nil {
			return false
		}

		// Keep the order of inherited entries, including duplicate names.
		for i := 0; i < len(_env); {
			if k, _ := _kv_from_entry(_env[i].text); k == key {
				_free_env_entry(_env[i])
				ordered_remove(&_env, i)
			} else {
				i += 1
			}
		}
		return true
	}

	_clear_env :: proc() {
		sync.guard(&_env_mutex)
		for entry in _env {
			_free_env_entry(entry)
		}
		clear(&_env)
		_env.allocator = runtime.heap_allocator()
		_env_initialized = true
	}

	_environ :: proc(allocator: runtime.Allocator) -> (environ: []string, err: Error) {
		sync.guard(&_env_mutex)
		_build_env() or_return

		env := make([]string, len(_env), allocator) or_return
		defer if err != nil {
			for e in env {
				delete(e, allocator)
			}
			delete(env, allocator)
		}

		for entry, i in _env {
			env[i] = clone_string(entry.text, allocator) or_return
		}
		return env, nil
	}

	// Returns an independent, nil-terminated snapshot. Both the strings and the
	// pointer slice must be freed with allocator.
	export_cstring_environment :: proc(allocator: runtime.Allocator) -> (env: []cstring, err: Error) {
		sync.guard(&_env_mutex)
		_build_env() or_return

		env = make([]cstring, len(_env) + 1, allocator) or_return
		defer if err != nil {
			for entry in env {
				delete(entry, allocator)
			}
			delete(env, allocator)
			env = nil
		}
		for entry, i in _env {
			env[i] = clone_to_cstring(entry.text, allocator) or_return
		}
		return
	}

	// The caller must hold _env_mutex.
	_build_env :: proc() -> Error {
		if _env_initialized {
			return nil
		}

		cstring_env := _get_original_env()
		n: int
		for ; cstring_env[n] != nil; n += 1 {}
		env := make([dynamic]_Env_Entry, n, n, runtime.heap_allocator()) or_return
		for i in 0..<n {
			env[i] = _Env_Entry{string(cstring_env[i]), false}
		}
		_env = env
		_env_initialized = true
		return nil
	}

	_free_env_entry :: proc(entry: _Env_Entry) {
		if entry.owned {
			delete(entry.text, runtime.heap_allocator())
		}
	}

	_get_original_env :: #force_inline proc() -> [^]cstring {
		// essentially &argv[argc] which should be a nil pointer!
		#no_bounds_check env: [^]cstring = &runtime.args__[len(runtime.args__)]
		assert(env[0] == nil)
		return &env[1]
	}

	_kv_from_entry :: #force_inline proc(entry: string) -> (k, v: string) {
		eq_idx := strings.index_byte(entry, '=')
		if eq_idx == -1 {
			return entry, ""
		}
		return entry[:eq_idx], entry[eq_idx + 1:]
	}

}
