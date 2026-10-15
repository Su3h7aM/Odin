#+build linux amd64
package runtime

// Round exact a*b+c once to nearest-even, without FMA3.
// Finite f64 products and addends fit in 4196 bits in units of 2**-2148,
// preserving overflowing/underflowing products until after cancellation.
// Value semantics only: no exception flags or MXCSR rounding-mode handling.
linux_math_fma_f64 :: proc "contextless" (a, b, c: f64) -> f64 {
	return transmute(f64)_linux_fma_bits(a, b, c, 52, 1023)
}

linux_math_fma_f32 :: proc "contextless" (a, b, c: f32) -> f32 {
	// Widen exactly, then round directly to f32 to avoid double rounding.
	return transmute(f32)u32(_linux_fma_bits(f64(a), f64(b), f64(c), 23, 127))
}

@(private="file")
_Linux_FMA_Integer :: [66]u64

@(private="file")
_linux_fma_insert :: proc "contextless" (dst: ^_Linux_FMA_Integer, value: u64, shift: int) {
	i, offset := shift / 64, shift % 64
	dst[i] |= value << uint(offset)
	if offset != 0 {
		dst[i+1] |= value >> uint(64-offset)
	}
}

@(private="file")
_linux_fma_bit :: proc "contextless" (value: ^_Linux_FMA_Integer, bit: int) -> u64 {
	return (value[bit / 64] >> uint(bit % 64)) & 1
}

@(private="file")
_linux_fma_decode :: proc "contextless" (bits: u64) -> (significand: u64, exponent: int) {
	significand = bits & 0x000f_ffff_ffff_ffff
	exponent = int((bits >> 52) & 0x7ff)
	if exponent == 0 {
		exponent = -1074
	} else {
		significand |= u64(1) << 52
		exponent -= 1075
	}
	return
}

@(private="file")
_linux_fma_bits :: proc "contextless" (a, b, c: f64, fraction_bits, bias: int) -> u64 {
	ab, bb, cb := transmute(u64)a, transmute(u64)b, transmute(u64)c
	am, bm, cm := ab & 0x7fff_ffff_ffff_ffff, bb & 0x7fff_ffff_ffff_ffff, cb & 0x7fff_ffff_ffff_ffff
	INF :: u64(0x7ff0_0000_0000_0000)
	infinity := u64(2*bias+1) << uint(fraction_bits)
	quiet_nan := infinity | (u64(1) << uint(fraction_bits-1))
	product_sign := (ab ~ bb) >> 63
	addend_sign := cb >> 63
	sign_shift := fraction_bits + (11 if fraction_bits == 52 else 8)

	if am > INF || bm > INF || cm > INF {
		return quiet_nan
	}
	if am == INF || bm == INF {
		if am == 0 || bm == 0 || (cm == INF && product_sign != addend_sign) {
			return quiet_nan
		}
		return (product_sign << uint(sign_shift)) | infinity
	}
	if cm == INF {
		return (addend_sign << uint(sign_shift)) | infinity
	}

	as, ae := _linux_fma_decode(ab)
	bs, be := _linux_fma_decode(bb)
	cs, ce := _linux_fma_decode(cb)
	product := u128(as) * u128(bs)
	x, y: _Linux_FMA_Integer
	_linux_fma_insert(&x, u64(product), ae+be+2148)
	_linux_fma_insert(&x, u64(product >> 64), ae+be+2148+64)
	_linux_fma_insert(&y, cs, ce+2148)

	sign := product_sign
	if product_sign == addend_sign {
		carry: u128
		for i in 0..<len(x) {
			sum := u128(x[i]) + u128(y[i]) + carry
			x[i] = u64(sum)
			carry = sum >> 64
		}
	} else {
		for i := len(x)-1; i >= 0; i -= 1 {
			if x[i] != y[i] {
				if x[i] < y[i] {
					x, y = y, x
					sign = addend_sign
				}
				break
			}
		}
		borrow: u128
		for i in 0..<len(x) {
			difference := (u128(1) << 64) + u128(x[i]) - u128(y[i]) - borrow
			x[i] = u64(difference)
			borrow = 1 - (difference >> 64)
		}
	}

	top := len(x)*64 - 1
	for top >= 0 && _linux_fma_bit(&x, top) == 0 {
		top -= 1
	}
	if top < 0 {
		// Exact cancellation is +0. Two negative zero terms give -0.
		return (product_sign & addend_sign) << uint(sign_shift)
	}

	// Subnormals use a fixed quantum of 2**(1-bias-fraction_bits).
	shift := max(top-fraction_bits, 2148+1-bias-fraction_bits)
	retained: u64
	for bit := top; bit >= shift; bit -= 1 {
		retained = (retained << 1) | _linux_fma_bit(&x, bit)
	}
	guard := _linux_fma_bit(&x, shift-1)
	sticky := false
	for bit in 0..<shift-1 {
		if _linux_fma_bit(&x, bit) != 0 {
			sticky = true
			break
		}
	}
	if guard != 0 && (sticky || (retained & 1) != 0) {
		retained += 1
	}
	if retained >= u64(1) << uint(fraction_bits+1) {
		retained >>= 1
		shift += 1
	}
	result := sign << uint(sign_shift)
	if retained < u64(1) << uint(fraction_bits) {
		return result | retained
	}
	exponent := shift - 2148 + fraction_bits + bias
	if exponent >= 2*bias+1 {
		return result | infinity
	}
	return result | (u64(exponent) << uint(fraction_bits)) | (retained & ((u64(1) << uint(fraction_bits))-1))
}
