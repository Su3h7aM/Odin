#+build linux amd64
package runtime

import "base:intrinsics"

// Owned double-precision math kernels for Linux amd64.
//
// These are internal runtime primitives backing `core:math` on this target,
// where the LLVM `llvm.exp`/`llvm.pow` intrinsics would otherwise lower to
// external libm calls (`exp`, `pow`). They are plain contextless Odin procs
// with distinct internal names and no C-ABI exports; any C-ABI aliasing for
// the link profile is owned elsewhere. They are always defined on
// Linux amd64 (no profile gating here) and are allocation-, context- and
// errno-free: the `core:math` contracts for these operations document value
// semantics only, so no `errno` side effects are produced.
//
// Algorithms are Odin translations of FreeBSD's msun `e_exp.c` and `e_pow.c`
// (Sun Microsystems fdlibm family, same provenance as the pure-Odin `ln`
// port already in `core:math`), whose accuracy notes are preserved below:
//
//	exp: error always less than 1 ulp. Overflow above
//	  7.09782712893383973096e+02, underflow below -7.45133219101941108420e+02.
//	pow: returns x**y nearly rounded; pow(integer, integer) always returns
//	  the correct integer provided it is representable.
//
// The requiredisci copyright notice:
//
// ====================================================
// Copyright (C) 2004 by Sun Microsystems, Inc. All rights reserved.
//
// Permission to use, copy, modify, and distribute this
// software is freely granted, provided that this notice
// is preserved.
// ====================================================

// Internal runtime primitive for `core:math` on Linux amd64; not an
// additional public math API. `exp(x)` returns the exponential of x.
// Special cases: exp(+Inf) is +Inf, exp(-Inf) is 0, exp(NaN) is NaN;
// for finite x only exp(0) == 1 is exact.
linux_math_exp_f64 :: proc "contextless" (x: f64) -> f64 {
	// Constants: the hexadecimal values are the intended ones. Decimal
	// values are used; the compiler converts them accurately enough to
	// produce the hexadecimal values shown (per the original source note).
	O_THRESHOLD  :: 7.09782712893383973096e+02 // 0x40862E42, 0xFEFA39EF
	U_THRESHOLD  :: -7.45133219101941108420e+02 // 0xc0874910, 0xD52D3051
	LN2_HI       :: 6.93147180369123816490e-01 // 0x3fe62e42, 0xfee00000
	LN2_LO       :: 1.90821492927058770002e-10 // 0x3dea39ef, 0x35793c76
	INV_LN2      :: 1.44269504088896338700e+00 // 0x3ff71547, 0x652b82fe
	EXP_P1       :: 1.66666666666666019037e-01 // 0x3FC55555, 0x5555553E
	EXP_P2       :: -2.77777777770155933842e-03 // 0xBF66C16C, 0x16BEBD93
	EXP_P3       :: 6.61375632143793436117e-05 // 0x3F11566A, 0xAF25DE2C
	EXP_P4       :: -1.65339022054652515390e-06 // 0xBEBBBD41, 0xC5D26BF1
	EXP_P5       :: 4.13813679705723846039e-08 // 0x3E663769, 0x72BEA4D0
	EXP_HUGE     := 1.0e300
	EXP_TWOM1000 :: 9.33263618503218878990e-302 // 2**-1000

	hx := _f64_hi(x)
	xsb := int((hx >> 31) & 1) // sign bit of x
	hx &= 0x7fffffff // high word of |x|

	// Filter out non-finite argument.
	if hx >= 0x40862E42 { // |x| >= 709.78...
		if hx >= 0x7ff00000 {
			lx := _f64_lo(x)
			if ((hx & 0xfffff) | lx) != 0 {
				return x + x // NaN
			}
			if xsb == 0 {
				return x // exp(+Inf) = +Inf
			}
			return 0.0 // exp(-Inf) = 0
		}
		if x > O_THRESHOLD {
			return EXP_HUGE * EXP_HUGE // overflow
		}
		if x < U_THRESHOLD {
			return EXP_TWOM1000 * EXP_TWOM1000 // underflow
		}
	}

	hi, lo := 0.0, 0.0
	k := 0
	xx := x

	// Argument reduction: find r and integer k with x = k*ln2 + r,
	// |r| <= 0.5*ln2, r represented as hi-lo for extra accuracy.
	if hx > 0x3fd62e42 { // |x| > 0.5*ln2
		if hx < 0x3FF0A2B2 { // |x| < 1.5*ln2
			hi = x - (LN2_HI if xsb == 0 else -LN2_HI)
			lo = LN2_LO if xsb == 0 else -LN2_LO
			k = 1 - xsb - xsb
		} else {
			kf := INV_LN2 * x + (0.5 if xsb == 0 else -0.5)
			k = int(kf)
			t := f64(k)
			hi = x - t * LN2_HI // t*LN2_HI is exact here
			lo = t * LN2_LO
		}
		xx = hi - lo
	} else if hx < 0x3e300000 { // |x| < 2**-28
		if EXP_HUGE + xx > 1.0 {
			return 1.0 + xx
		}
	}

	// xx is now in primary range.
	t := xx * xx
	twopk: f64
	if k >= -1021 {
		twopk = _f64_from_words(u32(0x3ff + k) << 20, 0)
	} else {
		twopk = _f64_from_words(u32(0x3ff + (k + 1000)) << 20, 0)
	}
	c := xx - t * (EXP_P1 + t * (EXP_P2 + t * (EXP_P3 + t * (EXP_P4 + t * EXP_P5))))
	if k == 0 {
		return 1.0 - ((xx * c) / (c - 2.0) - xx)
	}
	y := 1.0 - ((lo - (xx * c) / (2.0 - c)) - hi)
	if k >= -1021 {
		if k == 1024 {
			return y * 2.0 * _f64_from_words(0x7FE00000, 0) // y * 2 * 2**1023
		}
		return y * twopk
	}
	return y * twopk * EXP_TWOM1000
}

