#+build linux amd64
// Owned Linux amd64 routing for `core:math` entry points whose LLVM
// intrinsics lower to external libm calls (`sin`, `cos`, `sinf`, `cosf`,
// `exp`, `expf`, `pow`, `powf`, and the fused `sincos`).
//
// Every procedure below delegates to the self-contained runtime kernels in
// `base/runtime/math_linux_amd64*.odin` (trigonometry) and
// `base/runtime/math_linux_amd64.odin` (exponential/power), so there is one
// active Linux implementation per family: the public `sincos` group reaches
// the same kernels through `sincos_f64`'s own Linux delegation, and `erf`
// and `gamma` close transitively with no changes to their files.
//
// Narrower precisions evaluate the f64 kernel and narrow (in-tree
// precedent: `cbrt_f32` via `cbrt_f64`). Public `core:math` API names and
// signatures are unchanged on every target.
package math

import "base:runtime"

@(require_results)
native_sin_f64 :: proc "contextless" (θ: f64) -> f64 {
	return runtime.linux_math_sin_f64(θ)
}

@(require_results)
native_cos_f64 :: proc "contextless" (θ: f64) -> f64 {
	return runtime.linux_math_cos_f64(θ)
}

@(require_results)
native_sincos_f64 :: proc "contextless" (x: f64) -> (sin, cos: f64) {
	return runtime.linux_math_sincos_f64(x)
}

@(require_results)
native_exp_f64 :: proc "contextless" (x: f64) -> f64 {
	return runtime.linux_math_exp_f64(x)
}

@(require_results)
native_pow_f64 :: proc "contextless" (x, power: f64) -> f64 {
	return runtime.linux_math_pow_f64(x, power)
}

@(require_results)
native_sin_f32 :: proc "contextless" (θ: f32) -> f32 {
	return runtime.linux_math_sin_f32(θ)
}

@(require_results)
native_cos_f32 :: proc "contextless" (θ: f32) -> f32 {
	return runtime.linux_math_cos_f32(θ)
}

@(require_results)
native_exp_f32 :: proc "contextless" (x: f32) -> f32 {
	return runtime.linux_math_exp_f32(x)
}

@(require_results)
native_pow_f32 :: proc "contextless" (x, power: f32) -> f32 {
	return runtime.linux_math_pow_f32(x, power)
}

@(require_results)
native_sin_f16 :: proc "contextless" (θ: f16) -> f16 {
	return f16(runtime.linux_math_sin_f64(f64(θ)))
}

@(require_results)
native_cos_f16 :: proc "contextless" (θ: f16) -> f16 {
	return f16(runtime.linux_math_cos_f64(f64(θ)))
}

@(require_results)
native_exp_f16 :: proc "contextless" (x: f16) -> f16 {
	return f16(runtime.linux_math_exp_f64(f64(x)))
}

@(require_results)
native_pow_f16 :: proc "contextless" (x, power: f16) -> f16 {
	return f16(runtime.linux_math_pow_f64(f64(x), f64(power)))
}
