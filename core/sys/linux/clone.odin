#+build linux amd64, linux arm64, linux riscv64
#+no-instrumentation
package linux

when ODIN_ARCH == .amd64 {
	foreign import clone_asm "clone_amd64.asm"
} else when ODIN_ARCH == .arm64 {
	foreign import clone_asm "clone_arm64.asm"
} else when ODIN_ARCH == .riscv64 {
	foreign import clone_asm "clone_riscv64.asm"
}

@(private)
foreign clone_asm {
	@(link_name="_odin_linux_clone")
	clone_entry :: proc(fn: proc "c" (rawptr) -> i32, stack: rawptr, flags: u32, arg: rawptr, parent_tid: ^Pid, tls: rawptr, child_tid: ^Pid) -> int ---
}

/*
	Create a child which calls fn(arg) on the supplied stack and exits with its
	return value. stack points to the top of a writable, downward-growing stack.
	The caller owns the stack and must retain it until the child has exited.

	This mirrors the clone(2) libc wrapper interface, not the raw syscall's
	architecture-dependent argument order. Assembly is required to enter fn on
	the replacement stack without returning through the calling procedure's frame.
	No libc is called. If CLONE_SETTLS is used, tls must describe a valid thread
	pointer for the child ABI before fn accesses any thread-local storage.
	Available since Linux 1.0; these architectures require their respective Linux
	ports. CLONE_THREAD is available since Linux 2.4.0.
*/
clone :: proc "contextless" (fn: proc "c" (rawptr) -> i32, stack: rawptr, flags: u32, arg: rawptr, parent_tid: ^Pid = nil, tls: rawptr = nil, child_tid: ^Pid = nil) -> (Pid, Errno) {
	if fn == nil || stack == nil {
		return 0, .EINVAL
	}
	return errno_unwrap(clone_entry(fn, stack, flags, arg, parent_tid, tls, child_tid), Pid)
}