// Internal runtime primitive for `core:math` on Linux amd64; not an
// additional public math API. `pow(x, y)` returns x**y with the POSIX
// special cases (see body): (anything)**0 is 1 (even NaN**0);
// 1**y is 1 (even 1**NaN); (+-0)**negative is +-Inf; negative
// non-integer powers of negative bases are NaN; signed-zero and
// infinity rules per quadrant. No errno side effects.
linux_math_pow_f64 :: proc "contextless" (x, y: f64) -> f64 {
	BP_0  :: 1.0
	BP_1  :: 1.5
	DP_H1 :: 5.84962487220764160156e-01 // 0x3FE2B803, 0x40000000
	DP_L1 :: 1.35003920212974897128e-08 // 0x3E4CFDEB, 0x43CFD006
	HALF  :: 0.5
	QRTR  :: 0.25
	THRD  :: 3.3333333333333331e-01 // 0x3fd55555, 0x55555555
	ONE   :: 1.0
	TWO   :: 2.0
	TWO53 :: 9007199254740992.0 // 0x43400000, 0x00000000
	HUGE  := 1.0e300
	TINY  := 1.0e-300
	L1    :: 5.99999999999994648725e-01
	L2    :: 4.28571428578550184252e-01
	L3    :: 3.33333329818377432918e-01
	L4    :: 2.72728123808534006489e-01
	L5    :: 2.30660745775561754067e-01
	L6    :: 2.06975017800338417784e-01
	P1    :: 1.66666666666666019037e-01
	P2    :: -2.77777777770155933842e-03
	P3    :: 6.61375632143793436117e-05
	P4    :: -1.65339022054652515390e-06
	P5    :: 4.13813679705723846039e-08
	LG2   :: 6.93147180559945286227e-01
	LG2_H :: 6.93147182464599609375e-01
	LG2_L :: -1.90465429995776804525e-09
	OVT   :: 8.0085662595372944372e-0017
	CP    :: 9.61796693925975554329e-01
	CP_H  :: 9.61796700954437255859e-01
	CP_L  :: -7.02846165095275826516e-09
	IVLN2   :: 1.44269504088896338700e+00
	IVLN2_H :: 1.44269502162933349609e+00
	IVLN2_L :: 1.92596299112661746887e-08

	hx := _f64_hi(x)
	lx := _f64_lo(x)
	hy := _f64_hi(y)
	ly := _f64_lo(y)
	ix := hx & 0x7fffffff
	iy := hy & 0x7fffffff

	// y == ±0: x**0 = 1.
	if (iy | ly) == 0 {
		return ONE
	}

	// x == 1: 1**y = 1, even if y is NaN.
	if hx == 0x3ff00000 && lx == 0 {
		return ONE
	}

	// Result is NaN if either argument is NaN (outside the cases above).
	if ix > 0x7ff00000 || (ix == 0x7ff00000 && lx != 0) ||
	   iy > 0x7ff00000 || (iy == 0x7ff00000 && ly != 0) {
		return x + y // NaN propagation
	}

	// Determine if y is an odd int when x < 0.
	yisint := i32(0)
	if hx >= 0x80000000 { // x < 0
		if iy >= 0x43400000 {
			yisint = 2 // even integer y
		} else if iy >= 0x3ff00000 {
			k := i32(iy >> 20) - 0x3ff // exponent
			if k > 20 {
				j := ly >> (u32(52 - k))
				if (j << (u32(52 - k))) == ly {
					yisint = 2 - i32(j & 1)
				}
			} else if ly == 0 {
				j := iy >> (u32(20 - k))
				if (j << (u32(20 - k))) == iy {
					yisint = 2 - i32(j & 1)
				}
			}
		}
	}

	// Special value of y.
	if ly == 0 {
		if iy == 0x7ff00000 { // y is ±Inf
			if ix == 0x3ff00000 && lx == 0 {
				return ONE // (-1)**±Inf is 1
			} else if ix >= 0x3ff00000 { // (|x|>1)**±Inf
				if hy < 0x80000000 {
					return y
				}
				return 0.0
			} else { // (|x|<1)**
				if hy >= 0x80000000 {
					return -y // +Inf
				}
				return 0.0
			}
		}
		if iy == 0x3ff00000 { // y is ±1
			if hy >= 0x80000000 {
				return ONE / x
			}
			return x
		}
		if hy == 0x40000000 { // y is 2
			return x * x
		}
		if hy == 0x3fe00000 { // y is 0.5
			if hx < 0x80000000 { // x >= +0
				return intrinsics.sqrt(x)
			}
		}
	}

	ax := _f64_abs(x)
	// Special value of x.
	if lx == 0 {
		if ix == 0x7ff00000 || ix == 0 || ix == 0x3ff00000 {
			z := ax // x is ±0, ±Inf, ±1
			if hy >= 0x80000000 {
				z = ONE / z // z = 1/|x|
			}
			if hx >= 0x80000000 { // x < 0
				if ix == 0x3ff00000 && yisint == 0 {
					z = (z - z) / (z - z) // (-1)**non-int is NaN
				} else if yisint == 1 {
					z = -z
				}
			}
			return z
		}
	}

	n := i32(hx >> 31) - 1 // -1 if x < 0 else 0

	// (x<0)**(non-int) is NaN.
	if (n | yisint) == 0 {
		return (x - x) / (x - x)
	}

	s := ONE // sign of result for (-ve)**odd, else 1
	if (n | (yisint - 1)) == 0 {
		s = -ONE
	}

	// |y| is huge.
	t1, t2: f64
	if iy > 0x41e00000 { // |y| > 2**31
		if iy > 0x43f00000 { // |y| > 2**64, must overflow/underflow
			if ix <= 0x3fefffff {
				if hy >= 0x80000000 {
					return HUGE * HUGE
				}
				return TINY * TINY
			}
			if ix >= 0x3ff00000 {
				if hy < 0x80000000 {
					return HUGE * HUGE
				}
				return TINY * TINY
			}
		}
		// Over/underflow if x is not close to one.
		if ix < 0x3fefffff {
			if hy >= 0x80000000 {
				return s * HUGE * HUGE
			}
			return s * TINY * TINY
		}
		if ix > 0x3ff00000 {
			if hy < 0x80000000 {
				return s * HUGE * HUGE
			}
			return s * TINY * TINY
		}
		// |1-x| is tiny <= 2**-20; log(x) by x-x^2/2+x^3/3-x^4/4.
		t := ax - ONE // t has 20 trailing zeros
		w := (t * t) * (HALF - t * (THRD - t * QRTR))
		u := IVLN2_H * t // IVLN2_H has 21 sig. bits
		v := t * IVLN2_L - w * IVLN2
		t1 = u + v
		t1 = _f64_with_lo(t1, 0)
		t2 = v - (t1 - u)
	} else {
		n = 0
		// Take care of subnormal x.
		if ix < 0x00100000 {
			ax *= TWO53
			n -= 53
			ix = _f64_hi(ax)
		}
		n += i32(ix >> 20) - 0x3ff
		j := ix & 0x000fffff
		// Determine interval.
		ix = j | 0x3ff00000 // normalize ix
		k: i32
		if j <= 0x3988E {
			k = 0 // |x| < sqrt(3/2)
		} else if j < 0xBB67A {
			k = 1 // |x| < sqrt(3)
		} else {
			k = 0
			n += 1
			ix -= 0x00100000
		}
		ax = _f64_with_hi(ax, ix)

		// ss = s_h+s_l = (x-1)/(x+1) or (x-1.5)/(x+1.5).
		bpv := BP_1 if k == 1 else BP_0
		u := ax - bpv
		v := ONE / (ax + bpv)
		ss := u * v
		s_h := _f64_with_lo(ss, 0)
		// t_h = ax+bp[k] high part.
		t_h := _f64_from_words(((ix >> 1) | 0x20000000) + 0x00080000 + (u32(k) << 18), 0)
		t_l := ax - (t_h - bpv)
		s_l := v * ((u - s_h * t_h) - s_h * t_l)
		// log(ax).
		s2 := ss * ss
		r := s2 * s2 * (L1 + s2 * (L2 + s2 * (L3 + s2 * (L4 + s2 * (L5 + s2 * L6)))))
		r += s_l * (s_h + ss)
		s2 = s_h * s_h
		t_h = 3 + s2 + r
		t_h = _f64_with_lo(t_h, 0)
		t_l = r - ((t_h - 3) - s2)
		// u+v = ss*(1+...).
		u = s_h * t_h
		v = s_l * t_h + t_l * ss
		// 2/(3log2)*(ss+...).
		p_h := u + v
		p_h = _f64_with_lo(p_h, 0)
		p_l := v - (p_h - u)
		z_h := CP_H * p_h // cp_h+cp_l = 2/(3*log2)
		z_l := CP_L * p_h + p_l * CP + (DP_L1 if k == 1 else 0.0)
		// log2(ax) = n + dp_h + z_h + z_l.
		t := f64(n)
		t1 = ((z_h + z_l) + (DP_H1 if k == 1 else 0.0)) + t
		t1 = _f64_with_lo(t1, 0)
		t2 = z_l - (((t1 - t) - (DP_H1 if k == 1 else 0.0)) - z_h)
	}

	// Split y into y1+y2 and compute (y1+y2)*(t1+t2).
	y1 := _f64_with_lo(y, 0)
	p_l := (y - y1) * t1 + y * t2
	p_h := y1 * t1
	z := p_l + p_h
	j := i32(_f64_hi(z))
	i := _f64_lo(z)
	if j >= 0x40900000 { // z >= 1024
		ju := cast(u32)j
		if ((ju - 0x40900000) | i) != 0 { // z > 1024
			return s * HUGE * HUGE // overflow
		}
		if p_l + OVT > z - p_h {
			return s * HUGE * HUGE // overflow
		}
	} else if (cast(u32)j & 0x7fffffff) >= 0x4090cc00 { // z <= -1075
		ju := cast(u32)j
		if ((ju - 0xc090cc00) | i) != 0 { // z < -1075
			return s * TINY * TINY // underflow
		}
		if p_l <= z - p_h {
			return s * TINY * TINY // underflow
		}
	}

	// Compute 2**(p_h+p_l).
	ii := cast(u32)j & 0x7fffffff
	k := i32(ii >> 20) - 0x3ff
	n = 0
	if ii > 0x3fe00000 { // |z| > 0.5, set n = [z+0.5]
		n = j + i32(u32(0x00100000) >> u32(k + 1))
		k = i32((cast(u32)n & 0x7fffffff) >> 20) - 0x3ff
		t := 0.0
		t = _f64_with_hi(t, cast(u32)n & ~(u32(0x000fffff) >> u32(k)))
		n = i32(((cast(u32)n & 0x000fffff) | 0x00100000) >> u32(20 - k))
		if j < 0 {
			n = -n
		}
		p_h -= t
	}
	t := p_l + p_h
	t = _f64_with_lo(t, 0)
	u := t * LG2_H
	v := (p_l - (t - p_h)) * LG2 + t * LG2_L
	z = u + v
	w := v - (z - u)
	t = z * z
	t1 = z - t * (P1 + t * (P2 + t * (P3 + t * (P4 + t * P5))))
	r := (z * t1) / (t1 - TWO) - (w + z * w)
	z = ONE - (r - z)
	j = cast(i32)_f64_hi(z)
	// j (biased exponent) is shifted in below as raw bits.
	j = cast(i32)(cast(u32)j + (cast(u32)n << 20))
	if (j >> 20) <= 0 {
		z = _scalbn_f64(z, int(n)) // subnormal output
	} else {
		z = _f64_with_hi(z, cast(u32)j)
	}
	return s * z
}

