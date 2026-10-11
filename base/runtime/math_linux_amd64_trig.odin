#+build linux amd64
package runtime

import "base:intrinsics"

// Owned double-precision trigonometry kernels for Linux amd64.
//
// These are internal runtime primitives backing `core:math` on this target,
// where the LLVM `llvm.sin`/`llvm.cos` intrinsics (including the fused
// `sincos` form the optimizer produces when both are used together) would
// otherwise lower to external libm calls. They are plain contextless Odin
// procs with distinct internal names and no C-ABI exports; any C-ABI
// aliasing for the link profile is owned elsewhere. They are always defined
// on Linux amd64 (no profile gating here) and are allocation-, context- and
// errno-free. They import nothing from `core`.
//
// The kernel is the same algorithm as the pure-Odin `sincos_f64` in
// `core:math` (which keeps serving every other target): range reduction
// into intervals of pi/4 with extended-precision modular arithmetic, a
// Payne-Hanek reduction above 2**29, and the two polynomial approximations
// below. Only the `core:math` classification helpers it used are restated
// here as bit operations. Accuracy per the original notes: relative error
// peak 2.1e-16 on IEEE over [-1.07e9, +1.07e9]; partial loss begins at
// 2**30 (see `core:math` for the full note).
//
// Algorithm provenance (preserved from `core:math`):
//
// The original C code, the long comment, and the constants below were from
// http://netlib.sandia.gov/cephes/cmath/sin.c and cos.c,
// available from http://www.netlib.org/cephes/cmath.tgz.
//
// Cephes Math Library Release 2.8:  June, 2000
// Copyright 1984, 1987, 1989, 1992, 2000 by Stephen L. Moshier
//
// What you see here may be used freely but it comes with no support or
// guarantee.
//
// The Payne-Hanek reduction follows:
// "ARGUMENT REDUCTION FOR HUGE ARGUMENTS: Good to the Last Bit",
// K. C. Ng et al, March 24, 1992.

// Internal runtime primitive for `core:math` on Linux amd64; not an
// additional public math API. Returns (sin(x), cos(x)) in radians with the
// IEEE special cases: sin(±0) is ±0, cos(anything finite) at 0 is 1, and
// any non-finite input yields (NaN, NaN).
linux_math_sincos_f64 :: proc "contextless" (x: f64) -> (sin, cos: f64) #no_bounds_check {
	x := x

	PI4A :: 0h3fe921fb40000000 // 7.85398125648498535156e-1  PI/4 split into three parts
	PI4B :: 0h3e64442d00000000 // 3.77489470793079817668e-8
	PI4C :: 0h3ce8469898cc5170 // 2.69515142907905952645e-15

	// Special cases.
	switch {
	case x == 0:
		return x, 1 // return ±0.0, 1.0
	case _trig_is_nan(x) || _trig_is_inf(x):
		return _TRIG_QNAN, _TRIG_QNAN
	}

	// Make argument positive.
	sin_sign, cos_sign := false, false
	if x < 0 {
		x = -x
		sin_sign = true
	}

	j: u64
	y, z: f64
	if x >= _TRIG_REDUCE_THRESHOLD {
		j, z = _trig_reduce_f64(x)
	} else {
		j = u64(x * (4 / TRIG_PI)) // integer part of x/(PI/4), for tests on the phase angle
		y = f64(j) // integer part of x/(PI/4), as float

		if j&1 == 1 { // map zeros to origin
			j += 1
			y += 1
		}
		j &= 7 // octant modulo TAU radians (360 degrees)
		z = ((x - y*PI4A) - y*PI4B) - y*PI4C // Extended precision modular arithmetic
	}
	if j > 3 { // reflect in x axis
		j -= 4
		sin_sign, cos_sign = !sin_sign, !cos_sign
	}
	if j > 1 {
		cos_sign = !cos_sign
	}

	zz := z * z

	cos = 1.0 - 0.5*zz + zz*zz*((((((_trig_cos[0]*zz)+_trig_cos[1])*zz+_trig_cos[2])*zz+_trig_cos[3])*zz+_trig_cos[4])*zz+_trig_cos[5])
	sin = z + z*zz*((((((_trig_sin[0]*zz)+_trig_sin[1])*zz+_trig_sin[2])*zz+_trig_sin[3])*zz+_trig_sin[4])*zz+_trig_sin[5])

	if j == 1 || j == 2 {
		sin, cos = cos, sin
	}
	if cos_sign {
		cos = -cos
	}
	if sin_sign {
		sin = -sin
	}
	return
}

