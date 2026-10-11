.text

.globl _start

// Entry point for programs that specify -no-crt option on Linux riscv64.
// The kernel starts the program with the stack pointer at argc, followed by the
// argv pointers, a null, the envp pointers, a null, and then the auxiliary vector.
// When the executable has PT_TLS and no PT_INTERP, the main thread's TLS block is
// installed before entering Odin: RISC-V psABI TLS variant I with no TCB, tp points at
// the block. Static non-PIE only: static PIE needs self-relocation, which this stub
// does not do.
_start:
	mv s0, zero                       # mark this as the outermost frame
	mv ra, zero
	ld s1, 0(sp)                      # argc
	addi s2, sp, 8                    # argv
	slli t0, s1, 3
	add t0, s2, t0
	addi t0, t0, 8                    # envp
1:	ld t1, 0(t0)
	addi t0, t0, 8
	bnez t1, 1b                       # t0 = auxv

	mv t2, zero                       # AT_PHDR
	mv t3, zero                       # AT_PHENT
	mv t4, zero                       # AT_PHNUM
	li a2, 3
	li a3, 4
	li a4, 5
	mv a5, zero                       # AT_RANDOM
	li a6, 25
2:	ld t1, 0(t0)
	ld t5, 8(t0)
	addi t0, t0, 16
	beqz t1, 3f
	bne t1, a2, 21f
	mv t2, t5
21:	bne t1, a3, 22f
	mv t3, t5
22:	bne t1, a4, 23f
	mv t4, t5
23:	bne t1, a6, 2b
	mv a5, t5
	j 2b

3:	beqz a5, .Lfail
	ld t0, 0(a5)
	andi t0, t0, -256                 # Terminator canary, zero low byte.
	la t1, __stack_chk_guard
	sd t0, 0(t1)
	beqz t2, .Lenter_odin
	li a0, 56                         # sizeof(Elf64_Phdr)
	bne t3, a0, .Lfail
	mv a1, zero                       # PT_TLS header
	li a3, 7
4:	beqz t4, 5f
	lw a0, 0(t2)
	beq a0, a2, .Lenter_odin          # PT_INTERP: the dynamic loader already installed TLS
	bne a0, a3, 6f                    # PT_TLS
	bnez a1, .Lfail
	mv a1, t2
6:	add a0, t2, t3
	bltu a0, t2, .Lfail
	mv t2, a0
	addi t4, t4, -1
	j 4b

5:	beqz a1, .Lenter_odin
	la t0, _odin_linux_tls_header
	sd a1, 0(t0)
	addi sp, sp, -48                # Shared TLS layout, six words.
	mv a0, a1
	mv a1, sp
	call _odin_linux_tls_layout
	beqz a0, .Lfail
	ld a1, 0(sp)                    # Mapping size.
	beqz a1, .Lenter_odin
	mv a0, zero
	li a2, 3                        # PROT_READ | PROT_WRITE
	li a3, 0x22                     # MAP_PRIVATE | MAP_ANONYMOUS
	li a4, -1
	mv a5, zero
	li a7, 222                      # mmap
	ecall
	li t0, -4095
	bgeu a0, t0, .Lfail
	ld t0, 8(sp)                    # Alignment.
	ld t1, 16(sp)                   # TP bias.
	add a0, a0, t1
	addi t1, t0, -1
	add a0, a0, t1
	neg t0, t0
	and a0, a0, t0                  # TP
	ld t0, 24(sp)
	add t1, a0, t0                  # TLS block.
	ld s3, 32(sp)                   # Original .tdata image.
	ld s4, 40(sp)                   # filesz.
8:	beqz s4, 9f
	lbu t2, 0(s3)
	sb t2, 0(t1)
	addi s3, s3, 1
	addi t1, t1, 1
	addi s4, s4, -1
	j 8b
9:	mv tp, a0

.Lenter_odin:
	mv a0, s1
	mv a1, s2
	andi sp, sp, -16                  # the stack must be 16 byte aligned
	call _start_odin
.Lfail:
	li a0, 127
	li a7, 94                         # exit_group, no runtime or TLS required
	ecall
	ebreak
