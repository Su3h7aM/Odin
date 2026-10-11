#+build linux amd64
#+no-instrumentation
package linux

import "base:runtime"
import "core:c"

// Owned kernel-vDSO fast path for clock reads.
//
// The kernel maps a small read-only ELF image, the vDSO, into every process
// and publishes its base address in the startup auxiliary vector under
// AT_SYSINFO_EHDR. Supported reads avoid entering the kernel. The image
// exports __vdso_clock_gettime, __vdso_clock_getres, and
// __vdso_gettimeofday, all under version LINUX_2.6. The C library resolves
// them for clock_gettime, clock_getres, and gettimeofday; the owned no-CRT
// path previously issued a raw system call on every read, paying a full
// kernel entry each time.
//
// Resolution happens once during startup initialization from the address the
// runtime captured out of the initial auxv: no libc, no dlopen, no per-call
// lookup, no syscalls. Anything the vDSO cannot serve (absent image,
// unrecognized layout, unknown symbol or version, a nonzero return) falls
// back to the corresponding raw system call, so results and errors match the
// mirror exactly. Other architectures keep the raw call until their vDSO is
// implemented the same way.
//
// [[ More; https://man7.org/linux/man-pages/man7/vdso.7.html ]]
// [[ More; https://man7.org/linux/man-pages/man2/clock_gettime.2.html ]]
// [[ Reference parser; https://github.com/torvalds/linux/blob/master/tools/testing/selftests/vDSO/parse_vdso.c ]]

// The vDSO writes the System V AMD64 ABI timespec: two 64-bit words. Pin the
// assumption at compile time; Time_Spec fields are uint, 64 bits on amd64.
#assert(size_of(Time_Spec) == 16 && offset_of(Time_Spec, time_sec) == 0 && offset_of(Time_Spec, time_nsec) == 8)

// The vDSO writes the System V AMD64 ABI timeval the same way: two 64-bit
// words. Time_Val fields are int, 64 bits on amd64.
#assert(size_of(Time_Val) == 16 && offset_of(Time_Val, seconds) == 0 && offset_of(Time_Val, microseconds) == 8)

// Symbol and version requested, per the x86-64 kernel vDSO version script.
// arch/x86/entry/vdso/vdso64/vdso64.lds.S exports these under LINUX_2.6, which
// pins the ABI the kernel guarantees for this signature.
@(private="file")
_VDSO_CLOCK_GETTIME_NAME    :: "__vdso_clock_gettime"
@(private="file")
_VDSO_CLOCK_GETTIME_VERSION :: "LINUX_2.6"
@(private="file")
_VDSO_CLOCK_GETRES_NAME    :: "__vdso_clock_getres"
@(private="file")
_VDSO_CLOCK_GETRES_VERSION :: "LINUX_2.6"
@(private="file")
_VDSO_GETTIMEOFDAY_NAME    :: "__vdso_gettimeofday"
@(private="file")
_VDSO_GETTIMEOFDAY_VERSION :: "LINUX_2.6"

// ELF tags, types, and flags consumed below, per the System V ABI.
@(private="file")
_VDSO_ELFCLASS64   :: 2
@(private="file")
_VDSO_PT_LOAD      :: 1
@(private="file")
_VDSO_PT_DYNAMIC   :: 2
@(private="file")
_VDSO_DT_NULL      :: 0
@(private="file")
_VDSO_DT_HASH      :: 4
@(private="file")
_VDSO_DT_STRTAB    :: 5
@(private="file")
_VDSO_DT_SYMTAB    :: 6
@(private="file")
_VDSO_DT_STRSZ     :: 10
@(private="file")
_VDSO_DT_VERSYM    :: 0x6ffffff0
@(private="file")
_VDSO_DT_VERDEF    :: 0x6ffffffc
@(private="file")
_VDSO_STT_FUNC     :: 2
@(private="file")
_VDSO_STB_GLOBAL   :: 1
@(private="file")
_VDSO_STB_WEAK     :: 2
@(private="file")
_VDSO_SHN_UNDEF    :: 0
@(private="file")
_VDSO_VER_FLG_BASE :: 1

// Resolution walks kernel-provided tables; the caps bound how far a corrupt
// image can take the walk before resolution gives up and callers stay on the
// raw system call. Genuine images stop far earlier: 6 program headers, about
// a dozen dynamic entries, 2 version definitions, 17 hash chains.
@(private="file")
_VDSO_PHDR_MAX   :: 16
@(private="file")
_VDSO_DYN_MAX    :: 32
@(private="file")
_VDSO_VERDEF_MAX :: 8
@(private="file")
_VDSO_TABLE_MAX  :: 1024

