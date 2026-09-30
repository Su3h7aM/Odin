#+build !js
#+build !orca
#+build !wasi
package runtime

import "base:intrinsics"
import "base:runtime"

/*
Heap_Info provides metrics on a single thread's heap memory usage.

`total_memory_allocated_from_system`
  = `total_memory_used_for_book_keeping`
  + `total_memory_in_use`
  + `total_memory_free`

NOTE: `total_memory_used_by_huge_segments` highlights how much memory is used
by the Huge class of allocations and is not part of any equation.
*/
Heap_Info :: struct {
	total_memory_allocated_from_system: int `fmt:"M"`,
	total_memory_used_for_book_keeping: int `fmt:"M"`,
	total_memory_used_by_huge_segments: int `fmt:"M"`,
	total_memory_in_use:                int `fmt:"M"`,
	total_memory_free:                  int `fmt:"M"`,
	total_memory_dirty:                 int `fmt:"M"`,

	total_segments:       int,
	total_small_segments: int,
	total_large_segments: int,
	total_huge_segments:  int,

	total_orphaned_in_use_segments: int,
	total_orphaned_empty_segments:  int,

	total_heap_remote_frees: int,
	total_slabs:             int,

	total_free_slabs_by_class: [1+int(max(Heap_Slab_Class))]int,
	
	slabs_by_rank: [runtime.ODIN_HEAP_BIN_RANKS]struct {
		total_memory_in_use: int `fmt:"M"`,

		total_slabs:         int,
		total_bins_in_use:   int,
		total_free_bins:     int,
		total_dirty_bins:    int,
		total_bins:          int,
	},

	peak_memory: int `fmt:"M"`,
}

/*
Get information about the current thread's heap.
*/
@(require_results)
get_local_heap_info :: proc "contextless" () -> (info: Heap_Info) {
	exists_in_list :: proc "contextless" (list: ^Heap_Slab, value: ^Heap_Slab) -> bool {
		for slab := list; slab != nil; slab = slab.next_slab {
			if slab == value {
				return true
			}
		}
		return false
	}

	if local_heap == nil {
		return
	}

	// Merge the frees which other threads left behind, and report on them as they
	// are merged, as this is the only place which counts them.
	heap_merge_remote_frees(&info.total_heap_remote_frees)

	total_slabs_seen: int

	// Get info on the segments.
	//
	// Every Slab the heap owns is accounted for here, by walking the Slabs of
	// each Segment rather than by walking the `free_slabs` and `slabs_by_rank`
	// lists. A Slab whose bins have all been handed out is deliberately taken
	// off its rank's list so that no allocation can find it, so those lists do
	// not hold every Slab the heap has and cannot be used to account for its
	// memory.
	for segment := local_heap.segments; segment != nil; segment = segment.next_segment {
		assert_contextless(intrinsics.atomic_load_explicit(&segment.owner, .Acquire) == get_current_thread_id(), "A segment has been found in this thread's heap that does not belong to it.")
		assert_contextless(intrinsics.atomic_load_explicit(&segment.heap, .Acquire) == local_heap, "A segment has been found in this heap that has not been assigned to it.")

		info.total_slabs += len(segment.slabs)
		info.total_memory_allocated_from_system += segment.size
		info.total_memory_used_for_book_keeping += int(uintptr(segment.slabs[0].data) - uintptr(segment))
		info.total_segments += 1

		switch segment.slab_size_class {
		case .Small:
			info.total_small_segments += 1
		case .Large:
			info.total_large_segments += 1
		case .Huge:
			// A Huge allocation has a Segment to itself, sized for it exactly.
			total_slabs_seen += 1
			info.total_huge_segments += 1
			info.total_memory_in_use += segment.slabs[0].bin_size
			info.total_memory_dirty  += segment.slabs[0].bin_size
			info.total_memory_used_for_book_keeping += ODIN_HEAP_MAX_ALIGNMENT - segment.padding
			info.total_memory_used_for_book_keeping += segment.size - (
				int(uintptr(segment.slabs[0].data) - uintptr(segment)) +
				ODIN_HEAP_MAX_ALIGNMENT - segment.padding +
				segment.slabs[0].bin_size
			)
			info.total_memory_used_by_huge_segments += segment.slabs[0].bin_size
			continue
		}

		for &slab in segment.slabs {
			total_slabs_seen += 1

			if slab.bin_size == 0 {
				// The Slab holds nothing, so all of its capacity is free, and it
				// waits on the free list for its Segment's size class.
				assert_contextless(exists_in_list(local_heap.free_slabs[segment.slab_size_class], &slab), "The heap allocator found a Slab with no bin size that is not on the free list for its size class.")
				info.total_free_slabs_by_class[segment.slab_size_class] += 1
				info.total_memory_free += slab.capacity
				continue
			}

			in_use := slab.max_bins - slab.free_bins
			rank := heap_bin_size_to_rank(slab.bin_size)

			info.total_memory_in_use += in_use * slab.bin_size
			info.total_memory_free   += slab.capacity - in_use * slab.bin_size

			info.slabs_by_rank[rank].total_memory_in_use += in_use * slab.bin_size
			info.slabs_by_rank[rank].total_slabs       += 1
			info.slabs_by_rank[rank].total_bins_in_use += in_use
			info.slabs_by_rank[rank].total_free_bins   += slab.free_bins
			info.slabs_by_rank[rank].total_dirty_bins  += slab.used_bins
			info.slabs_by_rank[rank].total_bins        += slab.max_bins

			if slab.free_bins > 0 {
				// The Slab has bins to hand out, so it is on the list for its
				// rank. A Slab whose bins have all been handed out is not on any
				// list, and is put back the next time one of its bins is freed.
				assert_contextless(slab.bin_rank == rank, "A ranked slab has been found with the wrong rank.")
				assert_contextless(exists_in_list(local_heap.slabs_by_rank[rank], &slab), "The heap allocator found a Slab with free bins that is not on the list for its rank.")
			}
		}
	}

	info.peak_memory = local_heap.peak_memory

	// The orphanage holds no thread's heap, so the walk above never sees it.
	// Both counts are approximate under concurrency; the empty count is read
	// from the list's embedded tag, the in-use count from its own counter.
	info.total_orphaned_in_use_segments = intrinsics.atomic_load_explicit(&heap_orphanage.in_use_count, .Relaxed)
	empty_head := transmute(Tagged_Pointer)intrinsics.atomic_load_explicit(cast(^u64)&heap_orphanage.empty, .Relaxed)
	info.total_orphaned_empty_segments = int(uintptr(empty_head.pointer) & uintptr(ODIN_HEAP_ORPHANAGE_COUNT_BITS))

	assert_contextless(info.total_memory_allocated_from_system == info.total_memory_used_for_book_keeping + info.total_memory_in_use + info.total_memory_free,
		"The heap allocator's metrics for total memory in use, free, and used for book-keeping do not add up to the total memory allocated from the operating system for this thread.")
	assert_contextless(info.total_slabs == total_slabs_seen, "There is a discrepancy between the number of slabs seen during iteration and the number that should be there based on the segments iterated.")

	return
}