// Internal runtime primitive for `core:math` on Linux amd64; not an
// additional public math API. Sine of θ in radians; shares its reduction
// with `linux_math_sincos_f64`, so the two agree bit-for-bit.
linux_math_sin_f64 :: proc "contextless" (θ: f64) -> f64 {
	s, _ := linux_math_sincos_f64(θ)
	return s
}

// Internal runtime primitive for `core:math` on Linux amd64; not an
// additional public math API. Cosine of θ in radians; shares its reduction
// with `linux_math_sincos_f64`, so the two agree bit-for-bit.
linux_math_cos_f64 :: proc "contextless" (θ: f64) -> f64 {
	_, c := linux_math_sincos_f64(θ)
	return c
}

// Internal runtime primitive for `core:math` on Linux amd64; not an
// additional public math API. f32 adapter: evaluates the f64 kernel and
// narrows (single rounding step beyond the kernel error).
linux_math_sin_f32 :: proc "contextless" (θ: f32) -> f32 {
	return f32(linux_math_sin_f64(f64(θ)))
}

// Internal runtime primitive for `core:math` on Linux amd64; not an
// additional public math API. f32 adapter: evaluates the f64 kernel and
// narrows (single rounding step beyond the kernel error).
linux_math_cos_f32 :: proc "contextless" (θ: f32) -> f32 {
	return f32(linux_math_cos_f64(f64(θ)))
}

// Internal runtime primitive for `core:math` on Linux amd64; not an
// additional public math API. f32 adapter for the joint kernel.
linux_math_sincos_f32 :: proc "contextless" (x: f32) -> (sin, cos: f32) {
	s, c := linux_math_sincos_f64(f64(x))
	return f32(s), f32(c)
}

// Internal runtime primitive for `core:math` on Linux amd64; not an
// additional public math API. f32 adapter for the exponential kernel in
// `math_linux_amd64.odin`: evaluates it in f64 and narrows.
linux_math_exp_f32 :: proc "contextless" (x: f32) -> f32 {
	return f32(linux_math_exp_f64(f64(x)))
}

// Internal runtime primitive for `core:math` on Linux amd64; not an
// additional public math API. f32 adapter for the power kernel in
// `math_linux_amd64.odin`: evaluates it in f64 and narrows.
linux_math_pow_f32 :: proc "contextless" (x, power: f32) -> f32 {
	return f32(linux_math_pow_f64(f64(x), f64(power)))
}

// Full double precision pi and pi/4 as bit patterns (same doubles as the
// decimal literals used in `core:math`).
@(private="file")
TRIG_PI  :: 0h400921fb54442d18
@(private="file")
TRIG_PI4 :: 0h3fe921fb54442d18 // pi/4: matches `PI / 4` in `core:math` bit-for-bit

@(private="file")
_TRIG_QNAN :: 0h7ff80000_00000001

// REDUCE_THRESHOLD is the maximum value of x where the reduction using Pi/4
// in 3 f64 parts still gives accurate results (see `core:math` for the full
// note). Above it the Payne-Hanek reduction below must be used.
@(private="file")
_TRIG_REDUCE_THRESHOLD :: 1 << 29

// Sine coefficients.
@(private="file")
_trig_sin := [?]f64{
	0h3de5d8fd1fd19ccd, //  1.58962301576546568060e-10
	0hbe5ae5e5a9291f5d, // -2.50507477628578072866e-8
	0h3ec71de3567d48a1, //  2.75573136213857245213e-6
	0hbf2a01a019bfdf03, // -1.98412698295895385996e-4
	0h3f8111111110f7d0, //  8.33333333332211858878e-3
	0hbfc5555555555548, // -1.66666666666666307295e-1
}

// Cosine coefficients.
@(private="file")
_trig_cos := [?]f64{
	0hbda8fa49a0861a9b, // -1.13585365213876817300e-11,
	0h3e21ee9d7b4e3f05, //  2.08757008419747316778e-9,
	0hbe927e4f7eac4bc6, // -2.75573141792967388112e-7,
	0h3efa01a019c844f5, //  2.48015872888517045348e-5,
	0hbf56c16c16c14f91, // -1.38888888888730564116e-3,
	0h3fa555555555554b, //  4.16666666666665929218e-2,
}

@(private="file")
_trig_is_nan :: #force_inline proc "contextless" (x: f64) -> bool {
	return (transmute(u64)x << 1) > 0xFFE0000000000000
}

@(private="file")
_trig_is_inf :: #force_inline proc "contextless" (x: f64) -> bool {
	return (transmute(u64)x << 1) == 0xFFE0000000000000
}

