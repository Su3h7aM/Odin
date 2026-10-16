#+build linux amd64
package runtime

import "base:intrinsics"

// Memory kernels for Linux amd64. Compiler-generated copies, moves, and fills call the
// package-private native_* entries. The C-name wrappers exist only without the C runtime.
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
		return native_memset(ptr, 0, len)
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

NATIVE_MEMORY_DISPATCH_MIN :: 256

// Capability word: 0 unresolved, bit 0 published, bit 1 AVX2 usable.
NATIVE_MEMORY_READY       :: u32(1)
NATIVE_MEMORY_AVX2_USABLE :: u32(2)

@(private)
native_memory_capabilities: u32

@(private)
Vec16 :: #simd[16]u8
@(private)
Vec32 :: #simd[32]u8

@(private)
native_memory_probe :: #force_no_inline proc "contextless" () -> u32 {
	max_leaf, _, _, _ := intrinsics.x86_cpuid(0, 0)
	if max_leaf < 7 {
		return NATIVE_MEMORY_READY
	}
	_, _, ecx1, _ := intrinsics.x86_cpuid(1, 0)
	XSAVE_OSXSAVE_AVX :: u32(1) << 26 | u32(1) << 27 | u32(1) << 28
	if (ecx1 & XSAVE_OSXSAVE_AVX) != XSAVE_OSXSAVE_AVX {
		return NATIVE_MEMORY_READY
	}
	xcr0, _ := intrinsics.x86_xgetbv(0)
	if (xcr0 & 6) != 6 {
		return NATIVE_MEMORY_READY
	}
	_, ebx7, _, _ := intrinsics.x86_cpuid(7, 0)
	if (ebx7 & (u32(1) << 5)) == 0 {
		return NATIVE_MEMORY_READY
	}
	return NATIVE_MEMORY_READY | NATIVE_MEMORY_AVX2_USABLE
}

@(private)
native_memory_avx2_usable :: #force_inline proc "contextless" () -> bool {
	caps := intrinsics.atomic_load_explicit(&native_memory_capabilities, .Acquire)
	if caps == 0 {
		probed := native_memory_probe()
		old, ok := intrinsics.atomic_compare_exchange_strong_explicit(&native_memory_capabilities, 0, probed, .Acq_Rel, .Acquire)
		caps = probed
		if !ok {
			caps = old
		}
	}
	return (caps & NATIVE_MEMORY_AVX2_USABLE) != 0
}

@(private)
at :: #force_inline proc "contextless" (p: rawptr, i: int) -> rawptr {
	return rawptr(uintptr(p) + uintptr(i))
}

@(private)
ldu :: #force_inline proc "contextless" ($T: typeid, p: rawptr) -> T {
	return intrinsics.unaligned_load((^T)(p))
}

@(private)
stu :: #force_inline proc "contextless" (p: rawptr, v: $T) {
	intrinsics.unaligned_store((^T)(p), v)
}

@(private)
splat :: #force_inline proc "contextless" ($V: typeid, v: u8) -> V {
	x: V = ---
	#unroll for k in 0 ..< int(size_of(V)) {
		x = intrinsics.simd_replace(x, uint(k), v)
	}
	return x
}

// n < 32. All loads happen before stores.
@(private)
move_small :: #force_inline proc "contextless" (d, s: rawptr, n: int) {
	switch {
	case n == 0:
	case n == 1:
		stu(d, ldu(u8, s))
	case n < 4:
		a, b := ldu(u16, s), ldu(u8, at(s, n - 1))
		stu(d, a)
		stu(at(d, n - 1), b)
	case n < 8:
		a, b := ldu(u32, s), ldu(u32, at(s, n - 4))
		stu(d, a)
		stu(at(d, n - 4), b)
	case n < 16:
		a, b := ldu(u64, s), ldu(u64, at(s, n - 8))
		stu(d, a)
		stu(at(d, n - 8), b)
	case:
		a, b := ldu(Vec16, s), ldu(Vec16, at(s, n - 16))
		stu(d, a)
		stu(at(d, n - 16), b)
	}
}

