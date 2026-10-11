bits 64
global _odin_linux_tls_layout
section .note.GNU-stack noalloc noexec nowrite progbits
section .text

; (Elf64_Phdr *header, Layout *out) -> bool. No TLS, context, or syscalls.
; Layout has six words: size, alignment, TP bias, signed block offset, image, filesz.
; Variant II span = memsz + ((-vaddr-memsz) & (align-1)).
; The 48-byte TCB holds the self-pointer and the stack guard at TP+0x28.
; A null header requests only the startup TCB, without managed static TLS.
_odin_linux_tls_layout:
	test rdi, rdi
	jz .empty
	mov r8, [rdi+40]               ; memsz
	mov r9, [rdi+32]               ; filesz
	cmp r9, r8
	ja .fail
	mov r10, [rdi+16]              ; vaddr
	mov rax, r10
	add rax, r9
	jc .fail
	mov rcx, [rdi+48]              ; align
	test rcx, rcx
	jnz .alignment
	mov ecx, 1
.alignment:
	lea rdx, [rcx-1]
	test rcx, rdx
	jnz .fail
	xor eax, eax
	sub rax, r10
	sub rax, r8
	and rax, rdx
	add r8, rax
	jc .fail
	cmp rcx, 8
	jae .size
	mov ecx, 8                     ; Align the TCB self-pointer too.
.size:
	lea rdx, [rcx-1]
	mov rax, r8
	add rax, rdx
	jc .fail
	add rax, 48
	jc .fail
	mov [rsi], rax
	mov [rsi+8], rcx
	mov [rsi+16], r8
	neg r8
	mov [rsi+24], r8
	mov [rsi+32], r10
	mov [rsi+40], r9
	mov eax, 1
	ret
.empty:
	mov qword [rsi], 55            ; 48-byte TCB plus alignment slack.
	mov qword [rsi+8], 8
	mov qword [rsi+16], 0
	mov qword [rsi+24], 0
	mov qword [rsi+32], 0
	mov qword [rsi+40], 0
	mov eax, 1
	ret
.fail:
	xor eax, eax
	ret
