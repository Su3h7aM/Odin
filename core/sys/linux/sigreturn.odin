#+build linux amd64, linux arm64
#+no-instrumentation
package linux

when ODIN_ARCH == .amd64 {
	foreign import sigreturn_asm "sigreturn_amd64.asm"
} else when ODIN_ARCH == .arm64 {
	foreign import sigreturn_asm "sigreturn_arm64.asm"
}

/*
	Returns from a signal handler by restoring the context saved in the signal
	frame. This is the signal restorer for `rt_sigaction`, written in assembly
	because it runs with the signal frame at the top of the stack, where a
	compiler prologue (stack protector, sanitizer calls) would corrupt it.
	It must not be called directly.
	Available since Linux 2.2.
*/
foreign sigreturn_asm {
	@(link_name="_odin_linux_rt_sigreturn")
	rt_sigreturn :: proc "c" () -> ! ---
}
