#+private
#+build linux, darwin, freebsd, openbsd, netbsd
#+no-instrumentation
package runtime

import "base:intrinsics"

when ODIN_BUILD_MODE == .Dynamic {
	@(link_name="_odin_entry_point", linkage="strong", require/*, link_section=".init"*/)
	_odin_entry_point :: proc "c" (argc: i32, argv: [^]cstring) {
		args__ = argv[:argc]
		context = default_context()
		when !ODIN_BEDROCK { #force_no_inline _startup_runtime() }
		intrinsics.__entry_point()
	}
	@(link_name="_odin_exit_point", linkage="strong", require/*, link_section=".fini"*/)
	_odin_exit_point :: proc "c" () {
		context = default_context()
		when !ODIN_BEDROCK {
			#force_no_inline _cleanup_runtime()
		}
	}
	@(link_name="main", linkage="strong", require)
	main :: proc "c" (argc: i32, argv: [^]cstring) -> i32 {
		return 0
	}
} else when !ODIN_TEST && !ODIN_NO_ENTRY_POINT {
	when ODIN_NO_CRT {
		// NOTE(flysand): We need to start from assembly because we need
		// to retrieve argc and argv from the stack
		when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
			@require foreign import entry "entry_unix_no_crt_linux_amd64.asm"
			SYS_exit :: 60
		} else when ODIN_ARCH == .amd64 {
			@require foreign import entry "entry_unix_no_crt_amd64.asm"
			SYS_exit :: 60
		} else when ODIN_ARCH == .i386 {
			@require foreign import entry "entry_unix_no_crt_i386.asm"
			SYS_exit :: 1
		} else when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
			@require foreign import entry "entry_unix_no_crt_darwin_arm64.asm"
			SYS_exit :: 1
		} else when ODIN_OS == .Linux && ODIN_ARCH == .arm64 {
			@require foreign import entry "entry_unix_no_crt_linux_arm64.asm"
			SYS_exit :: 93
		} else when ODIN_OS == .Linux && ODIN_ARCH == .riscv64 {
			@require foreign import entry "entry_unix_no_crt_linux_riscv64.asm"
			SYS_exit :: 93
		} else when ODIN_ARCH == .riscv64 {
			@require foreign import entry "entry_unix_no_crt_riscv64.asm"
			SYS_exit :: 93
		}
		@(link_name="_start_odin", linkage="strong", require)
		_start_odin :: proc "c" (argc: i32, argv: [^]cstring) -> ! {
			args__ = argv[:argc]
			context = default_context()
			// Linux amd64 publishes the inherited environment and runs C
			// constructors here: TLS, the stack guard, args, and the default
			// context are ready, while Odin package initializers still wait
			// for the full startup below, matching the ordinary order of
			// loader constructors before Odin inits. envp follows the argv
			// terminator on the initial stack, so no assembly change is needed
			// to recover it.
			when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
				// Owned thread and credential setup precedes everything that
				// can observe threads. Shared with the generated test entry
				// through the same helper.
				_owned_startup_bootstrap()
				envp := publish_startup_environ(argv, argc)
				run_c_init_arrays(argc, argv, envp)
			}
			when !ODIN_BEDROCK { #force_no_inline _startup_runtime() }
			intrinsics.__entry_point()
			// Owned atexit handlers drain, then C destructors in reverse, then
			// Odin cleanup. _cleanup_runtime itself runs the final atomic
			// drain and close after user finalizers and before runtime
			// teardown, so registrations from either side are covered. Raw
			// exits and worker thread exits never reach this path.
			when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
				drain_atexit()
				run_c_fini_arrays()
			}
			when !ODIN_BEDROCK { #force_no_inline _cleanup_runtime() }
			// Process exit, not thread exit: surviving workers must not keep
			// a torn-down process alive. Other targets keep their syscall.
			when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
				// 231 is exit_group on amd64, matching the per-arch table in
				// os_specific_linux._exit, which stays the raw-exit path.
				intrinsics.syscall(231, 0)
			} else {
				intrinsics.syscall(SYS_exit, 0)
			}
			unreachable()
		}
	} else {
		@(link_name="main", linkage="strong", require)
		main :: proc "c" (argc: i32, argv: [^]cstring) -> i32 {
			args__ = argv[:argc]
			context = default_context()
			when !ODIN_BEDROCK { #force_no_inline _startup_runtime() }
			intrinsics.__entry_point()
			when !ODIN_BEDROCK { #force_no_inline _cleanup_runtime() }
			return 0
		}
	}
}