// Exact scaling of x by 2**n with a single rounding, matching a true scalbn:
// overflow yields ±Inf, underflow yields a correctly gradual subnormal or
// ±0 (round-half-even, including ties), and NaN/Inf/±0 pass through
// unchanged. Normal results are bit-exact (no rounding at all); subnormal
// results round exactly once from the full 53-bit significand, so outcomes
// in intervals like [0.707..1.414]*2**-1023 are exact instead of flushed.
//
// Method: split x into a 53-bit-or-fewer significand M and a binary
// exponent E (both exact integers, normalizing subnormal inputs), add n to
// E exactly, then rebuild. A stepwise multiply by 2**-1022 would round
// twice on the way through the subnormal range (once crossing below normal
// range, once at the final magnitude); the shift-and-round below keeps the
// single rounding a true scalbn performs.
// Package-visible (not file-private) so the runtime's own test package can
// verify its boundaries directly; still internal, not public API.
@(private)
_scalbn_f64 :: proc "contextless" (x: f64, n: int) -> f64 {
	bits := transmute(u64)x
	sign := bits & 0x8000000000000000
	if bits << 1 == 0 {
		return x // ±0
	}
	if bits << 1 >= 0xFFE0000000000000 {
		return x // NaN or ±Inf
	}
	// Exact decomposition: V = M * 2**E with 0 < M < 2**53.
	mant := bits & 0x000fffffffffffff
	ebiased := i64((bits >> 52) & 0x7ff)
	m: u64
	e: i64
	if ebiased == 0 {
		// Subnormal input: no implicit leading bit.
		m = mant
		e = -1074
	} else {
		m = mant | 0x0010000000000000
		e = ebiased - 1023 - 52
	}
	// Normalize M into [2**52, 2**53), adjusting E exactly.
	shift := int(intrinsics.count_leading_zeros(m)) - 11
	m <<= uint(shift)
	e -= i64(shift)
	// Fast paths that also keep the exact addition below free of any
	// wrap concern: beyond these, every finite nonzero x overflows to
	// ±Inf (|x| >= 2**-1074 scaled by 2**2100 exceeds max double) or
	// underflows to signed zero (|x| < 2**1024 scaled by 2**-2200 is
	// below half the smallest subnormal).
	if n > 2100 {
		return transmute(f64)(sign | 0x7ff0000000000000)
	}
	if n < -2200 {
		return transmute(f64)(sign)
	}
	e += i64(n)
	// From here E is the exponent of the normalized 53-bit significand:
	// V = M * 2**E with M in [2**52, 2**53).
	if e >= 972 {
		// V >= 2**52 * 2**972 = 2**1024: overflow to ±Inf. (E == 971
		// always fits since M < 2**53.)
		return transmute(f64)(sign | 0x7ff0000000000000)
	}
	if e >= -1074 {
		// V >= 2**52 * 2**-1074 = 2**-1022 and V < 2**1024: normal
		// result, exact with the mantissa preserved bit-for-bit.
		return transmute(f64)(sign | (u64(e + 1075) << 52) | (m & 0x000fffffffffffff))
	}
	// Subnormal result: shift M right by k with round-half-even over the
	// full significand — the single rounding of a true scalbn. (A round-up
	// of q to 2**52 encodes min-normal, which shares its bit pattern.)
	k := -1074 - e // >= 1
	if k >= 64 {
		return transmute(f64)(sign) // far below range: signed zero
	}
	ku := uint(k)
	q := m >> ku
	rem := m & ((u64(1) << ku) - 1)
	half := u64(1) << (ku - 1)
	if rem > half || (rem == half && q & 1 == 1) {
		q += 1
	}
	return transmute(f64)(sign | q)
}

