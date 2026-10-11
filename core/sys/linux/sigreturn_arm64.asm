.text
.globl _odin_linux_rt_sigreturn
.type _odin_linux_rt_sigreturn, %function

// Signal restorer. The kernel enters here with the signal frame at the top of
// the stack, so nothing may touch the stack pointer before the syscall.
_odin_linux_rt_sigreturn:
	mov x8, #139                    // rt_sigreturn
	svc #0
	brk #0
.size _odin_linux_rt_sigreturn, .-_odin_linux_rt_sigreturn
.section .note.GNU-stack,"",%progbits
