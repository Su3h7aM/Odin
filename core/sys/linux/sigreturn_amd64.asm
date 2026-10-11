bits 64

global _odin_linux_rt_sigreturn

section .note.GNU-stack noalloc noexec nowrite progbits
section .text

; Signal restorer. The kernel enters here with the signal frame at the top of
; the stack, so nothing may touch the stack pointer before the syscall.
_odin_linux_rt_sigreturn:
	mov eax, 15                     ; rt_sigreturn
	syscall
	ud2
