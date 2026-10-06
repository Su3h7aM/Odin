#+private
package runtime

import "base:intrinsics"

VIRTUAL_MEMORY_SUPPORTED :: true

when ODIN_ARCH == .amd64 {
	SYS_open   :: uintptr(2)
	SYS_read   :: uintptr(0)
	SYS_close  :: uintptr(3)

	SYS_mmap    :: uintptr(9)
	SYS_munmap  :: uintptr(11)
	SYS_mprotect :: uintptr(10)
	SYS_mremap  :: uintptr(25)
	SYS_madvise :: uintptr(28)
} else when ODIN_ARCH == .arm32 {
	SYS_open   :: uintptr(5)
	SYS_read   :: uintptr(3)
	SYS_close  :: uintptr(6)

	SYS_mmap    :: uintptr(90)
	SYS_munmap  :: uintptr(91)
	SYS_mprotect :: uintptr(125)
	SYS_mremap  :: uintptr(163)
	SYS_madvise :: uintptr(220)
} else when ODIN_ARCH == .arm64 {
	SYS_openat :: uintptr(56)
	SYS_read   :: uintptr(63)
	SYS_close  :: uintptr(57)

	SYS_mmap    :: uintptr(222)
	SYS_munmap  :: uintptr(215)
	SYS_mprotect :: uintptr(226)
	SYS_mremap  :: uintptr(216)
	SYS_madvise :: uintptr(233)
} else when ODIN_ARCH == .i386 {
	SYS_open   :: uintptr(5)
	SYS_read   :: uintptr(3)
	SYS_close  :: uintptr(6)

	SYS_mmap    :: uintptr(90)
	SYS_munmap  :: uintptr(91)
	SYS_mprotect :: uintptr(125)
	SYS_mremap  :: uintptr(163)
	SYS_madvise :: uintptr(219)
} else when ODIN_ARCH == .riscv64 {
	SYS_openat :: uintptr(56)
	SYS_read   :: uintptr(63)
	SYS_close  :: uintptr(57)

	SYS_mmap    :: uintptr(222)
	SYS_munmap  :: uintptr(215)
	SYS_mprotect :: uintptr(226)
	SYS_mremap  :: uintptr(216)
	SYS_madvise :: uintptr(233)
} else {
	#panic("Syscall numbers related to virtual memory are missing for this Linux architecture.")
}

PROT_NONE      :: 0x00
PROT_READ      :: 0x01
PROT_WRITE     :: 0x02

MAP_PRIVATE    :: 0x02
MAP_ANONYMOUS  :: 0x20

MREMAP_MAYMOVE :: 0x01

MADV_DONTNEED :: 0x04
MADV_HUGEPAGE :: 0x0E
MADV_NOHUGEPAGE :: 0x0F
MADV_GUARD_INSTALL :: 0x66

/*
ThreadSanitizer tracks mappings through its libc interceptors for `mmap`,
`munmap`, and `mprotect`. Those calls use libc when ThreadSanitizer is enabled;
all other virtual-memory operations use system calls directly. Compiler-rt
guards these interceptors with `SANITIZER_INTERCEPT_MMAP` and registers all
three in `INIT_MMAP` (`sanitizer_platform_interceptors.h:545` and
`sanitizer_common_interceptors.inc:7764-7767`).
*/
when .Thread in ODIN_SANITIZER_FLAGS {
	foreign {
		@(link_name="mmap")    c_mmap    :: proc "c" (addr: rawptr, length: uint, prot, flags, fd: i32, offset: i64) -> rawptr ---
		@(link_name="munmap")  c_munmap  :: proc "c" (addr: rawptr, length: uint) -> i32 ---
		@(link_name="mprotect") c_mprotect :: proc "c" (addr: rawptr, length: uint, prot: i32) -> i32 ---
	}
}

