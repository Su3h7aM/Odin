#+build linux amd64
package runtime

import "base:intrinsics"

// Process lifecycle for Linux amd64 without the C runtime: C constructor and
// destructor arrays plus an owned atexit registry. Static non-PIE executables
// only: the dynamic loader never runs here, so nobody else will run these.
// Wired into _start_odin in entry_unix.odin under the same target gate.
//
// The entry points below are also called from compiler-generated test
// startup, which runs after parallel code generation has finished. Keep their
// bodies free of private procedure callees: only LLVM intrinsics may appear,
// so no unqueued procedure reference can break that path. Registry state is
// package-private so the backend can define it explicitly for that path.
when ODIN_NO_CRT {
	// Linker-synthesized array bounds. lld materializes each pair on reference
	// and leaves start equal to end when the section is absent, which the
	// walkers treat as the empty no-op case. Addresses only: never load through
	// a bound as if it were an entry.
	//
	// Unreferenced control: rooted startup pulls only its actual dependency
	// closure, never co-file procedures. This proc must not appear in any
	// linked binary or object.
	@(private="file")
	_owned_startup_unrelated_probe :: proc() -> int {
		return 701
	}
	//
	// Early thread and credential startup shared by the normal entry and the
	// compiler-generated test entry. Runs after TP install and before
	// environ publication and all constructors on both paths: registry
	// bootstrap registers the initial thread, then credential and handler
	// install either succeeds or terminates startup here, never continuing
	// with partial state.
	_owned_startup_bootstrap :: proc() {
		_owned_thread_registry_bootstrap()
		if err := _owned_credentials_init(); err != 0 {
			_fatal_startup("thread credentials init failed", err)
		}
	}

	// Last-resort startup diagnostic: raw writes only, no context,
	// allocation, or cleanup.
	@(private="file")
	_fatal_write :: proc "contextless" (s: string) {
		if len(s) == 0 {
			return
		}
		intrinsics.syscall(1, 2, uintptr(raw_data(transmute([]u8)s)), uintptr(len(s)))
	}

	@(private)
	_fatal_startup :: proc(msg: string, code: int) -> ! {
		_fatal_write("odin: ")
		_fatal_write(msg)
		_fatal_write(" (errno ")
		buf: [24]u8
		n := 0
		v := code
		if v < 0 {
			buf[n] = '-'
			n += 1
			v = -v
		}
		start := n
		if v == 0 {
			buf[n] = '0'
			n += 1
		}
		for v > 0 {
			buf[n] = u8(v % 10) + '0'
			n += 1
			v /= 10
		}
		for i := start; i < (start + n) / 2; i += 1 {
			j := start + n - 1 - i
			buf[i], buf[j] = buf[j], buf[i]
		}
		_fatal_write(string(buf[:n]))
		_fatal_write(")\n")
		intrinsics.syscall(231, 1)
		unreachable()
	}
	@(private="file")
	foreign {
		@(link_name="__preinit_array_start")
		_preinit_array_start: rawptr
		@(link_name="__preinit_array_end")
		_preinit_array_end: rawptr
		@(link_name="__init_array_start")
		_init_array_start: rawptr
		@(link_name="__init_array_end")
		_init_array_end: rawptr
		@(link_name="__fini_array_start")
		_fini_array_start: rawptr
		@(link_name="__fini_array_end")
		_fini_array_end: rawptr
	}

	// Runs after args, TLS, the stack guard, and the default context are ready,
	// and before the full Odin startup, matching ordinary builds where C
	// constructors run in the loader before Odin package initializers. Called
	// constructors take the same argc, argv, and envp the process started
	// with, covering both void and three-argument C functions. Callbacks may
	// allocate and use TLS through the same lazy paths global initializers
	// use, but Odin user-initialized globals are not ready yet.
	run_c_init_arrays :: proc "contextless" (argc: i32, argv: [^]cstring, envp: [^]cstring) {
		p := ([^]rawptr)(&_preinit_array_start)
		end := ([^]rawptr)(&_preinit_array_end)
		for p < end {
			fn := (proc "c" (argc: i32, argv: [^]cstring, envp: [^]cstring))(p[0])
			if fn != nil {
				fn(argc, argv, envp)
			}
			p = ([^]rawptr)(uintptr(p) + size_of(rawptr))
		}
		p = ([^]rawptr)(&_init_array_start)
		end = ([^]rawptr)(&_init_array_end)
		for p < end {
			fn := (proc "c" (argc: i32, argv: [^]cstring, envp: [^]cstring))(p[0])
			if fn != nil {
				fn(argc, argv, envp)
			}
			p = ([^]rawptr)(uintptr(p) + size_of(rawptr))
		}
	}

	// Runs after the owned atexit drain and before Odin heap cleanup.
	run_c_fini_arrays :: proc "contextless" () {
		p := ([^]rawptr)(&_fini_array_end)
		end := ([^]rawptr)(&_fini_array_start)
		for p > end {
			p = ([^]rawptr)(uintptr(p) - size_of(rawptr))
			fn := (proc "c" ())(p[0])
			if fn != nil {
				fn()
			}
		}
	}

	@(private)
	_ATEXIT_CAP :: 64

	@(private)
	_atexit_lock: int
	@(private)
	_atexit_fns: [_ATEXIT_CAP]proc "c" ()
	@(private)
	_atexit_n: int
	@(private)
	_draining: bool
	@(private)
	_closed: bool

	// Owned atexit for static executables without libc. Same shape as the C
	// function: zero on success, nonzero when the table is full. A nil handler
	// is rejected. Registration is safe from any thread at any time and stays
	// open across finalizer phases: handlers registered while C or Odin
	// finalizers run append to a later drain instead of being lost. Each
	// registration runs once, including duplicates registered separately. Once
	// the registry is closed after the final drain, registration fails.
	@(link_name="atexit", linkage="strong", require)
	atexit :: proc "c" (fn: proc "c" ()) -> i32 {
		if fn == nil {
			return 1
		}
		for intrinsics.atomic_exchange(&_atexit_lock, 1) != 0 {
		}
		if _closed || _atexit_n >= _ATEXIT_CAP {
			intrinsics.atomic_exchange(&_atexit_lock, 0)
			return 1
		}
		_atexit_fns[_atexit_n] = fn
		_atexit_n += 1
		intrinsics.atomic_exchange(&_atexit_lock, 0)
		return 0
	}

	// Drains every registered handler, looping until empty so re-registrations
	// during the drain are picked up. Safe to call once per shutdown phase;
	// nested calls return at once while the outer loop keeps draining. Each
	// handler is popped under the lock and the lock is released before the
	// call. Raw exits and worker thread exits never reach this.
	drain_atexit :: proc() {
		for intrinsics.atomic_exchange(&_atexit_lock, 1) != 0 {
		}
		if _closed || _draining {
			intrinsics.atomic_exchange(&_atexit_lock, 0)
			return
		}
		_draining = true
		for _atexit_n > 0 {
			_atexit_n -= 1
			fn := _atexit_fns[_atexit_n]
			intrinsics.atomic_exchange(&_atexit_lock, 0)
			fn()
			for intrinsics.atomic_exchange(&_atexit_lock, 1) != 0 {
			}
		}
		_draining = false
		intrinsics.atomic_exchange(&_atexit_lock, 0)
	}

	// Terminal step of process shutdown: registrations after this fail
	// explicitly instead of being silently lost.
	// Empty and close happen under one lock hold with no window between them:
	// a registration appended by the last callback is drained, while one
	// landing after the close flag fails explicitly.
	drain_and_close_atexit :: proc() {
		for intrinsics.atomic_exchange(&_atexit_lock, 1) != 0 {
		}
		if _closed || _draining {
			intrinsics.atomic_exchange(&_atexit_lock, 0)
			return
		}
		_draining = true
		for _atexit_n > 0 {
			_atexit_n -= 1
			fn := _atexit_fns[_atexit_n]
			intrinsics.atomic_exchange(&_atexit_lock, 0)
			fn()
			for intrinsics.atomic_exchange(&_atexit_lock, 1) != 0 {
			}
		}
		_draining = false
		_closed = true
		intrinsics.atomic_exchange(&_atexit_lock, 0)
	}
}
