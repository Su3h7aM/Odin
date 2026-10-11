#+build linux, freebsd, netbsd, openbsd
package runtime

// Base address of the kernel vDSO ELF image from AT_SYSINFO_EHDR, or zero
// when the kernel provided none. Captured once in init_auxv before package
// initialization; read-only afterwards, so readers need no locking. Public
// so owned Linux code outside runtime (core:sys/linux) can resolve vDSO
// symbols without re-reading the auxiliary vector or linking libc.
// See vdso(7): https://man7.org/linux/man-pages/man7/vdso.7.html
vdso_addr: uintptr