@(private="file")
_f64_hi :: #force_inline proc "contextless" (x: f64) -> u32 {
	return u32(transmute(u64)x >> 32)
}

@(private="file")
_f64_lo :: #force_inline proc "contextless" (x: f64) -> u32 {
	return u32(transmute(u64)x)
}

@(private="file")
_f64_from_words :: #force_inline proc "contextless" (hi, lo: u32) -> f64 {
	return transmute(f64)((u64(hi) << 32) | u64(lo))
}

@(private="file")
_f64_with_hi :: #force_inline proc "contextless" (x: f64, hi: u32) -> f64 {
	return transmute(f64)((u64(hi) << 32) | (transmute(u64)x & 0xffffffff))
}

@(private="file")
_f64_with_lo :: #force_inline proc "contextless" (x: f64, lo: u32) -> f64 {
	return transmute(f64)((transmute(u64)x & 0xffffffff00000000) | u64(lo))
}

@(private="file")
_f64_abs :: #force_inline proc "contextless" (x: f64) -> f64 {
	return transmute(f64)(transmute(u64)x & 0x7fffffffffffffff)
}

// Integral rounding preserves signed zero; exception flags are not specified.
linux_math_trunc_f64 :: proc "contextless" (x: f64) -> f64 {
	bits := transmute(u64)x
	exponent := int((bits >> 52) & 0x7ff) - 1023
	if exponent < 0 {
		return transmute(f64)(bits & 0x8000000000000000)
	}
	if exponent >= 52 {
		return x
	}
	mask := (u64(1) << uint(52-exponent)) - 1
	return transmute(f64)(bits &~ mask)
}

