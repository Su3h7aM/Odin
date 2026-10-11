bits 64
global __stack_chk_fail:function
section .note.GNU-stack noalloc noexec nowrite progbits
section .rodata
message: db "runtime: stack protector check failed", 10
message_size equ $-message
section .text

; No stack frame, TLS, or calls to protected code, even on a corrupted stack.
__stack_chk_fail:
	lea rsi, [rel message]
	mov edx, message_size
.write:
	mov eax, 1                     ; write
	mov edi, 2                     ; stderr
	syscall
	cmp rax, -4                    ; EINTR
	je .write
	test rax, rax
	jle .exit
	add rsi, rax
	sub rdx, rax
	jnz .write
.exit:
	mov eax, 231                   ; exit_group
	mov edi, 134
	syscall
	ud2
