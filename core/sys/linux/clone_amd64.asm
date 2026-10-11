bits 64

global _odin_linux_clone

section .note.GNU-stack noalloc noexec nowrite progbits
section .text

; clone(2) callback interface. The child cannot use the parent's return frame.
_odin_linux_clone:
	and rsi, -16
	sub rsi, 16
	mov [rsi], rdi                  ; fn
	mov [rsi+8], rcx                ; arg
	mov rdi, rdx                    ; flags
	mov rdx, r8                     ; parent_tid
	mov r10, [rsp+8]                ; child_tid
	mov r8, r9                      ; tls
	mov eax, 56                     ; clone
	syscall
	test rax, rax
	jz .child
	ret
.child:
	xor ebp, ebp
	pop rax
	pop rdi
	call rax
	mov edi, eax
	mov eax, 60                     ; exit, not exit_group
	syscall
	ud2