// Head and tail with K vectors per side. Needs n >= K*vb. All loads happen before stores.
@(private)
ht :: #force_inline proc "contextless" ($V: typeid, $K: int, d, s: rawptr, n: int) {
	vb := int(size_of(V))
	h, t: [K]V = ---, ---
	#unroll for k in 0 ..< K {
		h[k] = ldu(V, at(s, k * vb))
		t[k] = ldu(V, at(s, n - K * vb + k * vb))
	}
	#unroll for k in 0 ..< K {
		stu(at(d, k * vb), h[k])
		stu(at(d, n - K * vb + k * vb), t[k])
	}
}

// Forward bulk for dst < src or disjoint. Head and tail are preloaded and stored last.
@(private)
bulk_fwd :: #force_inline proc "contextless" ($V: typeid, $N: int, d, s: rawptr, n: int) {
	vb := int(size_of(V))
	blk := N * vb
	h, t: [N]V = ---, ---
	#unroll for k in 0 ..< N {
		h[k] = ldu(V, at(s, k * vb))
		t[k] = ldu(V, at(s, n - blk + k * vb))
	}
	i := int((uintptr(vb) - uintptr(d)) & uintptr(vb - 1))
	for i + blk <= n {
		c: [N]V = ---
		#unroll for k in 0 ..< N {
			c[k] = ldu(V, at(s, i + k * vb))
		}
		#unroll for k in 0 ..< N {
			stu(at(d, i + k * vb), c[k])
		}
		i += blk
	}
	#unroll for k in 0 ..< N {
		stu(at(d, k * vb), h[k])
		stu(at(d, n - blk + k * vb), t[k])
	}
}

// Backward bulk for overlapping dst > src. Blocks descend from an aligned end.
@(private)
bulk_back :: #force_inline proc "contextless" ($V: typeid, $N: int, d, s: rawptr, n: int) {
	vb := int(size_of(V))
	blk := N * vb
	h, t: [N]V = ---, ---
	#unroll for k in 0 ..< N {
		h[k] = ldu(V, at(s, k * vb))
		t[k] = ldu(V, at(s, n - blk + k * vb))
	}
	e := n - int((uintptr(d) + uintptr(n)) & uintptr(vb - 1))
	for e >= blk {
		c: [N]V = ---
		#unroll for k in 0 ..< N {
			c[k] = ldu(V, at(s, e - blk + k * vb))
		}
		#unroll for k in 0 ..< N {
			stu(at(d, e - blk + k * vb), c[k])
		}
		e -= blk
	}
	#unroll for k in 0 ..< N {
		stu(at(d, k * vb), h[k])
		stu(at(d, n - blk + k * vb), t[k])
	}
}

@(private)
bulk_move :: #force_inline proc "contextless" ($V: typeid, $N: int, d, s: rawptr, n: int) {
	if uintptr(d) > uintptr(s) && uintptr(d) - uintptr(s) < uintptr(n) {
		bulk_back(V, N, d, s, n)
	} else {
		bulk_fwd(V, N, d, s, n)
	}
}

// n < 32. Stores only; overlapping head/tail stores are intended.
@(private)
native_memset_small :: #force_inline proc "contextless" (d: rawptr, v: u8, n: int) {
	switch {
	case n == 0:
	case n == 1:
		stu(d, v)
	case n < 4:
		stu(d, u16(v) * 0x0101)
		stu(at(d, n - 1), v)
	case n < 8:
		w := u32(v) * 0x01010101
		stu(d, w)
		stu(at(d, n - 4), w)
	case n < 16:
		w := u64(v) * 0x0101010101010101
		stu(d, w)
		stu(at(d, n - 8), w)
	case:
		x := splat(Vec16, v)
		stu(d, x)
		stu(at(d, n - 16), x)
	}
}

