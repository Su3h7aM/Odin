#+build linux amd64
package main

import "base:intrinsics"
import "core:os"

#assert(ODIN_NO_CRT)

foreign {
	@(link_name="llvm.fma.f64")
	llvm_fma :: proc "c" (x, y, z: f64) -> f64 ---
	@(link_name="llvm.fmuladd.f32")
	llvm_fmuladd :: proc "c" (x, y, z: f32) -> f32 ---
}

main :: proc() {
	// Unfused evaluation loses the nonzero cancellation remainder.
	n := f64(len(os.args))
	x := n + 0.000000007450580596923828125
	y := 0.999999992549419403076171875
	expected := -0.000000000000000055511151231257827021181583404541015625
	if intrinsics.fused_mul_add(x, y, -n) != expected || llvm_fma(x, y, -n) != expected {
		os.exit(1)
	}
	x32 := f32(n) + 0.0001220703125
	y32 := f32(0.9998779296875)
	expected32 := f32(-0.00000001490116119384765625)
	if intrinsics.fused_mul_add(x32, y32, -f32(n)) != expected32 {
		os.exit(2)
	}
	// fmuladd permits either fused or unfused evaluation.
	r := llvm_fmuladd(x32, y32, -f32(n))
	if r != expected32 && r != 0 {
		os.exit(3)
	}
	check_rounding(f32)
	check_rounding(f64)
}

check_rounding :: proc($T: typeid) {
	n := T(len(os.args))
	v: #simd[2]T = {n + 0.5, -n - 1.5}
	if transmute([2]T)intrinsics.simd_ceil(v) != ([2]T{n + 1, -n - 1}) ||
	   transmute([2]T)intrinsics.simd_floor(v) != ([2]T{n, -n - 2}) ||
	   transmute([2]T)intrinsics.simd_trunc(v) != ([2]T{n, -n - 1}) ||
	   transmute([2]T)intrinsics.simd_nearest(v) != ([2]T{n + 1, -n - 1}) {
		os.exit(4)
	}
}