// ELF64 header. Only the fields symbol resolution reads are modeled.
@(private="file")
_Vdso_Ehdr :: struct {
	magic:     [4]u8, // 0x7f, 'E', 'L', 'F'
	class:     u8,    // 2 selects the 64-bit layout below
	data:      u8,
	version:   u8,
	os_abi:    u8,
	abi_ver:   u8,
	pad:       [7]u8,
	etype:     u16,
	machine:   u16,
	e_version: u32,
	entry:     u64,
	phoff:     u64,
	shoff:     u64,
	flags:     u32,
	ehsize:    u16,
	phentsize: u16,
	phnum:     u16,
	shentsize: u16,
	shnum:     u16,
	shstrndx:  u16,
}

@(private="file")
_Vdso_Phdr :: struct {
	ptype:   u32,
	pflags:  u32,
	poffset: u64,
	pvaddr:  u64,
	ppaddr:  u64,
	pfilesz: u64,
	pmemsz:  u64,
	palign:  u64,
}

@(private="file")
_Vdso_Dyn :: struct {
	tag: i64,
	val: u64,
}

@(private="file")
_Vdso_Sym :: struct {
	name:  u32,
	info:  u8,
	other: u8,
	shndx: u16,
	value: u64,
	size:  u64,
}

@(private="file")
_Vdso_Verdef :: struct {
	version: u16,
	flags:   u16,
	ndx:     u16,
	cnt:     u16,
	hash:    u32,
	aux:     u32,
	next:    u32,
}

@(private="file")
_Vdso_Verdaux :: struct {
	name: u32,
	next: u32,
}

// Resolved vDSO clock_gettime: C ABI, kernel timespec, zero on success.
// Nil when the kernel provided no usable symbol. Written once during startup
// initialization; read-only afterwards, so callers need no locking.
@(private)
_vdso_clock_gettime: proc "c" (clock: i32, ts: ^Time_Spec) -> c.int
// Resolved vDSO clock_getres: C ABI, kernel timespec, zero on success.
// Nil when the kernel provided no usable symbol.
@(private)
_vdso_clock_getres: proc "c" (clock: i32, res: ^Time_Spec) -> c.int
// Resolved vDSO gettimeofday: C ABI, kernel timeval, zero on success.
// The timezone argument is obsolete; callers pass nil. Nil when the kernel
// provided no usable symbol.
@(private)
_vdso_gettimeofday: proc "c" (tv: ^Time_Val, tz: rawptr) -> c.int

// The System V ELF hash over a name, as the kernel's reference parser
// computes it for both symbol names and version strings.
@(private="file")
_vdso_elf_hash :: proc "contextless" (s: string) -> u32 {
	h: u32 = 0
	for i in 0 ..< len(s) {
		h = (h << 4) + u32(s[i])
		g := h & 0xf000_0000
		if g != 0 {
			h ~= g >> 24
		}
		h &= ~g
	}
	return h
}

// Compares a string against the NUL-terminated name at strtab+off, staying
// inside the string table bounds.
@(private="file")
_vdso_str_eq :: proc "contextless" (strtab: [^]u8, strsz: u64, off: u32, s: string) -> bool {
	if u64(off) >= strsz || u64(len(s)) + 1 > strsz - u64(off) {
		return false
	}
	for i in 0 ..< len(s) {
		if strtab[off + u32(i)] != s[i] {
			return false
		}
	}
	return strtab[off + u32(len(s))] == 0
}

// Checks the symbol's version definition against the requested version, the
// way the kernel's reference parser does: skip the base definition, match
// the index with the hidden bit masked out, then match the definition's
// hash and name.
@(private="file")
_vdso_match_version :: proc "contextless" (verdef: ^_Vdso_Verdef, strtab: [^]u8, strsz: u64, ver: u16, name: string, hash: u32) -> bool {
	v := ver & 0x7fff
	def := verdef
	found := false
	for _ in 0 ..< _VDSO_VERDEF_MAX {
		if def == nil {
			return false
		}
		if (def.flags & _VDSO_VER_FLG_BASE) == 0 && (def.ndx & 0x7fff) == v {
			found = true
			break
		}
		if def.next == 0 {
			return false
		}
		def = (^_Vdso_Verdef)(rawptr(uintptr(rawptr(def)) + uintptr(def.next)))
	}
	if !found {
		return false
	}
	// The auxiliary record follows its definition; bound the offset so a
	// corrupt table cannot aim the read at the rest of the address space.
	// The name itself stays inside the string table via _vdso_str_eq.
	if def.aux > 256 {
		return false
	}
	aux := (^_Vdso_Verdaux)(rawptr(uintptr(rawptr(def)) + uintptr(def.aux)))
	return def.hash == hash && _vdso_str_eq(strtab, strsz, aux.name, name)
}

