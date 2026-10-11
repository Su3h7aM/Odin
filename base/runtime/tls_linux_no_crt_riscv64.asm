.text
.globl _odin_linux_tls_layout
.type _odin_linux_tls_layout, @function

# (Elf64_Phdr *header, Layout *out) -> bool. No TLS, context, or syscalls.
# Layout has six words: size, alignment, TP bias, signed block offset, image, filesz.
# Variant I block offset = vaddr & (align-1); there is no TCB.
_odin_linux_tls_layout:
	ld t0, 16(a0)                   # vaddr
	ld t1, 32(a0)                   # filesz
	ld t2, 40(a0)                   # memsz
	ld t3, 48(a0)                   # align
	bltu t2, t1, .Lfail
	add t4, t0, t1
	bltu t4, t0, .Lfail
	bnez t3, .Lalignment
	li t3, 1
.Lalignment:
	addi t4, t3, -1
	and t5, t3, t4
	bnez t5, .Lfail
	and t5, t0, t4                  # block offset
	add t6, t5, t2
	bltu t6, t5, .Lfail
	add a2, t6, t4
	bltu a2, t6, .Lfail
	sd a2, 0(a1)
	sd t3, 8(a1)
	sd zero, 16(a1)
	sd t5, 24(a1)
	sd t0, 32(a1)
	sd t1, 40(a1)
	li a0, 1
	ret
.Lfail:
	li a0, 0
	ret
.size _odin_linux_tls_layout, .-_odin_linux_tls_layout
.section .note.GNU-stack,"",@progbits
