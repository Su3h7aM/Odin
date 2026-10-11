.globl __stack_chk_fail
.type __stack_chk_fail, @function
.section .note.GNU-stack, "", @progbits
.section .rodata
.Lmessage:
	.ascii "runtime: stack protector check failed\n"
.Lmessage_end:
.text

# No stack frame, TLS, or calls to protected code, even on a corrupted stack.
__stack_chk_fail:
	la a1, .Lmessage
	la a2, .Lmessage_end
	sub a2, a2, a1
.Lwrite:
	li a0, 2                       # stderr
	li a7, 64                      # write
	ecall
	li t0, -4                      # EINTR
	beq a0, t0, .Lwrite
	blez a0, .Lexit
	add a1, a1, a0
	sub a2, a2, a0
	bnez a2, .Lwrite
.Lexit:
	li a0, 134
	li a7, 94                      # exit_group
	ecall
	ebreak
