#+build linux amd64
package runtime

// Test-only internal bridge to the owned `_scalbn_f64` helper. Compiled
// only under ODIN_TEST so ordinary builds gain no additional public API;
// it performs no C exports and imports nothing outside the base runtime.
// The actual boundary tests live in `tests/core/math/native_linux`
// (which may import `core:testing`; this package may not import `core`
// even for tests) and call `runtime.linux_math_scalbn_for_test`, so the
// helper is exercised directly with no mirrored algorithm copy.
when ODIN_TEST {
	linux_math_scalbn_for_test :: proc "contextless" (x: f64, n: int) -> f64 {
		return _scalbn_f64(x, n)
	}
}
