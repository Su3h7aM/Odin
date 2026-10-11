.text
.globl _odin_linux_clone
.type _odin_linux_clone, @function

# clone(2) callback interface. Only the parent returns to the caller.
_odin_linux_clone:
	andi a1, a1, -16
	addi a1, a1, -16
	sd a0, 0(a1)                    # fn
	sd a3, 8(a1)                    # arg
	mv a0, a2                      # flags
	mv a2, a4                      # parent_tid
	mv a3, a5                      # tls
	mv a4, a6                      # child_tid
	li a7, 220                      # clone
	ecall
	beqz a0, .Lchild
	ret
.Lchild:
	mv s0, zero
	ld t0, 0(sp)
	ld a0, 8(sp)
	addi sp, sp, 16
	jalr t0
	li a7, 93                       # exit, not exit_group
	ecall
	ebreak
.size _odin_linux_clone, .-_odin_linux_clone
.section .note.GNU-stack,"",@progbits
