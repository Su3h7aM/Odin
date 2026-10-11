bits 64

extern _start_odin
extern _odin_linux_tls_layout
extern _odin_linux_tls_header
extern _odin_linux_stack_guard
global _start

section .note.GNU-stack noalloc noexec nowrite progbits
section .text

;; Linux amd64 static no-CRT entry. AMD64 psABI 3.4.1 and 3.4.3.
;; Static non-PIE only: static PIE needs self-relocation, which this stub does not do.
_start:
	xor ebp, ebp
	cld
	mov r13, [rsp]                  ; argc
	lea r14, [rsp+8]                ; argv
	lea rbx, [r14+r13*8+8]          ; envp
.env:
	cmp qword [rbx], 0
	lea rbx, [rbx+8]
	jne .env

	xor r8d, r8d                   ; AT_PHDR
	xor r9d, r9d                   ; AT_PHENT
	xor r10d, r10d                 ; AT_PHNUM
	xor r12d, r12d                 ; AT_RANDOM
.auxv:
	mov rax, [rbx]
	test rax, rax
	jz .headers
	cmp rax, 3
	jne .phent
	mov r8, [rbx+8]
.phent:
	cmp rax, 4
	jne .phnum
	mov r9, [rbx+8]
.phnum:
	cmp rax, 5
	jne .random
	mov r10, [rbx+8]
.random:
	cmp rax, 25                    ; AT_RANDOM points to 16 random bytes.
	jne .next_auxv
	mov r12, [rbx+8]
.next_auxv:
	add rbx, 16
	jmp .auxv

.headers:
	test r12, r12
	jz .fail
	mov rax, [r12]
	and rax, -256                  ; Zero the low byte, as a terminator canary.
	mov [rel _odin_linux_stack_guard], rax
	xor r15d, r15d                 ; PT_TLS header, or a TCB-only layout.
	test r8, r8
	jz .init_tls
	cmp r9, 56                     ; sizeof(Elf64_Phdr)
	jne .fail
	mov rbx, r8
	xor edx, edx                   ; PT_INTERP present
.next_header:
	test r10, r10
	jz .tls
	cmp dword [rbx], 3             ; PT_INTERP
	jne .tls_header
	mov edx, 1
.tls_header:
	cmp dword [rbx], 7             ; PT_TLS
	jne .advance_header
	test r15, r15
	jnz .fail
	mov r15, rbx
.advance_header:
	add rbx, r9
	jc .fail
	dec r10
	jmp .next_header

.tls:
	test edx, edx
	jnz .enter_odin                ; The dynamic loader already installed TLS.
	mov [rel _odin_linux_tls_header], r15
.init_tls:
	and rsp, -16
	sub rsp, 48                    ; Shared TLS layout, six words.
	mov rdi, r15
	mov rsi, rsp
	call _odin_linux_tls_layout
	test al, al
	jz .fail
	mov rsi, [rsp]                 ; Mapping size.
	mov eax, 9                     ; mmap
	xor edi, edi
	mov edx, 3                     ; PROT_READ | PROT_WRITE
	mov r10d, 0x22                 ; MAP_PRIVATE | MAP_ANONYMOUS
	mov r8, -1
	xor r9d, r9d
	syscall
	cmp rax, -4095
	jae .fail
	add rax, [rsp+16]              ; TP bias
	jc .fail
	mov rbx, [rsp+8]               ; TP alignment
	lea rdx, [rbx-1]
	add rax, rdx
	jc .fail
	neg rbx
	and rax, rbx
	mov r12, rax                   ; TP
	mov rdi, rax
	add rdi, [rsp+24]              ; Signed TLS block offset.
	mov rsi, [rsp+32]              ; Original .tdata image.
	mov rcx, [rsp+40]
	rep movsb
	mov [r12], r12                 ; %fs:0 contains the thread pointer.
	mov rax, [rel _odin_linux_stack_guard]
	mov [r12+0x28], rax            ; LLVM's stack-protector canary.
	mov eax, 158                   ; arch_prctl
	mov edi, 0x1002                ; ARCH_SET_FS
	mov rsi, r12
	syscall
	test rax, rax
	jnz .fail

.enter_odin:
	mov rdi, r13
	mov rsi, r14
	and rsp, -16
	call _start_odin
.fail:
	mov eax, 231                   ; exit_group, no runtime or TLS required
	mov edi, 127
	syscall
	ud2