// Accepts only a defined global or weak function with the right name and
// version. A zero address never resolves: calling the image base would run
// the ELF header as code.
@(private="file")
_vdso_sym_matches :: proc "contextless" (sym: ^_Vdso_Sym, sym_idx: u32, strtab: [^]u8, strsz: u64, versym: ^u16, verdef: ^_Vdso_Verdef, name: string, version: string, ver_hash: u32) -> bool {
	if sym.info & 0x0f != _VDSO_STT_FUNC {
		return false
	}
	bind := sym.info >> 4
	if bind != _VDSO_STB_GLOBAL && bind != _VDSO_STB_WEAK {
		return false
	}
	if sym.shndx == _VDSO_SHN_UNDEF || sym.value == 0 {
		return false
	}
	if !_vdso_str_eq(strtab, strsz, sym.name, name) {
		return false
	}
	if versym != nil {
		if !_vdso_match_version(verdef, strtab, strsz, ([^]u16)(versym)[sym_idx], version, ver_hash) {
			return false
		}
	}
	return true
}

// Resolves one versioned function symbol out of the vDSO image at base.
// Returns nil for any unusable image, table, or lookup: callers fall back
// to the raw system call. Mirrors the kernel's reference parser, plus table
// bounds so a corrupt image fails closed instead of over-reading.
@(private="file")
_vdso_resolve :: proc "contextless" (base: uintptr, name: string, version: string) -> rawptr {
	hdr := (^_Vdso_Ehdr)(rawptr(base))
	if hdr.magic[0] != 0x7f || hdr.magic[1] != 'E' || hdr.magic[2] != 'L' || hdr.magic[3] != 'F' {
		return nil
	}
	if hdr.class != _VDSO_ELFCLASS64 || hdr.version != 1 {
		return nil
	}
	if int(hdr.phnum) > _VDSO_PHDR_MAX {
		return nil
	}

	load_bias: uintptr = 0
	found_load := false
	dyn: ^_Vdso_Dyn = nil
	for i in 0 ..< int(hdr.phnum) {
		ph := (^_Vdso_Phdr)(rawptr(base + uintptr(hdr.phoff) + uintptr(i) * uintptr(size_of(_Vdso_Phdr))))
		switch ph.ptype {
		case _VDSO_PT_LOAD:
			if !found_load {
				found_load = true
				load_bias = base + uintptr(ph.poffset) - uintptr(ph.pvaddr)
			}
		case _VDSO_PT_DYNAMIC:
			dyn = (^_Vdso_Dyn)(rawptr(base + uintptr(ph.poffset)))
		}
	}
	if !found_load || dyn == nil {
		return nil
	}

	strtab: [^]u8 = nil
	strsz: u64 = 0
	symtab: ^_Vdso_Sym = nil
	hash: ^u32 = nil
	versym: ^u16 = nil
	verdef: ^_Vdso_Verdef = nil
	d := dyn
	done := false
	for _ in 0 ..< _VDSO_DYN_MAX {
		if done {
			break
		}
		switch d.tag {
		case _VDSO_DT_NULL:
			done = true
		case _VDSO_DT_STRTAB:
			strtab = ([^]u8)(rawptr(load_bias + uintptr(d.val)))
		case _VDSO_DT_STRSZ:
			strsz = d.val
		case _VDSO_DT_SYMTAB:
			symtab = (^_Vdso_Sym)(rawptr(load_bias + uintptr(d.val)))
		case _VDSO_DT_HASH:
			hash = (^u32)(rawptr(load_bias + uintptr(d.val)))
		case _VDSO_DT_VERSYM:
			versym = (^u16)(rawptr(load_bias + uintptr(d.val)))
		case _VDSO_DT_VERDEF:
			verdef = (^_Vdso_Verdef)(rawptr(load_bias + uintptr(d.val)))
		}
		if !done {
			d = (^_Vdso_Dyn)(rawptr(uintptr(rawptr(d)) + uintptr(size_of(_Vdso_Dyn))))
		}
	}
	if !done || strtab == nil || strsz == 0 || symtab == nil || hash == nil {
		return nil
	}
	if versym == nil || verdef == nil {
		return nil
	}

	h := ([^]u32)(hash)
	nbucket := h[0]
	nchain := h[1]
	if nbucket == 0 || nbucket > _VDSO_TABLE_MAX || nchain > _VDSO_TABLE_MAX {
		return nil
	}
	bucket := ([^]u32)(rawptr(uintptr(rawptr(hash)) + 8))
	chain := ([^]u32)(rawptr(uintptr(rawptr(hash)) + 8 + uintptr(nbucket) * 4))
	syms := ([^]_Vdso_Sym)(symtab)

	ver_hash := _vdso_elf_hash(version)
	idx := bucket[_vdso_elf_hash(name) % nbucket]
	// At most nchain + 1 steps: a longer walk revisits an entry, so the
	// table is corrupt and resolution fails closed.
	for _ in 0 ..< int(nchain) + 1 {
		if idx == 0 {
			return nil
		}
		if idx >= nchain {
			return nil
		}
		if _vdso_sym_matches(&syms[idx], idx, strtab, strsz, versym, verdef, name, version, ver_hash) {
			return rawptr(load_bias + uintptr(syms[idx].value))
		}
		idx = chain[idx]
	}
	return nil
}

