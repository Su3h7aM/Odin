#+build linux amd64, linux arm64, linux riscv64
#+no-instrumentation
package runtime

when ODIN_NO_CRT {
	when ODIN_ARCH == .amd64 {
		@require foreign import stack_protector_asm "stack_protector_linux_no_crt_amd64.asm"
		@(private, export, require, linkage="strong", link_name="_odin_linux_stack_guard")
		linux_stack_guard: uintptr
	} else when ODIN_ARCH == .arm64 {
		@require foreign import stack_protector_asm "stack_protector_linux_no_crt_arm64.asm"
		@(private, export, require, linkage="strong", link_name="__stack_chk_guard")
		linux_stack_guard: uintptr
	} else when ODIN_ARCH == .riscv64 {
		@require foreign import stack_protector_asm "stack_protector_linux_no_crt_riscv64.asm"
		@(private, export, require, linkage="strong", link_name="__stack_chk_guard")
		linux_stack_guard: uintptr
	}

	// The entry stub seeds the guard from AT_RANDOM before any Odin procedure.
	// The failure handler uses only assembly and syscalls, so LLVM cannot add a
	// stack-protector check to it. It writes to stderr and exits the process with
	// status 134 without consulting context, TLS, allocators, or cleaners.
	@(private)
	foreign stack_protector_asm {
		@(link_name="__stack_chk_fail")
		linux_stack_chk_fail :: proc "contextless" () -> ! ---
	}
}