linux_math_floor_f64 :: proc "contextless" (x: f64) -> f64 {
	integer := linux_math_trunc_f64(x)
	return integer - 1 if x < integer else integer
}

linux_math_ceil_f64 :: proc "contextless" (x: f64) -> f64 {
	integer := linux_math_trunc_f64(x)
	return integer + 1 if x > integer else integer
}

// Nearest-even value semantics, independent of MXCSR rounding mode.
linux_math_nearest_f64 :: proc "contextless" (x: f64) -> f64 {
	bits := transmute(u64)x
	sign := bits & 0x8000000000000000
	magnitude := bits & 0x7fffffffffffffff
	exponent := int((bits >> 52) & 0x7ff) - 1023
	if exponent < 0 {
		return transmute(f64)(sign | (0x3ff0000000000000 if magnitude > 0x3fe0000000000000 else 0))
	}
	if exponent >= 52 {
		return x
	}
	shift := uint(52-exponent)
	mask := (u64(1) << shift) - 1
	fraction := bits & mask
	half := u64(1) << (shift-1)
	integer := bits &~ mask
	if fraction > half || (fraction == half && ((integer >> shift) & 1) != 0) {
		integer += mask + 1
	}
	return transmute(f64)integer
}

linux_math_trunc_f32 :: proc "contextless" (x: f32) -> f32 {
	return f32(linux_math_trunc_f64(f64(x)))
}

linux_math_floor_f32 :: proc "contextless" (x: f32) -> f32 {
	return f32(linux_math_floor_f64(f64(x)))
}

linux_math_ceil_f32 :: proc "contextless" (x: f32) -> f32 {
	return f32(linux_math_ceil_f64(f64(x)))
}

linux_math_nearest_f32 :: proc "contextless" (x: f32) -> f32 {
	return f32(linux_math_nearest_f64(f64(x)))
}