/*
Map `size` bytes of zeroed memory, readable and writable.
*/
vm_map :: proc "contextless" (size: int) -> (memory: rawptr, ok: bool) {
	when .Thread in ODIN_SANITIZER_FLAGS {
		result := c_mmap(nil, uint(size), PROT_READ|PROT_WRITE, i32(MAP_ANONYMOUS|MAP_PRIVATE), -1, 0)
		ok = result != nil && uintptr(result) != ~uintptr(0)
		memory = result
	} else {
		result := intrinsics.syscall(SYS_mmap, 0, uintptr(size), PROT_READ|PROT_WRITE, MAP_ANONYMOUS|MAP_PRIVATE, ~uintptr(0), 0)
		ok = int(result) >= 0
		memory = rawptr(result)
	}
	return
}

/*
Return the memory to the operating system.
*/
vm_unmap :: proc "contextless" (memory: rawptr, size: int) {
	when .Thread in ODIN_SANITIZER_FLAGS {
		c_munmap(memory, uint(size))
	} else {
		intrinsics.syscall(SYS_munmap, uintptr(memory), uintptr(size))
	}
}

/*
Move or resize memory previously returned by `vm_map`.
*/
vm_remap :: proc "contextless" (memory: rawptr, old_size, new_size: int, may_move: bool) -> (moved: rawptr, ok: bool) {
	flags := uintptr(0)
	if may_move {
		flags = MREMAP_MAYMOVE
	}
	result := intrinsics.syscall(SYS_mremap, uintptr(memory), uintptr(old_size), uintptr(new_size), flags)
	ok = int(result) >= 0
	moved = rawptr(result)
	return
}

/*
Guard `memory` so that any access faults, without splitting the mapping the
way `mprotect` does. Returns false on kernels older than Linux 6.10, and the
caller falls back to protecting the page.
*/
vm_guard_pages :: proc "contextless" (memory: rawptr, size: int) -> (guarded: bool) {
	return int(intrinsics.syscall(SYS_madvise, uintptr(memory), uintptr(size), MADV_GUARD_INSTALL)) == 0
}

/*
Advise the kernel that `memory` is worth backing with transparent huge pages.
Kernels without support ignore it.
*/
vm_advise_hugepages :: proc "contextless" (memory: rawptr, size: int) {
	intrinsics.syscall(SYS_madvise, uintptr(memory), uintptr(size), MADV_HUGEPAGE)
}

/*
Advise the kernel that `memory` is not worth backing with transparent huge
pages. On a machine with collapsing set to `always` this is what keeps a
sparsely used Segment from being filled in whole the first time any part of
it is touched. Kernels without support ignore it.
*/
vm_avoid_hugepages :: proc "contextless" (memory: rawptr, size: int) {
	intrinsics.syscall(SYS_madvise, uintptr(memory), uintptr(size), MADV_NOHUGEPAGE)
}

/*
Give the pages backing `memory` back to the operating system, which reads as
zero the next time it is used.
*/
vm_release_pages :: proc "contextless" (memory: rawptr, size: int) -> (released: bool) {
	return int(intrinsics.syscall(SYS_madvise, uintptr(memory), uintptr(size), MADV_DONTNEED)) == 0
}

_init_virtual_memory :: proc "contextless" () {
	page_size = _get_page_size()
	superpage_size = _get_superpage_size()
}

_get_page_size :: proc "contextless" () -> int {
	// This is a fallback value if the auxiliary vector does not supply it.
	DEFAULT_PAGE_SIZE :: 4096

	if value, found := _get_auxiliary(.AT_PAGESZ); found {
		return int(value.a_val)
	} else {
		return DEFAULT_PAGE_SIZE
	}
}

