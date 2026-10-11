.text
.globl _odin_linux_clone
.type _odin_linux_clone, %function

// clone(2) callback interface. Only the parent returns to the caller.
_odin_linux_clone:
	and x1, x1, #0xfffffffffffffff0
	sub x1, x1, #16
	stp x0, x3, [x1]                // fn, arg
	mov x0, x2                      // flags
	mov x2, x4                      // parent_tid
	mov x3, x5                      // tls
	mov x4, x6                      // child_tid
	mov x8, #220                    // clone
	svc #0
	cbz x0, .Lchild
	ret
.Lchild:
	mov x29, xzr
	ldp x9, x0, [sp], #16
	blr x9
	mov x8, #93                     // exit, not exit_group
	svc #0
	brk #0
.size _odin_linux_clone, .-_odin_linux_clone
.section .note.GNU-stack,"",%progbits
