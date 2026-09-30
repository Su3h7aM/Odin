#+build !js
#+build !orca
#+build !wasi
package runtime

import "base:intrinsics"

@(require_results)
heap_allocator :: proc() -> Allocator {
	return Allocator{
		procedure = heap_allocator_proc,
		data = nil,
	}
}

heap_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, Allocator_Error) {
	assert(alignment >= 0, "Alignment must be greater than or equal to zero.", loc = loc)

	// A negative size, a non-binary alignment, or an alignment beyond what a bin
	// can give can never be satisfied, so fail with Invalid_Argument in every
	// build rather than hand back a misaligned address.
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if size < 0 || alignment > ODIN_HEAP_MAX_ALIGNMENT || (alignment != 0 && !is_power_of_two_int(alignment)) {
			return nil, .Invalid_Argument
		}
	case .Free, .Free_All, .Query_Features, .Query_Info:
	}
	switch mode {
	case .Alloc:
		// All allocations are aligned to at least their size up to
		// `HEAP_MAX_ALIGNMENT`, and by virtue of binary arithmetic, any
		// address aligned to N will also be aligned to N>>1.
		//
		// Therefore, we have no book-keeping costs for alignment.
		ptr := heap_alloc(max(size, alignment))
		if ptr == nil {
			return nil, .Out_Of_Memory
		}
		return transmute([]byte)Raw_Slice{ data = ptr, len = size }, nil
	case .Alloc_Non_Zeroed:
		ptr := heap_alloc(max(size, alignment), zero_memory = false)
		if ptr == nil {
			return nil, .Out_Of_Memory
		}
		return transmute([]byte)Raw_Slice{ data = ptr, len = size }, nil
	case .Resize:
		ptr := heap_resize(old_memory, old_size, max(size, alignment))
		if ptr == nil {
			return nil, .Out_Of_Memory
		}
		return transmute([]byte)Raw_Slice{ data = ptr, len = size }, nil
	case .Resize_Non_Zeroed:
		ptr := heap_resize(old_memory, old_size, max(size, alignment), zero_memory = false)
		if ptr == nil {
			return nil, .Out_Of_Memory
		}
		return transmute([]byte)Raw_Slice{ data = ptr, len = size }, nil
	case .Free:
		heap_free(old_memory)
	case .Free_All:
		return nil, .Mode_Not_Implemented
	case .Query_Features:
		set := (^Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {
				.Alloc,
				.Alloc_Non_Zeroed,
				.Resize,
				.Resize_Non_Zeroed,
				.Free,
				.Query_Features,
			}
		}
		return nil, nil
	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, nil
}
