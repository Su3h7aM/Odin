#+build linux amd64
package runtime

// C ABI aliases for the owned native math kernels on Linux amd64 without
// the C runtime. LLVM lowers floating-point intrinsics to C library calls,
// so these link names must resolve on the owned track even when core:math
// is absent from the graph; the kernels themselves are self-contained
// internal helpers that carry no C names. Thin forwarding only: accuracy
// and algorithms belong to the kernels. The interop track emits none of
// this and leaves every name to libc.
when ODIN_NO_CRT {
	@(link_name="sin", linkage="strong", require)
	sin_glue :: proc "c" (x: f64) -> f64 {
		return linux_math_sin_f64(x)
	}

	@(link_name="cos", linkage="strong", require)
	cos_glue :: proc "c" (x: f64) -> f64 {
		return linux_math_cos_f64(x)
	}

	// glibc sincos stores through both pointers and returns nothing; the
	// kernel returns the pair directly.
	@(link_name="sincos", linkage="strong", require)
	sincos_glue :: proc "c" (x: f64, s, c: ^f64) {
		sin, cos := linux_math_sincos_f64(x)
		s^ = sin
		c^ = cos
	}

	@(link_name="exp", linkage="strong", require)
	exp_glue :: proc "c" (x: f64) -> f64 {
		return linux_math_exp_f64(x)
	}

	@(link_name="pow", linkage="strong", require)
	pow_glue :: proc "c" (x, y: f64) -> f64 {
		return linux_math_pow_f64(x, y)
	}

	@(link_name="sinf", linkage="strong", require)
	sinf_glue :: proc "c" (x: f32) -> f32 {
		return linux_math_sin_f32(x)
	}

	@(link_name="cosf", linkage="strong", require)
	cosf_glue :: proc "c" (x: f32) -> f32 {
		return linux_math_cos_f32(x)
	}

	@(link_name="sincosf", linkage="strong", require)
	sincosf_glue :: proc "c" (x: f32, s, c: ^f32) {
		sin, cos := linux_math_sincos_f32(x)
		s^ = sin
		c^ = cos
	}

	@(link_name="expf", linkage="strong", require)
	expf_glue :: proc "c" (x: f32) -> f32 {
		return linux_math_exp_f32(x)
	}

	@(link_name="powf", linkage="strong", require)
	powf_glue :: proc "c" (x, y: f32) -> f32 {
		return linux_math_pow_f32(x, y)
	}
}
