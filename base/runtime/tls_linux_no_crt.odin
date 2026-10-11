#+build linux amd64, linux arm64, linux riscv64
#+no-instrumentation
package runtime

import "base:intrinsics"

when ODIN_NO_CRT {
	when ODIN_ARCH == .amd64 {
		@require foreign import tls_layout_asm "tls_linux_no_crt_amd64.asm"
	} else when ODIN_ARCH == .arm64 {
		@require foreign import tls_layout_asm "tls_linux_no_crt_arm64.asm"
	} else when ODIN_ARCH == .riscv64 {
		@require foreign import tls_layout_asm "tls_linux_no_crt_riscv64.asm"
	}

	// Written by the entry stub before runtime initialization. Static ET_EXEC only.
	@(private, link_name="_odin_linux_tls_header", linkage="strong", require, export)
	linux_tls_header: rawptr

	// Layout relative to an aligned thread pointer. The image is borrowed from
	// the executable and remains valid for the lifetime of the process.
	Linux_No_Crt_TLS_Layout :: struct {
		size:         uintptr,
		alignment:    uintptr,
		tp_bias:      uintptr,
		block_offset: int,
		image:        rawptr,
		image_size:   uintptr,
	}

	@(private)
	foreign tls_layout_asm {
		@(link_name="_odin_linux_tls_layout")
		linux_tls_layout :: proc(header: rawptr, layout: ^Linux_No_Crt_TLS_Layout) -> bool ---
	}

	// Return the same static TLS layout used by the Linux no-CRT entry stub.
	// A missing PT_TLS yields an empty layout. False indicates an invalid layout.
	linux_no_crt_tls_layout :: proc "contextless" () -> (layout: Linux_No_Crt_TLS_Layout, ok: bool) {
		if linux_tls_header == nil {
			layout.alignment = 1
			return layout, true
		}
		ok = linux_tls_layout(linux_tls_header, &layout)
		return
	}

	// Initialize a new thread's static TLS in caller-owned writable memory of
	// at least layout.size bytes. Return the thread pointer to pass to CLONE_SETTLS.
	// The memory must remain valid until the kernel has finished exiting the thread.
	linux_no_crt_tls_init :: proc "contextless" (layout: Linux_No_Crt_TLS_Layout, memory: rawptr) -> rawptr {
		if layout.size == 0 {
			return nil
		}
		intrinsics.mem_zero(memory, int(layout.size))
		tp := (uintptr(memory) + layout.tp_bias + layout.alignment - 1) & ~(layout.alignment - 1)
		block := rawptr(tp + uintptr(layout.block_offset))
		intrinsics.mem_copy_non_overlapping(block, layout.image, int(layout.image_size))
		when ODIN_ARCH == .amd64 {
			(^uintptr)(rawptr(tp))^ = tp
			// LLVM's Linux amd64 stack protector reads the canary at %fs:0x28.
			(^uintptr)(rawptr(tp + 0x28))^ = linux_stack_guard
		}
		return rawptr(tp)
	}
}
