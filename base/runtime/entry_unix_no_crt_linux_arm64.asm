.text

.globl _start

// Entry point for programs that specify -no-crt option on Linux arm64.
// The kernel starts the program with the stack pointer at argc, followed by the
// argv pointers, a null, the envp pointers, a null, and then the auxiliary vector.
// When the executable has PT_TLS and no PT_INTERP, the main thread's TLS block is
// installed before entering Odin: AAELF64 TLS variant I, a 16-byte TCB at TP and the
// block after it. Static non-PIE only: static PIE needs self-relocation, which this
// stub does not do.
_start:
	mov x29, xzr                      // mark this as the outermost frame
	mov x30, xzr
	ldr x19, [sp]                     // argc
	add x20, sp, #8                   // argv
	add x9, x20, x19, lsl #3
	add x9, x9, #8                    // envp
1:	ldr x10, [x9], #8
	cbnz x10, 1b                      // x9 = auxv

	mov x11, xzr                      // AT_PHDR
	mov x12, xzr                      // AT_PHENT
	mov x13, xzr                      // AT_PHNUM
	mov x16, xzr                      // AT_RANDOM
2:	ldp x10, x14, [x9], #16
	cbz x10, 3f
	cmp x10, #3
	csel x11, x14, x11, eq
	cmp x10, #4
	csel x12, x14, x12, eq
	cmp x10, #5
	csel x13, x14, x13, eq
	cmp x10, #25                      // AT_RANDOM points to 16 random bytes.
	csel x16, x14, x16, eq
	b 2b

3:	cbz x16, .Lfail
	ldr x14, [x16]
	and x14, x14, #0xffffffffffffff00  // Terminator canary, zero low byte.
	adrp x9, __stack_chk_guard
	str x14, [x9, :lo12:__stack_chk_guard]
	cbz x11, .Lenter_odin
	cmp x12, #56                      // sizeof(Elf64_Phdr)
	b.ne .Lfail
	mov x15, xzr                      // PT_TLS header
4:	cbz x13, 5f
	ldr w10, [x11]
	cmp w10, #3                       // PT_INTERP: the dynamic loader already installed TLS
	b.eq .Lenter_odin
	cmp w10, #7                       // PT_TLS
	b.ne 6f
	cbnz x15, .Lfail
	mov x15, x11
6:	adds x11, x11, x12
	b.cs .Lfail
	sub x13, x13, #1
	b 4b

5:	cbz x15, .Lenter_odin
	adrp x9, _odin_linux_tls_header
	str x15, [x9, :lo12:_odin_linux_tls_header]
	sub sp, sp, #48                 // Shared TLS layout, six words.
	mov x0, x15
	mov x1, sp
	bl _odin_linux_tls_layout
	cbz x0, .Lfail
	ldr x1, [sp]                    // Mapping size.
	mov x0, xzr
	mov x2, #3                      // PROT_READ | PROT_WRITE
	mov x3, #0x22                   // MAP_PRIVATE | MAP_ANONYMOUS
	mov x4, #-1
	mov x5, xzr
	mov x8, #222                    // mmap
	svc #0
	cmn x0, #4095
	b.hs .Lfail
	ldp x9, x10, [sp, #8]           // Alignment, TP bias.
	add x0, x0, x10
	sub x10, x9, #1
	add x0, x0, x10
	neg x9, x9
	and x0, x0, x9                  // TP
	ldr x10, [sp, #24]
	add x10, x0, x10                // TLS block.
	ldp x21, x22, [sp, #32]         // Original .tdata image, filesz.
7:	cbz x22, 8f
	ldrb w11, [x21], #1
	strb w11, [x10], #1
	sub x22, x22, #1
	b 7b
8:	msr tpidr_el0, x0

.Lenter_odin:
	mov x0, x19
	mov x1, x20
	mov x9, sp
	and x9, x9, #0xfffffffffffffff0   // the stack must be 16 byte aligned
	mov sp, x9
	bl _start_odin
.Lfail:
	mov x0, #127
	mov x8, #94                       // exit_group, no runtime or TLS required
	svc #0
	brk #0