// Runs before main, after the runtime captured the auxiliary vector, and
// resolves the clock symbols once. A symbol the image does not provide
// keeps its cached pointer nil and those reads stay on the raw system call.
@(init)
_vdso_startup_resolve :: proc "contextless" () {
	base := runtime.vdso_addr
	if base == 0 {
		return
	}
	addr := _vdso_resolve(base, _VDSO_CLOCK_GETTIME_NAME, _VDSO_CLOCK_GETTIME_VERSION)
	if addr != nil {
		_vdso_clock_gettime = cast(proc "c" (clock: i32, ts: ^Time_Spec) -> c.int)(addr)
	}
	res := _vdso_resolve(base, _VDSO_CLOCK_GETRES_NAME, _VDSO_CLOCK_GETRES_VERSION)
	if res != nil {
		_vdso_clock_getres = cast(proc "c" (clock: i32, res: ^Time_Spec) -> c.int)(res)
	}
	tod := _vdso_resolve(base, _VDSO_GETTIMEOFDAY_NAME, _VDSO_GETTIMEOFDAY_VERSION)
	if tod != nil {
		_vdso_gettimeofday = cast(proc "c" (tv: ^Time_Val, tz: rawptr) -> c.int)(tod)
	}
}

/*
Reads the specified clock, serving the read from the kernel vDSO in userspace
when startup resolved it, and issuing the raw clock_gettime system call
otherwise.

Returns the timestamp and .NONE on success, or the raw call's error. A
nonzero vDSO return also takes the system call path, so clock IDs the vDSO
does not accelerate and every error contract match clock_gettime exactly.
Callable from any thread once startup initialization has run; before that
the cached pointer is nil and the call is a plain system call.

Available since Linux 2.6 on amd64, wherever the kernel maps the vDSO.
*/
clock_gettime_fast :: proc "contextless" (clock: Clock_Id) -> (ts: Time_Spec, err: Errno) {
	if _vdso_clock_gettime != nil {
		if _vdso_clock_gettime(i32(clock), &ts) == 0 {
			return ts, .NONE
		}
	}
	return clock_gettime(clock)
}

/*
Reads the resolution of the specified clock, serving the read from the
kernel vDSO in userspace when startup resolved it, and issuing the raw
clock_getres system call otherwise.

Returns the resolution and .NONE on success, or the raw call's error. A
nonzero vDSO return also takes the system call path, so clock IDs the vDSO
does not accelerate and every error contract match clock_getres exactly.
Callable from any thread once startup initialization has run; before that
the cached pointer is nil and the call is a plain system call.

Kernel vDSO acceleration is available on amd64 since Linux 5.3. Older kernels
and missing symbols use the raw system call.
*/
clock_getres_fast :: proc "contextless" (clock: Clock_Id) -> (res: Time_Spec, err: Errno) {
	if _vdso_clock_getres != nil {
		if _vdso_clock_getres(i32(clock), &res) == 0 {
			return res, .NONE
		}
	}
	return clock_getres(clock)
}

/*
Reads the current time, serving the read from the kernel vDSO in userspace
when startup resolved it, and issuing the raw gettimeofday system call
otherwise.

Returns .NONE on success, or the raw call's error. A nonzero vDSO return
also takes the system call path. A nil tv is valid and succeeds without
storing, matching the system call; the timezone argument stays nil,
obsolete and ignored. Callable from any thread once startup initialization
has run; before that the cached pointer is nil and the call is a plain
system call.

Available since Linux 2.6 on amd64, wherever the kernel maps the vDSO.
*/
gettimeofday_fast :: proc "contextless" (tv: ^Time_Val) -> (Errno) {
	if _vdso_gettimeofday != nil {
		if _vdso_gettimeofday(tv, nil) == 0 {
			return .NONE
		}
	}
	return gettimeofday(tv)
}
