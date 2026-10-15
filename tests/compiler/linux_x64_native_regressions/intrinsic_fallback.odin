#+build linux amd64
package main

import "core:os"

foreign {
	@(link_name="llvm.exp2.f64")
	exp2 :: proc "c" (x: f64) -> f64 ---
}

main :: proc() {
	// The baseline lowering calls exp2 despite LLVM intrinsic recognition.
	when ODIN_NO_CRT {
		os.exit(1)
	}
	if exp2(f64(len(os.args))) != 2 {
		os.exit(2)
	}
}
