#+build linux amd64, linux arm64, linux riscv64
#+private
package runtime

// Test executables use a compiler-generated _start_odin rather than the
// ordinary entry_unix procedure. Both need the same pre-Odin TLS bootstrap.
when ODIN_TEST && ODIN_NO_CRT && !ODIN_NO_ENTRY_POINT && !ODIN_NO_THREAD_LOCAL {
	when ODIN_ARCH == .amd64 {
		@require foreign import entry "entry_unix_no_crt_linux_amd64.asm"
	} else when ODIN_ARCH == .arm64 {
		@require foreign import entry "entry_unix_no_crt_linux_arm64.asm"
	} else when ODIN_ARCH == .riscv64 {
		@require foreign import entry "entry_unix_no_crt_linux_riscv64.asm"
	}
}
