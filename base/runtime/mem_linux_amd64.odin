#+build linux amd64
package runtime

import "base:intrinsics"

// Memory kernels are shared by compiler-generated operations in both profiles.
// Standard C-name providers remain exclusive to noCRT.
when ODIN_NO_CRT {
	// LLVM can replace byte-scanning loops with a call to strlen.
	@(link_name="strlen", linkage="strong", require)
	strlen :: proc "c" (s: cstring) -> uintptr {
		return uintptr(cstring_len(s))
	}

	@(link_name="memset", linkage="strong", require)
	memset :: proc "c" (ptr: rawptr, val: i32, #any_int len: int) -> rawptr {
		return native_memset(ptr, u8(val), len)
	}

	@(link_name="bzero", linkage="strong", require)
	bzero :: proc "c" (ptr: rawptr, #any_int len: int) -> rawptr {
		if ptr != nil && len != 0 {
			p := ([^]byte)(ptr)
			for i := 0; i < len; i += 1 {
				p[i] = 0
			}
		}
		return ptr
	}

	@(link_name="memmove", linkage="strong", require)
	memmove :: proc "c" (dst, src: rawptr, #any_int len: int) -> rawptr {
		return native_memmove(dst, src, len)
	}

	@(link_name="memcpy", linkage="strong", require)
	memcpy :: proc "c" (dst, src: rawptr, #any_int len: int) -> rawptr {
		return native_memcpy(dst, src, len)
	}
}

// Large-fill helper as a language-level asm template, so this target needs
// no standalone assembly file or assembler invocation for it. The emitted
// object comes from LLVM codegen and carries the executable-stack marking
// centrally. Effects are explicit: volatile with a memory clobber, fixed
// rdi/rcx/rax use, DF cleared before rep stosb and left clear.
@(private="file")
_rep_memset :: asm(dst: rawptr, val: u8, len: int) -> (r: rawptr) [#volatile, #clobber memory] {
	mov r, dst
	mov %rdi, dst
	movzx %rax, val
	mov %rcx, len
	cld
	rep
	stosb
}

