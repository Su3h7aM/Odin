.text
.globl _odin_linux_tls_layout
.type _odin_linux_tls_layout, %function

// (Elf64_Phdr *header, Layout *out) -> bool. No TLS, context, or syscalls.
// Layout has six words: size, alignment, TP bias, signed block offset, image, filesz.
// Variant I block offset = 16 + ((vaddr-16) & (align-1)); a 16-byte TCB is at TP.
_odin_linux_tls_layout:
	ldr x9, [x0, #16]               // vaddr
	ldp x10, x11, [x0, #32]         // filesz, memsz
	ldr x12, [x0, #48]              // align
	cmp x10, x11
	b.hi .Lfail
	cmn x9, x10
	b.cs .Lfail
	cmp x12, #0
	csinc x12, x12, xzr, ne
	sub x13, x12, #1
	tst x12, x13
	b.ne .Lfail
	sub x14, x9, #16
	and x14, x14, x13
	add x14, x14, #16
	adds x15, x14, x11
	b.cs .Lfail
	cmp x12, #16
	mov x16, #16
	csel x12, x12, x16, hs
	sub x13, x12, #1
	adds x15, x15, x13
	b.cs .Lfail
	stp x15, x12, [x1]
	stp xzr, x14, [x1, #16]
	stp x9, x10, [x1, #32]
	mov x0, #1
	ret
.Lfail:
	mov x0, xzr
	ret
.size _odin_linux_tls_layout, .-_odin_linux_tls_layout
.section .note.GNU-stack,"",%progbits