@(private)
fill_ht :: #force_inline proc "contextless" ($V: typeid, $K: int, d: rawptr, x: V, n: int) {
	vb := int(size_of(V))
	#unroll for k in 0 ..< K {
		stu(at(d, k * vb), x)
		stu(at(d, n - K * vb + k * vb), x)
	}
}

@(private)
fill_bulk :: #force_inline proc "contextless" ($V: typeid, $N: int, d: rawptr, v: u8, n: int) {
	vb := int(size_of(V))
	blk := N * vb
	x := splat(V, v)
	#unroll for k in 0 ..< N {
		stu(at(d, k * vb), x)
	}
	i := int((uintptr(vb) - uintptr(d)) & uintptr(vb - 1))
	for i + blk <= n {
		#unroll for k in 0 ..< N {
			stu(at(d, i + k * vb), x)
		}
		i += blk
	}
	#unroll for k in 0 ..< N {
		stu(at(d, n - blk + k * vb), x)
	}
}

@(private)
copy_sse :: #force_inline proc "contextless" (d, s: rawptr, n: int) {
	switch {
	case n < 32: move_small(d, s, n)
	case n < 64: ht(Vec16, 2, d, s, n)
	case n < 128: ht(Vec16, 4, d, s, n)
	case n < 256: ht(Vec16, 8, d, s, n)
	case: bulk_move(Vec16, 4, d, s, n)
	}
}

@(private)
native_memcpy_sse2 :: #force_no_inline proc "contextless" (dst, src: rawptr, len: int) {
	copy_sse(dst, src, len)
}

@(private)
native_memmove_sse2 :: #force_no_inline proc "contextless" (dst, src: rawptr, len: int) {
	copy_sse(dst, src, len)
}

@(private, enable_target_feature = "avx2,-slow-unaligned-mem-32")
native_memcpy_avx2 :: #force_no_inline proc "contextless" (dst, src: rawptr, len: int) {
	bulk_move(Vec32, 2, dst, src, len)
}

@(private, enable_target_feature = "avx2,-slow-unaligned-mem-32")
native_memmove_avx2 :: #force_no_inline proc "contextless" (dst, src: rawptr, len: int) {
	bulk_move(Vec32, 2, dst, src, len)
}

@(private)
native_memset_sse2 :: #force_no_inline proc "contextless" (d: rawptr, v: u8, n: int) {
	if n < 32 {
		native_memset_small(d, v, n)
		return
	}
	x := splat(Vec16, v)
	switch {
	case n < 64: fill_ht(Vec16, 2, d, x, n)
	case n < 128: fill_ht(Vec16, 4, d, x, n)
	case n < 256: fill_ht(Vec16, 8, d, x, n)
	case: fill_bulk(Vec16, 4, d, v, n)
	}
}

@(private, enable_target_feature = "avx2,-slow-unaligned-mem-32")
native_memset_avx2 :: #force_no_inline proc "contextless" (d: rawptr, v: u8, n: int) {
	fill_bulk(Vec32, 2, d, v, n)
}

@(private, require)
native_memcpy :: proc "contextless" (dst, src: rawptr, len: int) -> rawptr {
	if dst == src || len <= 0 {
		return dst
	}
	if len < NATIVE_MEMORY_DISPATCH_MIN || !native_memory_avx2_usable() {
		native_memcpy_sse2(dst, src, len)
	} else {
		native_memcpy_avx2(dst, src, len)
	}
	return dst
}

@(private, require)
native_memmove :: proc "contextless" (dst, src: rawptr, len: int) -> rawptr {
	if dst == src || len <= 0 {
		return dst
	}
	if len < NATIVE_MEMORY_DISPATCH_MIN || !native_memory_avx2_usable() {
		native_memmove_sse2(dst, src, len)
	} else {
		native_memmove_avx2(dst, src, len)
	}
	return dst
}

@(private, require)
native_memset :: proc "contextless" (dst: rawptr, val: u8, len: int) -> rawptr {
	if dst == nil || len <= 0 {
		return dst
	}
	if len < NATIVE_MEMORY_DISPATCH_MIN || !native_memory_avx2_usable() {
		native_memset_sse2(dst, val, len)
	} else {
		native_memset_avx2(dst, val, len)
	}
	return dst
}