_get_superpage_size :: proc "contextless" () -> int {
	meminfo: cstring = "/proc/meminfo"

	when ODIN_ARCH == .arm64 || ODIN_ARCH == .riscv64 {
		AT_FDCWD :: ~uintptr(99) // -100
		fd := cast(int)intrinsics.syscall(SYS_openat, AT_FDCWD, transmute(uintptr)meminfo, 0 /* flags */, 0 /* mode */)
	} else {
		fd := cast(int)intrinsics.syscall(SYS_open, transmute(uintptr)meminfo, 0 /* flags */, 0 /* mode */)
	}
	if fd < 0 {
		// Error on opening file.
		return 0
	}
	defer intrinsics.syscall(SYS_close, uintptr(fd))

	buf: [4096]u8
	read := cast(int)intrinsics.syscall(SYS_read, cast(uintptr)fd, cast(uintptr)&buf[0], len(buf))
	if read <= 0 {
		// Failed to read anything.
		return 0
	}

	// Only one line of the file is of interest, e.g. "Hugepagesize:       2048 kB".
	// Anything unparseable means no superpage, which the caller handles by
	// falling back to the default Segment size.
	KEY :: "Hugepagesize:"
	i := 0
	for i < read {
		if i + len(KEY) <= read && string(buf[i:i+len(KEY)]) == KEY {
			j := i + len(KEY)
			for j < read && buf[j] == ' ' {
				j += 1
			}
			bytes := 0
			digits := 0
			// Ten digits always fit; no superpage needs more.
			for j < read && digits < 10 && '0' <= buf[j] && buf[j] <= '9' {
				bytes = bytes*10 + int(buf[j]-'0')
				digits += 1
				j += 1
			}
			if digits == 0 {
				return 0
			}
			if j < read && buf[j] == ' ' {
				j += 1
			}
			// A hostile value yields no superpage, not a wrap.
			mult := 0
			if j + 2 <= read {
				switch string(buf[j:j+2]) {
				case "kB":
					mult = Kilobyte
				case "mB":
					mult = Megabyte
				case "gB":
					mult = Gigabyte
				}
			}
			if mult == 0 || bytes > max(int) / mult {
				return 0
			}
			return bytes * mult
		}
		// Not the line wanted; skip to the next one.
		for i < read && buf[i] != '\n' {
			i += 1
		}
		i += 1
	}
	return 0
}

_allocate_virtual_memory :: proc "contextless" (size: int) -> rawptr {
	result, ok := vm_map(size)
	if !ok {
		return nil
	}
	return result
}

_allocate_virtual_memory_superpage :: proc "contextless" () -> rawptr {
	// This depends on Transparent HugePage Support being enabled.
	result, ok := vm_map(superpage_size)
	if !ok {
		return nil
	}
	if uintptr(result) % uintptr(superpage_size) != 0 {
		// If THP support is not enabled, we may receive an address aligned to a
		// page boundary instead, in which case, we must manually align a new
		// address.
		_free_virtual_memory(result, superpage_size)
		return _allocate_virtual_memory_aligned(superpage_size, superpage_size)
	}
	return result
}