// _trig_reduce_f64 implements Payne-Hanek range reduction by Pi/4 for
// x > 0. It returns the integer part mod 8 (j) and the fractional part
// (z) of x / (Pi/4).
@(private="file")
_trig_reduce_f64 :: proc "contextless" (x: f64) -> (j: u64, z: f64) #no_bounds_check {
	// bd_pi4 is the binary digits of 4/pi as a u64 array,
	// that is, 4/pi = Sum bd_pi4[i]*2^(-64*i)
	// 19 64-bit digits and the leading one bit give 1217 bits
	// of precision to handle the largest possible f64 exponent.
	@(static, rodata) bd_pi4 := [?]u64{
		0x0000000000000001,
		0x45f306dc9c882a53,
		0xf84eafa3ea69bb81,
		0xb6c52b3278872083,
		0xfca2c757bd778ac3,
		0x6e48dc74849ba5c0,
		0x0c925dd413a32439,
		0xfc3bd63962534e7d,
		0xd1046bea5d768909,
		0xd338e04d68befc82,
		0x7323ac7306a673e9,
		0x3908bf177bf25076,
		0x3ff12fffbc0b301f,
		0xde5e2316b414da3e,
		0xda6cfd9e4f96136e,
		0x9e8c7ecd3cbfd45a,
		0xea4f758fd7cbe2f6,
		0x7a0e73ef14a525d4,
		0xd7f6bf623f1aba10,
		0xac06608df8f6d757,
	}

	if x < TRIG_PI4 {
		return 0, x
	}

	MASK  :: 0x7FF
	SHIFT :: 64 - 11 - 1
	BIAS  :: 1023

	// Extract out the integer and exponent such that,
	// x = ix * 2 ** exp.
	ix := transmute(u64)x
	exp := int(ix>>SHIFT&MASK) - BIAS - SHIFT
	ix &~= MASK << SHIFT
	ix |= 1 << SHIFT
	// Use the exponent to extract the 3 appropriate u64 digits from bd_pi4,
	// B ~ (z0, z1, z2), such that the product leading digit has the exponent -61.
	// Note, exp >= -53 since x >= PI4 and exp < 971 for maximum f64.
	digit, bitshift := uint(exp+61)/64, uint(exp+61)%64
	z0 := (bd_pi4[digit] << bitshift) | (bd_pi4[digit+1] >> (64 - bitshift))
	z1 := (bd_pi4[digit+1] << bitshift) | (bd_pi4[digit+2] >> (64 - bitshift))
	z2 := (bd_pi4[digit+2] << bitshift) | (bd_pi4[digit+3] >> (64 - bitshift))
	// Multiply mantissa by the digits and extract the upper two digits (hi, lo).
	z2hi, _ := _trig_mul_u64(z2, ix)
	z1hi, z1lo := _trig_mul_u64(z1, ix)
	z0lo := z0 * ix
	lo, c := _trig_add_u64(z1lo, z2hi, 0)
	hi, _ := _trig_add_u64(z0lo, z1hi, c)
	// The top 3 bits are j.
	j = hi >> 61
	// Extract the fraction and find its magnitude.
	hi = hi<<3 | lo>>61
	lz := uint(intrinsics.count_leading_zeros(hi))
	e := u64(BIAS - (lz + 1))
	// Clear implicit mantissa bit and shift into place.
	hi = (hi << (lz + 1)) | (lo >> (64 - (lz + 1)))
	hi >>= 64 - SHIFT
	// Include the exponent and convert to a float.
	hi |= e << SHIFT
	z = transmute(f64)hi
	// Map zeros to origin.
	if j&1 == 1 {
		j += 1
		j &= 7
		z -= 1
	}
	// Multiply the fractional part by pi/4.
	return j, z * TRIG_PI4

	@(require_results)
	_trig_add_u64 :: proc "contextless" (x, y, carry: u64) -> (sum, carry_out: u64) {
		tmp_carry, tmp_carry2: bool
		sum, tmp_carry  = intrinsics.overflow_add(x, y)
		sum, tmp_carry2 = intrinsics.overflow_add(sum, carry)
		carry_out = u64(tmp_carry | tmp_carry2)
		return
	}

	@(require_results)
	_trig_mul_u64 :: proc "contextless" (x, y: u64) -> (hi, lo: u64) {
		prod_wide := u128(x) * u128(y)
		hi, lo = u64(prod_wide>>64), u64(prod_wide)
		return
	}
}