// Volatile paths: every access is volatile and each byte is accessed exactly once.
// Vector accesses are used only after peeling to the vector's natural alignment.

@(private)
volatile_fill :: #force_inline proc "contextless" ($V: typeid, d: [^]byte, v: u8, n: int) {
	vb := int(size_of(V))
	x := splat(V, v)
	i := 0
	for i < n && (uintptr(d) + uintptr(i)) & uintptr(vb - 1) != 0 {
		intrinsics.volatile_store(&d[i], v)
		i += 1
	}
	for n - i >= vb {
		intrinsics.volatile_store((^V)(rawptr(uintptr(d) + uintptr(i))), x)
		i += vb
	}
	for i < n {
		intrinsics.volatile_store(&d[i], v)
		i += 1
	}
}

@(private, require)
native_memset_volatile :: proc "contextless" (dst: rawptr, val: u8, len: int) -> rawptr {
	if len <= 0 {
		return dst
	}
	if len >= NATIVE_MEMORY_DISPATCH_MIN && native_memory_avx2_usable() {
		native_memset_volatile_avx2(dst, val, len)
	} else {
		native_memset_volatile_sse2(dst, val, len)
	}
	return dst
}

@(private)
native_memset_volatile_sse2 :: #force_no_inline proc "contextless" (dst: rawptr, val: u8, len: int) {
	volatile_fill(Vec16, ([^]byte)(dst), val, len)
}

@(private, enable_target_feature = "avx2,-slow-unaligned-mem-32")
native_memset_volatile_avx2 :: #force_no_inline proc "contextless" (dst: rawptr, val: u8, len: int) {
	volatile_fill(Vec32, ([^]byte)(dst), val, len)
}

// Copies use 16-byte volatile vectors only when source and destination share a residue.
@(private)
volatile_copy_forward :: proc "contextless" (d, s: [^]byte, n: int) {
	i := 0
	if (uintptr(d) ~ uintptr(s)) & 15 == 0 {
		for i < n && (uintptr(d) + uintptr(i)) & 15 != 0 {
			intrinsics.volatile_store(&d[i], intrinsics.volatile_load(&s[i]))
			i += 1
		}
		for n - i >= 16 {
			x := intrinsics.volatile_load((^Vec16)(rawptr(uintptr(s) + uintptr(i))))
			intrinsics.volatile_store((^Vec16)(rawptr(uintptr(d) + uintptr(i))), x)
			i += 16
		}
	}
	for i < n {
		intrinsics.volatile_store(&d[i], intrinsics.volatile_load(&s[i]))
		i += 1
	}
}

@(private)
volatile_copy_backward :: proc "contextless" (d, s: [^]byte, n: int) {
	i := n
	if (uintptr(d) ~ uintptr(s)) & 15 == 0 {
		for i > 0 && (uintptr(d) + uintptr(i)) & 15 != 0 {
			i -= 1
			intrinsics.volatile_store(&d[i], intrinsics.volatile_load(&s[i]))
		}
		for i >= 16 {
			i -= 16
			x := intrinsics.volatile_load((^Vec16)(rawptr(uintptr(s) + uintptr(i))))
			intrinsics.volatile_store((^Vec16)(rawptr(uintptr(d) + uintptr(i))), x)
		}
	}
	for i > 0 {
		i -= 1
		intrinsics.volatile_store(&d[i], intrinsics.volatile_load(&s[i]))
	}
}

@(private, require)
native_memmove_volatile :: proc "contextless" (dst, src: rawptr, len: int) -> rawptr {
	d, s := ([^]byte)(dst), ([^]byte)(src)
	if len <= 0 {
		return dst
	}
	if uintptr(d) > uintptr(s) && uintptr(d) - uintptr(s) < uintptr(len) {
		volatile_copy_backward(d, s, len)
	} else {
		volatile_copy_forward(d, s, len)
	}
	return dst
}