_allocate_virtual_memory_aligned :: proc "contextless" (size: int, alignment: int) -> rawptr {
	// The mapping below adds `alignment` to `size`, which must not wrap
	// (CWE-190). Fail clean with nil, as every caller already handles.
	if size > max(int) - alignment {
		return nil
	}
	if alignment <= page_size {
		// This is the simplest case.
		//
		// By virtue of binary arithmetic, any address aligned to a power of
		// two is necessarily aligned to all lesser powers of two, and because
		// mmap returns page-aligned addresses, we don't have to do anything
		// extra here.
		result, ok := vm_map(size)
		if !ok {
			return nil
		}
		return result
	}
	// We must over-allocate then adjust the address.
	mmap_result_raw, ok := vm_map(size + alignment)
	if !ok {
		return nil
	}
	mmap_result := uintptr(mmap_result_raw)
	assert_contextless(mmap_result % uintptr(page_size) == 0)
	modulo := mmap_result & uintptr(alignment-1)
	if modulo != 0 {
		// The address is misaligned, so we must return an adjusted address
		// and free the pages we don't need.
		delta := uintptr(alignment) - modulo
		adjusted_result := mmap_result + delta

		// Sanity-checking:
		// - The adjusted address is still page-aligned, so it is a valid argument for mremap and munmap.
		// - The adjusted address is aligned to the user's needs.
		assert_contextless(adjusted_result % uintptr(page_size) == 0)
		assert_contextless(adjusted_result % uintptr(alignment) == 0)

		// Round the delta to a multiple of the page size.
		delta = delta / uintptr(page_size) * uintptr(page_size)
		if delta > 0 {
			// Unmap the pages we don't need.
			vm_unmap(rawptr(mmap_result), int(delta))
		}

		// The pages past the end of the requested size are also given back, as
		// they would otherwise be leaked for the lifetime of the mapping.
		tail_pages := size / page_size * page_size
		if size % page_size != 0 {
			tail_pages += page_size
		}
		tail_start := adjusted_result + uintptr(tail_pages)
		tail_end   := mmap_result + uintptr(size + alignment)
		if tail_end > tail_start {
			vm_unmap(rawptr(tail_start), int(tail_end - tail_start))
		}

		return rawptr(adjusted_result)
	} else if size + alignment > page_size {
		// The address is coincidentally aligned as desired, but we have space
		// that will never be seen by the user, so we must free the backing
		// pages for it.
		start := size / page_size * page_size
		if size % page_size != 0 {
			start += page_size
		}
		length := size + alignment - start
		if length > 0 {
			vm_unmap(rawptr(mmap_result + uintptr(start)), int(length))
		}
	}
	return rawptr(mmap_result)
}

_free_virtual_memory :: proc "contextless" (ptr: rawptr, size: int) {
	vm_unmap(ptr, size)
}

_decommit_virtual_memory :: proc "contextless" (ptr: rawptr, size: int) -> (decommitted: bool) {
	// `MADV_DONTNEED` drops the pages, and the next access to the range is
	// served a fresh, zeroed page.
	return vm_release_pages(ptr, size)
}

_protect_virtual_memory :: proc "contextless" (ptr: rawptr, size: int) -> (protected: bool) {
	// A page with no access faults on any read or write, and is released along
	// with the rest of the mapping it is in.
	when .Thread in ODIN_SANITIZER_FLAGS {
		return c_mprotect(ptr, uint(size), PROT_NONE) == 0
	} else {
		return int(intrinsics.syscall(SYS_mprotect, uintptr(ptr), uintptr(size), PROT_NONE)) == 0
	}
}

_resize_virtual_memory_in_place :: proc "contextless" (ptr: rawptr, old_size: int, new_size: int) -> (resized: bool) {
	// `mremap` without `MREMAP_MAYMOVE` either extends the mapping where it is
	// or fails, which is exactly what is being asked for here.
	moved, ok := vm_remap(ptr, old_size, new_size, false)
	return ok && moved == ptr
}

_resize_virtual_memory :: proc "contextless" (ptr: rawptr, old_size: int, new_size: int, alignment: int) -> rawptr {
	if alignment == 0 {
		// The user does not care about alignment, which is the simpler case.
		result, ok := vm_remap(ptr, old_size, new_size, true)
		if !ok {
			return nil
		}
		return result
	} else {
		// First, let's try to resize the memory in place. We might get lucky
		// and the operating system could expand (or shrink, as the case may be)
		// the pages without moving them, which means we don't have to allocate
		// a whole new chunk of memory.
		if result, ok := vm_remap(ptr, old_size, new_size, false); ok {
			return result
		}

		// The memory could not be resized in place, which means we must
		// allocate an entirely new aligned chunk of memory, copy the old data,
		// and free the old pointer before returning the new one.
		//
		// This is costly but unavoidable with the API available to us.
		result := _allocate_virtual_memory_aligned(new_size, alignment)
		if result == nil {
			return nil
		}
		intrinsics.mem_copy_non_overlapping(result, ptr, min(new_size, old_size))
		_free_virtual_memory(ptr, old_size)
		return result
	}
}