// Small fills use SSE2 stores; large fills use rep stosb.
@(private, optimization_mode="none")
native_memset_small :: proc "contextless" (ptr: rawptr, b: byte, len: int) {
	v: #simd[16]u8 = b
	p := ([^]byte)(ptr)
	n := len
	for n >= 64 {
		intrinsics.unaligned_store(cast(^#simd[16]u8)p, v)
		intrinsics.unaligned_store(cast(^#simd[16]u8)(uintptr(p) + 16), v)
		intrinsics.unaligned_store(cast(^#simd[16]u8)(uintptr(p) + 32), v)
		intrinsics.unaligned_store(cast(^#simd[16]u8)(uintptr(p) + 48), v)
		p = ([^]byte)(uintptr(p) + 64)
		n -= 64
	}
	for n >= 16 {
		intrinsics.unaligned_store(cast(^#simd[16]u8)p, v)
		p = ([^]byte)(uintptr(p) + 16)
		n -= 16
	}
	for n > 0 {
		p[0] = b
		p = ([^]byte)(uintptr(p) + 1)
		n -= 1
	}
}

@(private, require, optimization_mode="none")
native_memset :: proc "contextless" (ptr: rawptr, val: u8, len: int) -> rawptr {
	if ptr == nil || len <= 0 {
		return ptr
	}
	if len >= 1024 {
		return _rep_memset(ptr, u8(val), len)
	}
	native_memset_small(ptr, byte(val), len)
	return ptr
}

@(private, require, optimization_mode="none")
native_memmove :: proc "contextless" (dst, src: rawptr, len: int) -> rawptr {
	d, s := ([^]byte)(dst), ([^]byte)(src)
	if d == s || len == 0 {
		return dst
	}
	if d > s && uintptr(d)-uintptr(s) < uintptr(len) {
		// Backward copy for overlap. Three strictly descending phases
		// tile [dst, dst+len) exactly: top fragment bytes down to the
		// first u64-aligned boundary, whole u64 blocks, then bottom
		// fragment bytes. Block sources use explicit unaligned loads
		// so differing src/dst offsets stay valid, and each block is
		// fully loaded before it is stored, which is what makes
		// descending block order overlap-safe. The u64 loop only runs
		// while at least 8 bytes remain, so every access stays inside
		// its region.
		gap := uintptr(d) - uintptr(s)
		adw := (uintptr(d) + uintptr(len)) & ~uintptr(7)
		j := len
		for j > 0 && uintptr(d) + uintptr(j) > adw {
			j -= 1
			d[j] = s[j]
		}
		for j >= 8 {
			adw -= 8
			dw := ([^]u64)(adw)
			sw := ([^]u64)(adw - gap)
			dw[0] = intrinsics.unaligned_load(&sw[0])
			j -= 8
		}
		for j > 0 {
			j -= 1
			d[j] = s[j]
		}
		return dst
	}

	if s > d && uintptr(s)-uintptr(d) < uintptr(len) {
		// Forward overlap copies ascending, which is what memcpy does.
		return native_memcpy(dst, src, len)
	}
	return native_memcpy(dst, src, len)
}

// No rep movsb: the prototype matrix showed order-of-magnitude
// layout-dependent cliffs for it on the primary target, while 8-byte
// chunks held ~20 GB/s in every size/offset/layout measured. The
// destination is aligned with head bytes; the source is read with
// explicit unaligned loads. Forward overlap is safe ascending.
@(private, require, optimization_mode="none")
native_memcpy :: proc "contextless" (dst, src: rawptr, len: int) -> rawptr {
	d, s := ([^]byte)(dst), ([^]byte)(src)
	if d == s || len <= 0 {
		return dst
	}
	n := len
	for n > 0 && uintptr(d) & 7 != 0 {
		d[0] = s[0]
		d = ([^]byte)(uintptr(d) + 1)
		s = ([^]byte)(uintptr(s) + 1)
		n -= 1
	}
	dw := ([^]u64)(d)
	sw := ([^]u64)(s)
	for n >= 32 {
		dw[0] = intrinsics.unaligned_load(&sw[0])
		dw[1] = intrinsics.unaligned_load(&sw[1])
		dw[2] = intrinsics.unaligned_load(&sw[2])
		dw[3] = intrinsics.unaligned_load(&sw[3])
		dw = ([^]u64)(uintptr(dw) + 32)
		sw = ([^]u64)(uintptr(sw) + 32)
		n -= 32
	}
	for n >= 8 {
		dw[0] = intrinsics.unaligned_load(&sw[0])
		dw = ([^]u64)(uintptr(dw) + 8)
		sw = ([^]u64)(uintptr(sw) + 8)
		n -= 8
	}
	d = ([^]byte)(dw)
	s = ([^]byte)(sw)
	for n > 0 {
		d[0] = s[0]
		d = ([^]byte)(uintptr(d) + 1)
		s = ([^]byte)(uintptr(s) + 1)
		n -= 1
	}
	return dst
}

@(private, require, optimization_mode="none")
native_memmove_volatile :: proc "contextless" (dst, src: rawptr, len: int) -> rawptr {
	d, s := ([^]byte)(dst), ([^]byte)(src)
	if len <= 0 {
		return dst
	}
	if uintptr(d) > uintptr(s) && uintptr(d)-uintptr(s) < uintptr(len) {
		for i := len; i > 0; {
			i -= 1
			intrinsics.volatile_store(&d[i], intrinsics.volatile_load(&s[i]))
		}
	} else {
		for i := 0; i < len; i += 1 {
			intrinsics.volatile_store(&d[i], intrinsics.volatile_load(&s[i]))
		}
	}
	return dst
}

@(private, require, optimization_mode="none")
native_memset_volatile :: proc "contextless" (dst: rawptr, val: u8, len: int) -> rawptr {
	d := ([^]byte)(dst)
	for i := 0; i < len; i += 1 {
		intrinsics.volatile_store(&d[i], val)
	}
	return dst
}
