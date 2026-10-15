#+build linux amd64
package main

import "core:os"

foreign import c "system:c"
foreign import proof "proof_input.asm"

foreign c {
	puts :: proc "c" (s: cstring) -> i32 ---
}
foreign proof {
	native_proof_value :: proc "c" () -> i32 ---
}

main :: proc() {
	// puts forces a managed recheck after proof assembly.
	when ODIN_NO_CRT {
		os.exit(1)
	}
	if native_proof_value() != 73 {
		os.exit(2)
	}
	puts("proof cleanup regression")
}
