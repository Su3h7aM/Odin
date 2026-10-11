.globl __stack_chk_fail
.type __stack_chk_fail, %function
.section .note.GNU-stack, "", %progbits
.section .rodata
.Lmessage:
	.ascii "runtime: stack protector check failed\n"
.Lmessage_size = . - .Lmessage
.text

// No stack frame, TLS, or calls to protected code, even on a corrupted stack.
__stack_chk_fail:
	adrp x1, .Lmessage
	add x1, x1, :lo12:.Lmessage
	mov x2, #.Lmessage_size
.Lwrite:
	mov x0, #2                     // stderr
	mov x8, #64                    // write
	svc #0
	cmn x0, #4                     // EINTR
	b.eq .Lwrite
	cmp x0, #0
	b.le .Lexit
	add x1, x1, x0
	subs x2, x2, x0
	b.ne .Lwrite
.Lexit:
	mov x0, #134
	mov x8, #94                    // exit_group
	svc #0
	brk #0
