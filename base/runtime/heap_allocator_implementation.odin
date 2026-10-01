#+build !js
#+build !orca
#+build !wasi
package runtime

import "base:intrinsics"
import "base:sanitizer"

/*
This is the dynamic heap allocator for the Odin runtime.

**Features**

- Lock-free guarantee: A thread cannot deadlock or obstruct the allocator;
  some thread makes progress no matter the parallel conditions.

- Thread-local heaps: There is no allocator-induced false sharing.

- Global storage for unused memory: When a thread finishes cleanly, its memory
  is sent to the orphanage where other threads can use it. When an entire
  segment is freed, the orphanage will hold some in reserve to prevent too many
  requests to the operating system for virtual memory.

- Headerless: Except for the heap metadata needed to support them, each
  allocation consumes no extra space, and as a result of being tightly packed,
  performance is enhanced with cache locality for programs.


**Debugging Features**

The following guards are present when AddressSanitizer (`-sanitize:address`)
is enabled. When one of these events is caught, the program will panic with a
descriptive message and produce a core dump.

- Double Free: Memory that is going to be freed will be checked if it was marked previously.

- Invalid Free: Pointers will be checked upon freeing to see if they address
  an area marked by the sanitizer to prevent freeing invalid memory.

- Use-After-Free: Most importantly, memory that has been freed will be marked
  with the sanitizer, preventing its re-use. This also prevents any free list
  corruption of the heap allocator.

- Buffer Overflows: All allocations will be boxed off into marked sections,
  causing a warning if any read or write access happens beyond the specific range
  of memory allotted.


**Terminology**

- Segment: a single contiguous allocation from the operating system that
  contains metadata about its allocations and is divided into at least one Slab.

- Slab: a fixed-size block within a Segment that is divided into a constant
  number of Bins at runtime based on the needs of the program.

- Bin: an allocation of a fixed power-of-two size, shared with others of the
  same size category. These fixed size categories are called ranks.


**Size Classes**

Segments are divided based on the initial allocation request which causes them
to be needed.

For example, an allocation of 8 bytes will cause a Segment of Small Slabs to be
made to support it, and an allocation of 128KiB will cause a Segment of Large
Slabs to be made.

Each Segment is subdivided to support as many Slabs as can be held, except for
allocations over 512KiB; those are given their own single-Slab Segment and are
returned to the operating system immediately upon freeing.

- Small: Allocations <= 8KiB are placed into Small-subdivided Segments.
- Large: Allocations <= 512KiB are placed into Large-subdivided Segments.
- Huge:  Allocations >  512KiB are given their own single-Slab Segment.
*/

//
// Tunables
//

/*
`ODIN_HEAP_SEGMENT_SIZE_OVERRIDE` controls how many bytes are allocated for each heap segment.

The default value of zero causes the allocator to use the superpage size of operating system.
*/
ODIN_HEAP_SEGMENT_SIZE_OVERRIDE :: #config(ODIN_HEAP_SEGMENT_SIZE_OVERRIDE, 0 /* bytes */)

/*
`ODIN_HEAP_MAX_EMPTY_ORPHANED_SEGMENTS` controls how many empty segments are kept on
hand for re-use instead of being immediately returned to the operating system.
*/
ODIN_HEAP_MAX_EMPTY_ORPHANED_SEGMENTS :: #config(ODIN_HEAP_MAX_EMPTY_ORPHANED_SEGMENTS, 5 /* segments */)

/*
`ODIN_HEAP_DEBUG_LEVEL` controls exactly how much debug checking the allocator will
do. The levels are ordered from increasing levels of computational complexity
and the higher the level, the slower the program will run.
*/
ODIN_HEAP_DEBUG_LEVEL :: Heap_Debug_Level(HEAP_DEBUG_LEVEL)
@(private="file")
HEAP_DEBUG_LEVEL :: #config(ODIN_HEAP_DEBUG_LEVEL, 3 when .Address in ODIN_SANITIZER_FLAGS else 2 when ODIN_DEBUG else 0)

/*
`ODIN_HEAP_SECURE` turns on the protections that cost more than a comparison of
fields the allocator already holds, for programs which may be attacked through
the heap.

Every build refuses an address which is not a bin of this heap, a size larger
than the bin, a bin freed twice in a row, and a free-list link which is not
aligned or points outside its Slab, so the worst a forged link can do is
overlap two allocations of one Slab. On top of that, a secure build:

- masks each free-list link with the address it is stored at, so a write
  through a stale pointer cannot name an address without knowing where the link is,
- keeps a key in every free bin with room for one, so a bin freed twice with
  others freed in between is found,
- puts a page that faults after each Huge allocation, so an overflow off its end
  does not reach the mapping that follows, and gives up growing one in place,
  which could not keep that page at its end.

These are the same protections mimalloc keeps behind `MI_SECURE`, and like
there, they are off by default: they cost about a nanosecond per free and a
system call per Huge allocation. Nothing in them is random, so a secure heap
is as deterministic as any other.
*/
ODIN_HEAP_SECURE :: #config(ODIN_HEAP_SECURE, false)

/*
`ODIN_HEAP_MIN_BIN_SIZE` and `ODIN_HEAP_MAX_BIN_SIZE` control the range of the size of
the bins in power-of-two intervals from each other as an inclusive range.

Below `ODIN_HEAP_MIN_BIN_SIZE`, all requests are rounded up to the minimum.
Beyond `ODIN_HEAP_MAX_BIN_SIZE`, all requests are given their own specifically-sized allocation.
*/
ODIN_HEAP_MIN_BIN_SIZE :: #config(ODIN_HEAP_MIN_BIN_SIZE, 8 * Byte)
ODIN_HEAP_MAX_BIN_SIZE :: #config(ODIN_HEAP_MAX_BIN_SIZE, 512 * Kilobyte) // [n..=m] inclusive range

/*
`ODIN_HEAP_MAX_ALIGNMENT` controls the maximum supported alignment.
*/
ODIN_HEAP_MAX_ALIGNMENT :: #config(ODIN_HEAP_MAX_ALIGNMENT, 64 * Byte)

/*
`ODIN_HEAP_SUPERPAGES` controls whether a Segment is given over to the operating
system's largest pages.

A superpage holds one address translation for a large amount of memory, which
saves the processor work while that memory is in use, and brings that memory in
for a fraction of what a page at a time costs. The price is that touching any
part of one makes the whole thing resident.

That price is only worth paying for memory the program is going to use, so a
Segment is given large pages once the heap is already handing out that kind of
Segment's worth of allocated bins and they are densely used. Everything else
stays on ordinary pages and costs only what it touches.

Turning this off keeps every Segment on ordinary pages.
*/
ODIN_HEAP_SUPERPAGES :: #config(ODIN_HEAP_SUPERPAGES, true)

/*
`ODIN_HEAP_SUPERPAGE_THRESHOLD` is how many bytes of allocated bins a heap must be
handing out in Segments of the kind it is about to make before the new one is
given over to the operating system's largest pages.

The default of zero means two Segments' worth. One Segment's worth is not enough
of an answer to the question the threshold is asking, which is whether this kind
of Segment gets filled: a Segment can be entirely given over to Slabs and still
hold little, one Segment per Bin size above 8 KiB is easy to reach with a handful
of allocations, and a single Segment's worth of bins can therefore be evidence
that the heap is using a lot of address space for very little. Two Segments'
worth is past the point where that is so.

A larger value makes the heap more reluctant to use large pages; a value no
program reaches leaves them to allocations the size of a Segment or more.
*/
ODIN_HEAP_SUPERPAGE_THRESHOLD :: #config(ODIN_HEAP_SUPERPAGE_THRESHOLD, 0 /* bytes, 0 means two Segments */)

/*
`ODIN_HEAP_SMALL_SLAB_SIZE` controls the cut-off for Segments with Small Slabs.
Any allocation below `ODIN_HEAP_SMALL_BIN_MAX` will be placed into Slabs of this size.

Beyond that, allocations are placed into Large Slabs that consume an entire
Segment for the power-of-two size request. For example, an allocation of 16KiB
will result in a Segment that has been partitioned with only one Slab but may
use the entire width of the Slab space for any allocation that rounds to 16KiB.
*/
ODIN_HEAP_SMALL_SLAB_SIZE :: #config(ODIN_HEAP_SMALL_SLAB_SIZE, 64 * Kilobyte)
ODIN_HEAP_SMALL_BIN_MAX   :: #config(ODIN_HEAP_SMALL_BIN_MAX, 8 * Kilobyte) // [0..=m] inclusive range

/*
`ODIN_HEAP_PURGE_INTERVAL` controls how many frees may pass before the heap
hands the pages of its empty Segments back. Purging on every free would fault
them straight back in under steady churn; never purging would keep idle pages
resident until the heap grows again.
*/
ODIN_HEAP_PURGE_INTERVAL :: #config(ODIN_HEAP_PURGE_INTERVAL, 1024 /* frees */)
//
// Constants
//

ODIN_HEAP_SEGMENT_SIZE  :: 4 * Megabyte

// An address is turned back into its Segment by masking the low bits, so every
// Segment is the same size and that size is a power of two. It also has to be
// large enough to hold a Slab of the largest Bin size, which spans the whole
// Segment, along with the book-keeping that sits in front of a Slab's data. This
// is the smallest power of two that does both.
ODIN_HEAP_MIN_SEGMENT_SIZE :: ODIN_HEAP_MAX_BIN_SIZE * 2
ODIN_HEAP_MIN_BIN_SHIFT :: intrinsics.constant_log2(ODIN_HEAP_MIN_BIN_SIZE)
ODIN_HEAP_MAX_BIN_SHIFT :: intrinsics.constant_log2(ODIN_HEAP_MAX_BIN_SIZE)
ODIN_HEAP_BIN_RANKS     :: 1 + ODIN_HEAP_MAX_BIN_SHIFT - ODIN_HEAP_MIN_BIN_SHIFT

// This mask is used to store an atomic count within a `Tagged_Pointer` to
// limit the number of empty Segments sent into the orphanage.
ODIN_HEAP_ORPHANAGE_COUNT_BITS :: 0xFFFF

Heap_Debug_Level :: enum {
	// No extra work is done beyond the sanity checking in the assertion statements.
	None          = 0,

	// Some allocation statistics are monitored in real-time.
	Statistics    = 1,

	// This level makes sure that each new allocation on an untouched slab is
	// completely zero, and that the free list link inside a freed bin is intact
	// when the bin is handed out again.
	Ensure_Zero   = 2,

	// This level forbids allocations from residing next to each other,
	// allowing the address sanitizer to detect buffer overflows and underflows
	// by virtue of its memory poisoning feature.
	//
	// This works by spacing out each allocation by `[size..=ODIN_HEAP_MAX_ALIGNMENT]`
	// bytes and having the sanitizer keep the boundaries between allocations poisoned.
	//
	// A simple diagram for an 8 byte slab is as follows:
	//
	// [0x00 :: bin 1] [0x08 :: POISONED] [0x10 :: bin 2] [0x18 :: POISONED]
	//
	// Normally the poisoned areas would be used for extra bins, thus this
	// level consumes some extra amount of memory per slab. However, no more
	// than `ODIN_HEAP_MAX_ALIGNMENT` bytes will be used to pad out the
	// allocations, as this is our guaranteed alignment.
	//
	// NOTE: `-sanitize:address` must be passed for this to be effective.
	Buffer_Overflow = 3,
}

//
// Sanity checking
//

#assert(ODIN_HEAP_DEBUG_LEVEL < .Buffer_Overflow || .Address in ODIN_SANITIZER_FLAGS, "AddressSanitizer must be enabled if ODIN_HEAP_DEBUG_LEVEL is set to the Buffer_Overflow level.")
#assert(ODIN_HEAP_SEGMENT_SIZE_OVERRIDE & (ODIN_HEAP_SEGMENT_SIZE_OVERRIDE-1) == 0, "ODIN_HEAP_SEGMENT_SIZE_OVERRIDE must be a power of two.")
#assert(ODIN_HEAP_SEGMENT_SIZE_OVERRIDE == 0 || ODIN_HEAP_SEGMENT_SIZE_OVERRIDE > ODIN_HEAP_ORPHANAGE_COUNT_BITS, "ODIN_HEAP_SEGMENT_SIZE_OVERRIDE must be larger than ODIN_HEAP_ORPHANAGE_COUNT_BITS.")
#assert(ODIN_HEAP_MIN_BIN_SIZE & (ODIN_HEAP_MIN_BIN_SIZE-1) == 0, "ODIN_HEAP_MIN_BIN_SIZE must be a power of two.")
#assert(ODIN_HEAP_MAX_BIN_SIZE & (ODIN_HEAP_MAX_BIN_SIZE-1) == 0, "ODIN_HEAP_MAX_BIN_SIZE must be a power of two.")
#assert(ODIN_HEAP_MIN_BIN_SIZE >= size_of(rawptr), "ODIN_HEAP_MIN_BIN_SIZE must be large enough to hold a pointer for the free lists.")
#assert(ODIN_HEAP_MIN_BIN_SIZE >= 8 || .Address not_in ODIN_SANITIZER_FLAGS, "ODIN_HEAP_MIN_BIN_SIZE must be large enough to satisfy AddressSanitizer's alignment requirement.")
#assert(ODIN_HEAP_MAX_BIN_SIZE >= ODIN_HEAP_MIN_BIN_SIZE, "ODIN_HEAP_MAX_BIN_SIZE must be greater than or equal to ODIN_HEAP_MIN_BIN_SIZE.")
#assert(ODIN_HEAP_MAX_EMPTY_ORPHANED_SEGMENTS >= 0, "ODIN_HEAP_MAX_EMPTY_ORPHANED_SEGMENTS must be positive.")
#assert(ODIN_HEAP_MAX_EMPTY_ORPHANED_SEGMENTS < ODIN_HEAP_ORPHANAGE_COUNT_BITS, "ODIN_HEAP_MAX_EMPTY_ORPHANED_SEGMENTS is too great.")
#assert(ODIN_HEAP_MAX_ALIGNMENT & (ODIN_HEAP_MAX_ALIGNMENT-1) == 0, "ODIN_HEAP_MAX_ALIGNMENT must be a power of two.")
#assert(ODIN_HEAP_PURGE_INTERVAL >= 0, "ODIN_HEAP_PURGE_INTERVAL must be positive.")

//
// Utility Procedures
//

Heap_Slab_Class :: enum {
	Small, // Slabs are `ODIN_HEAP_SMALL_SLAB_SIZE` (64KiB) each.
	Large, // One segment-wide (platform-dependent size) slab.
	Huge,  // One slab for one allocation, sized specifically for the request.
}

/*
Get what Slab size class a `bytes` sized allocation should go to.
*/
@(require_results)
heap_get_size_class :: #force_inline proc "contextless" (bytes: int) -> Heap_Slab_Class {
	if bytes <= ODIN_HEAP_SMALL_BIN_MAX {
		return .Small
	} else if bytes <= ODIN_HEAP_MAX_BIN_SIZE {
		return .Large
	} else {
		return .Huge
	}
}

/*
The distance between the start of one bin of `bin_size` and the next within a
Slab.

When the address sanitizer is asked to keep the boundaries between bins
poisoned, every bin is followed by up to `ODIN_HEAP_MAX_ALIGNMENT` poisoned
bytes, which is what the bins are spaced apart by.
*/
@(require_results)
heap_bin_stride :: #force_inline proc "contextless" (bin_size: int) -> int {
	when ODIN_HEAP_DEBUG_LEVEL >= .Buffer_Overflow {
		return bin_size + min(bin_size, ODIN_HEAP_MAX_ALIGNMENT)
	} else {
		return bin_size
	}
}

/*
Settle the size every Segment has, once. Every path that maps a Segment comes
through here, since global initializers may allocate before runtime init runs.
*/
heap_ensure_segment_size :: #force_inline proc "contextless" () {
	when ODIN_HEAP_SEGMENT_SIZE_OVERRIDE == 0 {
		if segment_size == 0 {
			if page_size == 0 {
				_init_virtual_memory()
			}
			segment_size = heap_choose_segment_size()
		}
	}
}

/*
Allocate a new Segment that may be used to store either Small or Large slabs.
*/
@(require_results)
heap_allocate_segment :: #force_inline proc "contextless" () -> ^Heap_Segment {
	heap_ensure_segment_size()

	size := heap_get_segment_size()
	if size == superpage_size {
		// A Segment is exactly one of the operating system's largest pages, so
		// it can be asked for as one.
		return cast(^Heap_Segment)allocate_virtual_memory_superpage()
	}
	return cast(^Heap_Segment)allocate_virtual_memory_aligned(size, size)
}

/*
Take the size that every Segment will have.

The operating system's largest pages make a good Segment size when one of them
fits the range a Segment has to be in, because then a Segment is exactly one of
them. A machine whose pages are outside that range gets `ODIN_HEAP_SEGMENT_SIZE`
instead. That is the case that matters: a page size larger than a Segment has
reason to be would otherwise hand every Segment, and so every size class, an
enormous amount of address space, and a page size below the minimum cannot hold
the largest Slab at all.
*/
@(require_results)
heap_choose_segment_size :: proc "contextless" () -> int {
	when ODIN_HEAP_SEGMENT_SIZE_OVERRIDE != 0 {
		return ODIN_HEAP_SEGMENT_SIZE_OVERRIDE
	} else {
		size := superpage_size
		if size < ODIN_HEAP_MIN_SEGMENT_SIZE || size > ODIN_HEAP_SEGMENT_SIZE {
			return ODIN_HEAP_SEGMENT_SIZE
		}
		if size & (size-1) != 0 {
			// The book-keeping finds a Segment from an address by masking the
			// low bits, so a size that is not a power of two cannot be used.
			return ODIN_HEAP_SEGMENT_SIZE
		}
		return size
	}
}

/*
Get the size that all segments have. This size also dictates each segment's alignment.
*/
@(require_results)
heap_get_segment_size :: #force_inline proc "contextless" () -> int {
	when ODIN_HEAP_SEGMENT_SIZE_OVERRIDE != 0 {
		return ODIN_HEAP_SEGMENT_SIZE_OVERRIDE
	} else {
		if size := segment_size; size != 0 {
			return size
		} else {
			return ODIN_HEAP_SEGMENT_SIZE
		}
	}
}

/*
Convert a rounded bin size to its integer rank.

This is used for the `Heap.slabs_by_rank` array of linked lists for fast lookup of slabs by the size they support.

For example, the default ranks are as follows:

[Small Slabs]
 -  0:       8
 -  1:      16
 -  2:      32
 -  3:      64
 -  4:     128
 -  5:     256
 -  6:     512
 -  7:   1_024
 -  8:   2_048
 -  9:   4_096
 - 10:   8_192

[Large Slabs]
 - 11:  16_384
 - 12:  32_768
 - 13:  65_536
 - 14: 131_072
 - 15: 262_144
 - 16: 524_288

Beyond this size, bins are not ranked; allocations use the Huge class and are made and freed on an as-needed basis.
*/
@(require_results)
heap_bin_size_to_rank :: proc "contextless" (bin_size: int) -> (rank: int) {
	// By this point, a size of zero should've been rounded up to ODIN_HEAP_MIN_BIN_SIZE.
	assert_contextless(ODIN_HEAP_MIN_BIN_SIZE <= bin_size && bin_size <= ODIN_HEAP_MAX_BIN_SIZE, "Bin size must be within [ODIN_HEAP_MIN_BINSIZE..=ODIN_HEAP_MAX_BIN_SIZE].")
	assert_contextless(bin_size & (bin_size-1) == 0, "Bin size must be a power of two.")

	rank = int(intrinsics.count_trailing_zeros(uint(bin_size)) - ODIN_HEAP_MIN_BIN_SHIFT)
	assert_contextless(0 <= rank && rank < ODIN_HEAP_BIN_RANKS, "The heap allocator miscalculated the bin rank; it must be within [0..<ODIN_HEAP_BIN_RANKS].")
	return 
}

/*
Round an integer from `2..<max(uint)` up to a power of two.
*/
@(private="file", require_results)
round_up_to_power_of_two :: proc "contextless" (n: int) -> int {
	assert_contextless(n > 1, "This procedure does not handle the edge case of n < 2.")
	return 1 << ((8 /* bits */ * size_of(int)) - intrinsics.count_leading_zeros(uint(n-1)))
}

/*
Round an arbitrary byte `size` up to a bin size that can fit it.
*/
@(require_results)
heap_round_to_bin_size :: proc "contextless" (size: int) -> (bin_size: int) {
	assert_contextless(0 <= size && size <= ODIN_HEAP_MAX_BIN_SIZE, "Size must be within [0..=ODIN_HEAP_MAX_BIN_SIZE].")
	bin_size = round_up_to_power_of_two(max(ODIN_HEAP_MIN_BIN_SIZE, size))
	assert_contextless(bin_size & (bin_size-1) == 0, "The heap allocator miscalculated the bin size; it must be a power of two.")
	return
}

/*
Calculate both the rounded bin size and the rank for an arbitrary byte `size`.
*/
@(require_results)
heap_calculate_sizes :: proc "contextless" (size: int) -> (bin_size, rank: int) {
	bin_size = heap_round_to_bin_size(size)
	rank = heap_bin_size_to_rank(bin_size)
	return
}

/*
Find which segment should own an address with bit masking.

This does not return a valid segment address if the address itself is invalid.
*/
@(require_results)
find_segment_from_pointer :: #force_inline proc "contextless" (ptr: rawptr) -> ^Heap_Segment {
	return cast(^Heap_Segment)(uintptr(ptr) & ~uintptr(heap_get_segment_size()-1))
}

// The first eight letters of "feoramalloc", the name of this allocator, in
// ASCII. Any fixed non-zero value would do: every Segment holds it mixed with
// its own address, which is how an address given to `free` or `resize` is told
// apart from one that never came from a Segment.
HEAP_SEGMENT_MAGIC :: 0x6665_6F72_616D_616C

@(require_results)
heap_segment_magic :: #force_inline proc "contextless" (segment: ^Heap_Segment) -> uintptr {
	return HEAP_SEGMENT_MAGIC ~ uintptr(segment)
}

/*
Find the segment of an address the program gave back, and check that it is one.

Memory which is not a Segment, such as a stack or another allocator's memory,
does not hold the magic value of the Segment it would be mistaken for, and the
allocator aborts rather than read a free list, a Slab or a size out of it.
*/
@(require_results, no_sanitize_address)
heap_find_segment_to_give_back :: #force_inline proc "contextless" (ptr: rawptr) -> ^Heap_Segment {
	segment := find_segment_from_pointer(ptr)
	ensure_contextless(segment.magic == heap_segment_magic(segment), "The heap allocator was given an address which does not belong to one of its Segments. It never came from this heap, or it was freed along with its Segment.")
	return segment
}

// The shift which keeps the link mask to the page an address is in. Bins in the
// same page of the smallest size share a mask.
HEAP_LINK_SHIFT :: 12

/*
Encode or decode a link between free bins, which is the same operation.

In a secure build a link is stored masked with the address it is stored at, so
that a write through a stale pointer or an overflow cannot name a chosen
address without knowing where the link is. The mask is a function of the
address alone, so the allocator stays deterministic. Otherwise a link is stored
as it is.
*/
@(require_results)
heap_mask_link :: #force_inline proc "contextless" (at: rawptr, link: uintptr) -> uintptr {
	when ODIN_HEAP_SECURE {
		return link ~ (uintptr(at) >> HEAP_LINK_SHIFT)
	} else {
		return link
	}
}

//
// Data Structures
//

// NOTE: No structure with atomic fields in this allocator should ever be
// made `#packed` without regard for alignment to the size of the pointer for
// each atomic field, as misaligned atomic access could cause issues on some
// architectures.

/*
The **Slab** is a division of a Segment, configured at runtime to
contain fixed-size allocations. It uses two free lists to keep track of the
state of its bins: whether a bin is locally free or remotely free.

It is a Slab allocator in its own right, hence the name.

Each allocation is self-aligned, up to an alignment size of `ODIN_HEAP_MAX_ALIGNMENT`
(64 bytes by default).

Remote threads push pointers onto `remote_free_list` in an atomic lock-free
manner: a Slab is written to by no thread but the one which owns the Heap it
belongs to, so a free from another thread is parked where it can always be
reached, and the thread which owns the Slab merges it at its next opportunity.

**Fields**:

`data` points to the first bin and is used for calculating bin positions.


`prev_slab` and `next_slab` are used when the Slab is added to a linked list.
This can be a linked list of Slabs with the same size or a linked list of free
Slabs on the heap.


`free_bins` counts the exact number of free bins known to the allocating
thread. This value does not yet include any remote frees.

`used_bins` tracks how many unused addresses have been given out, which is used
to find a fresh bin if there are no pointers on the free list.

`max_bins` is the number of maximum bins that can be allocated from this Slab.
It makes an inclusive range of `0..=n`.


`bin_size` tracks the precise byte size of the allocations.

`bin_rank` is the cached rank for the `bin_size`, kept for performance purposes.


`capacity` is how much space the Slab was given by the Segment when allocated.


`free_list` is either nil or points to one of the free bins, which itself may
point to another freed bin, creating a linked list within the Slab space. In a
secure build each link is masked by `heap_mask_link`, and a bin with room for
it also holds a key which marks it as free.

`remote_free_list` is an atomic linked list, serving the same role as
`free_list` but for other threads. It is the one field of a Slab which another
thread writes, and it is merged into `free_list` by the thread which owns the
Slab: before this heap asks the operating system for more memory, when memory is
given back, and as this heap's thread exits.
*/
Heap_Slab :: struct {
	data: uintptr,

	prev_slab: ^Heap_Slab,
	next_slab: ^Heap_Slab,

	free_bins: int,
	used_bins: int,
	max_bins: int,

	bin_size: int,
	bin_rank: int,

	capacity: int,

	free_list: ^uintptr,
	remote_free_list: Tagged_Pointer, // atomic
}

/*
The **Segment** is a single contiguous allocation from the operating system's
virtual memory subsystem, subdivided into Slabs. All metadata lives at the head
of the allocation.

Depending on the operating system, addresses within the space occupied by the
Segment (and hence its allocations) may also have faster access times due to
leveraging properties of the Translation Lookaside Buffer.

It is always aligned to `heap_get_segment_size()`, allowing any address
allocated from its space to look up the Segment in constant-time with bit
masking.

**Fields:**

`magic` is `heap_segment_magic` of this Segment, set when it is made, and is
what tells a Segment from any other memory an address might point into.

`owner` is the value of `get_current_thread_id` for the thread which owns this
Segment or zero if it is orphaned.

`heap` points to the `Heap` which owns this Segment or is nil if is orphaned.

`size` is the exact size of the Segment allocation, used when returning the
memory to the operating system.


`prev_segment` and `next_segment` are used to add the Segment into linked
lists, whether on a thread's heap or in the orphanage.

NOTE: `next_segment` is accessed with atomics only when engaging with the
orphanage, as that is the only time it should change in a parallel situation.
For all other cases, the thread which owns the Segment is the only one to read
this field.


`may_return` is a flag that is set to true after all Slabs have been used
at least once, used as a heuristic to prevent the allocator from freeing the
Segment too early to improve performance.

`is_clean` records that the data area was cleared by the last purge. It avoids
clearing it again while the Segment remains empty.


`slab_size_class` is the size class of each and every Slab, used for tracking
in what size intervals the Slabs are subdivided.

`slab_shift` is an unsigned integer that is used to shift an address to a bin,
minus the address to the Segment, to find which Slab the bin is in.


`padding` tracks how many bytes were used to get an alignment of
`ODIN_HEAP_MAX_ALIGNMENT` for the first bin. This is used to ensure all bytes
are accounted during the tally of `get_local_heap_info`.


`free_slabs` is the count of Slabs which are ready to use for new bin ranks.


`allocated_bins` is the count of bins which have been handed to the program
and not yet given back. A Segment without any of them is holding nothing but
empty space, so its pages may be returned to the operating system without the
program ever noticing. A bin freed by another thread stays counted until its
owner merges it, which is what keeps the Segment alive under such a free.

`slabs` is the slice of Slab metadata which contains pointers to each Slab's
starting address and byte capacity. This information is used to subdivide the
Slab when a request is made for a new bin rank.
*/
Heap_Segment :: struct {
	magic: uintptr,
	owner: int,  // atomic
	heap: ^Heap, // atomic
	size: int,

	prev_segment: ^Heap_Segment,
	next_segment: ^Heap_Segment,

	may_return: bool,
	is_clean: bool,

	slab_size_class: Heap_Slab_Class,
	slab_shift: uint,

	padding: int,

	free_slabs: int,
	allocated_bins: int,
	slabs: []Heap_Slab,
	/* ... the slab space itself ... */
}

// Sanity checking that could not be done where the rest of it is, because it
// needs the size of the book-keeping in front of a Slab's data.
#assert(ODIN_HEAP_MIN_SEGMENT_SIZE >= ODIN_HEAP_MAX_BIN_SIZE + size_of(Heap_Segment) + size_of(Heap_Slab) + ODIN_HEAP_MAX_ALIGNMENT, "ODIN_HEAP_MIN_SEGMENT_SIZE must have room for a Slab of the largest Bin size and the book-keeping in front of its data.")
#assert(ODIN_HEAP_SEGMENT_SIZE_OVERRIDE == 0 || ODIN_HEAP_SEGMENT_SIZE_OVERRIDE >= ODIN_HEAP_MIN_SEGMENT_SIZE, "ODIN_HEAP_SEGMENT_SIZE_OVERRIDE is set below ODIN_HEAP_MIN_SEGMENT_SIZE, the smallest size a Segment can have and still serve an allocation of ODIN_HEAP_MAX_BIN_SIZE.")

/*
`Heap` is a thread-local structure that is allocated upon the first allocation
for a thread and stores metadata relevant to the thread's allocator.

**Fields:**

`segments` is a linked list of Segments which belong to this heap.


`free_slabs` is an array of linked lists by Slab size class which store slabs
not in use.

NOTE: The `Heap_Slab_Class.Huge` entry exists for code simplicity. When a
Huge allocation is made, the Slab is immediately taken for the request, and the
Segment is sized for that request alone, so it is given back to the operating
system when the allocation is freed rather than kept. A Huge request does adopt
in-use Segments from the orphanage, because a heap which takes one over is one
which can manage its remote frees, but the Segments in the orphanage for empty
ones are laid out for the Small and Large classes and have nothing to offer it.


`slabs_by_rank` is an array of linked lists, each list containing Slabs all of
the same size per its rank. For example, the 0th list contains all Slabs that
can fit allocations of `ODIN_HEAP_MIN_BIN_SIZE`.


`purge_countdown` counts down the frees which may pass before this heap hands
the pages of its empty Segments back. It starts at zero, so the first free
always looks.


`current_memory` reports the amount of memory that the heap has under its control.

`peak_memory` is the most amount of memory that the heap has ever held.
Both of these values are only updated under debug mode.
*/
Heap :: struct {
	segments: ^Heap_Segment,

	free_slabs: [1+int(max(Heap_Slab_Class))]^Heap_Slab,

	slabs_by_rank: [ODIN_HEAP_BIN_RANKS]^Heap_Slab,

	purge_countdown: int,

	current_memory: int,
	peak_memory:    int,
}

//
// Heap Operations
//

/*
Find a slab on a heap's free slab list which has room for an allocation of
`bin_size`, without taking it off the list.

A slab of the Small or Large class always has room, because the class fixes how
much a slab of it holds and that is more than the largest bin size of the class.
A Huge slab was sized for the request which made its segment, so a slab of that
class may be smaller than the request being served.
*/
@(private="file", require_results)
heap_find_free_slab :: proc "contextless" (list: ^Heap_Slab, bin_size: int) -> (slab: ^Heap_Slab) {
	for slab = list; slab != nil; slab = slab.next_slab {
		if slab.capacity >= bin_size {
			return
		}
	}
	return nil
}

// Push a slab onto a specific linked list.
@(private="file")
_push_slab :: proc "contextless" (list_head: ^^Heap_Slab, slab: ^Heap_Slab) {
	slab.prev_slab = nil
	slab.next_slab = list_head^
	if list_head^ != nil {
		list_head^.prev_slab = slab
	}
	list_head^ = slab
}

// Remove a free slab from the heap, no matter where it is.
@(no_sanitize_address)
heap_remove_free_slab :: proc "contextless" (slab: ^Heap_Slab) {
	assert_contextless(slab.bin_size == 0, "The heap allocator tried to remove a slab that is in use from one of the free slab lists.")
	for list, index in local_heap.free_slabs {
		if list == slab {
			local_heap.free_slabs[index] = slab.next_slab
			break
		}
	}

	if slab.prev_slab != nil {
		slab.prev_slab.next_slab = slab.next_slab
	}
	if slab.next_slab != nil {
		slab.next_slab.prev_slab = slab.prev_slab
	}
	slab.prev_slab = nil
	slab.next_slab = nil
}

/*
Add a `slab` that has been configured for allocation to the heap.
*/
@(no_sanitize_address)
heap_add_ranked_slab :: proc "contextless" (slab: ^Heap_Slab) {
	assert_contextless(slab.free_bins > 0, "The heap allocator tried to add a full slab to the ranked lists.")
	assert_contextless(slab.bin_size > 0, "The heap allocator tried to add a freed slab to the ranked lists.")
	assert_contextless(slab.bin_size <= ODIN_HEAP_MAX_BIN_SIZE, "The heap allocator tried to add a slab configured for a Huge allocation to the ranked lists.")
	assert_contextless(slab.bin_rank == heap_bin_size_to_rank(slab.bin_size), "The heap allocator found an incongruent bin rank on a slab.")
	rank := slab.bin_rank

	slab.prev_slab = nil
	if local_heap.slabs_by_rank[rank] != nil {
		local_heap.slabs_by_rank[rank].prev_slab = slab
	}
	slab.next_slab = local_heap.slabs_by_rank[rank]
	local_heap.slabs_by_rank[rank] = slab
}

/*
Remove a full or free `slab` from the ranked lists.
*/
@(no_sanitize_address)
heap_remove_ranked_slab :: proc "contextless" (slab: ^Heap_Slab) {
	assert_contextless(
		slab.max_bins > 0 && ((slab.free_bins == 0) || /* is full */ (slab.free_bins == slab.max_bins)) /* is empty */,
		"The heap allocator tried to remove a slab that is not full or not empty from one of the ranked lists.")
	assert_contextless(slab.bin_rank == heap_bin_size_to_rank(slab.bin_size), "The heap allocator found an incongruent bin rank on a slab.")
	rank := slab.bin_rank

	if slab == local_heap.slabs_by_rank[rank] {
		local_heap.slabs_by_rank[rank] = slab.next_slab
	}
	if slab.prev_slab != nil {
		slab.prev_slab.next_slab = slab.next_slab
	}
	if slab.next_slab != nil {
		slab.next_slab.prev_slab = slab.prev_slab
	}
	slab.prev_slab = nil
	slab.next_slab = nil
}

//
// Allocation
//

/*
`ODIN_HEAP_SUPERPAGE_DENSITY` is how much of the Segments a heap already has of
some kind must be made of bins before another Segment of that kind is given over
to the operating system's largest pages, as a percentage between 0 and 100.

A bin is rounded up to a power of two, so a Segment being full of bins does not
mean the program is using what it has been given: a request of 1030 bytes takes a
2048-byte bin. Large pages make the whole of that rounding resident, which is a
reason to ask for them only where the Segments of that kind are made mostly of
bins. The default of 90 is the point past which making the rest of a Segment
resident costs a tenth of it or less, which is a fair price for the translation a
large page saves.

A value of zero turns the check off.
*/
ODIN_HEAP_SUPERPAGE_DENSITY :: #config(ODIN_HEAP_SUPERPAGE_DENSITY, 90 /* percent, 0 disables the check */)

/*
Whether the Segments of `class` the heap already has are being filled.

`held` is how many bytes of bins those Segments are handing out and `mapped` is
how much address space they take up between them.

For a Large Segment, which holds one Bin size on its own, only Segments currently
dedicated to `bin_size` count: they serve a single size class, so the evidence
that another one is worth giving large pages to is that this one has been filled.
A Small Segment is divided into many Slabs that serve every small Bin size
between them, so the whole class is its evidence.
*/
@(require_results)
heap_segments_are_being_filled :: proc "contextless" (class: Heap_Slab_Class, bin_size: int) -> (held, mapped: int) {
	for segment := local_heap.segments; segment != nil; segment = segment.next_segment {
		if segment.slab_size_class != class {
			continue
		}
		if class == .Large && segment.slabs[0].bin_size != bin_size {
			// A Large Segment is dedicated to one Bin size while it is in use, so
			// one working on a different size says nothing about this one.
			continue
		}
		mapped += segment.size
		for &slab in segment.slabs {
			if slab.bin_size == 0 {
				continue
			}
			held += (slab.max_bins - slab.free_bins) * slab.bin_size
		}
	}
	return
}

/*
Whether a new Segment should be given over to the operating system's largest
pages.

Asking for a large page is a bet that the Segment behind it is going to be used.
The first store into the mapping makes the whole of a large page resident, so a
program that allocates a little memory across a handful of size classes pays a
large page for each of them and ends up holding several times the memory it asked
for. That is the case the kernel's own documentation warns about, which is why a
large page is meant to be asked for only where the access pattern is known in
advance not to increase the footprint.

The bet is made on evidence from the Segments of the same kind that the heap
already has: they must be handing out `ODIN_HEAP_SUPERPAGE_THRESHOLD` worth of bins
between them, and `ODIN_HEAP_SUPERPAGE_DENSITY` of what they take up must be those
bins. What counts as the same kind is described on
`heap_segments_are_being_filled`.

A program that allocates a few buffers of different sizes never provides the
evidence, however much it holds in total, and keeps its memory and only the pages
it touches. One that fills the same size class over and over provides it, and
gets the pages.

This has to be settled before anything is written to the mapping.
*/
@(require_results)
heap_should_use_superpages :: proc "contextless" (bin_size: int) -> bool {
	minimum := ODIN_HEAP_SUPERPAGE_THRESHOLD
	if minimum <= 0 {
		if minimum = 2 * heap_get_segment_size(); minimum <= 0 {
			return false
		}
	}

	class := heap_get_size_class(bin_size)
	held, mapped := heap_segments_are_being_filled(class, bin_size)
	if held < minimum {
		return false
	}

	when ODIN_HEAP_SUPERPAGE_DENSITY > 0 {
		if held * 100 < mapped * ODIN_HEAP_SUPERPAGE_DENSITY {
			return false
		}
	}
	return true
}

/*
Allocate memory for a Segment capable of supporting `bin_size` from the
operating system and do any initialization work.

An old, empty segment may be passed in `replacement` to convert it to the
requested size class.
*/
@(no_sanitize_address)
heap_make_segment :: proc "contextless" (bin_size: int, replacement: ^Heap_Segment = nil) -> (segment: ^Heap_Segment) {
	heap_ensure_segment_size()

	// Hand back the pages sitting idle before mapping anything new.
	heap_purge_empty_segments()

	class := heap_get_size_class(bin_size)

	slabs: int
	slab_size: int
	slab_shift: uint
	capacity: int
	mapped: int

	// Handle some book-keeping business.
	switch class {
	case .Small, .Large:
		if replacement == nil {
			segment = heap_allocate_segment()
		} else {
			// The empty orphan segment was already purged, so only its old
			// metadata needs clearing before the new layout is written.
			old_header_size := size_of(Heap_Segment) + size_of(Heap_Slab) * len(replacement.slabs)
			sanitizer.address_unpoison_rawptr(replacement, old_header_size)
			intrinsics.mem_zero_volatile(replacement, old_header_size)
			sanitizer.address_poison_rawptr(replacement, old_header_size)
			segment = replacement
		}
		capacity = heap_get_segment_size()
		mapped = capacity
	case .Huge:
		assert_contextless(replacement == nil, "The heap allocator was handed a replacement Segment to fulfill a Huge size class request. This is invalid behavior; Huge allocations are made independently.")
		book_keeping := size_of(Heap_Segment) + size_of(Heap_Slab) + ODIN_HEAP_MAX_ALIGNMENT

		// The mapping size below must not wrap: book_keeping is small but
		// bin_size is the raw request, and a sum near max(int) would hand the
		// operating system a nonsense size and poison every calculation
		// downstream (CWE-190). Fail clean with nil, as mimalloc does
		// (`if (size >= SIZE_MAX - X) return NULL`). Cold Huge-only path.
		if bin_size > max(int) - book_keeping {
			return nil
		}
		capacity = book_keeping + bin_size
		mapped = capacity
		when ODIN_HEAP_SECURE {
			guard_at: int
			// A page that faults goes after the last page of the allocation, so
			// an overflow off its end does not reach whatever is mapped next.
			// The sum must not wrap any more than the one above.
			page := get_page_size()
			if capacity > max(int) - 2*page {
				return nil
			}
			guard_at = (capacity + page-1) & ~(page-1)
			mapped = guard_at + page
			segment = cast(^Heap_Segment)allocate_virtual_memory_aligned(mapped, heap_get_segment_size())
			if segment != nil {
				// Protecting is a hint, and an allocation without its guard
				// page is as correct as it is without a secure build.
				guarded := false
				when ODIN_OS == .Linux {
					guarded = vm_guard_pages(rawptr(uintptr(segment) + uintptr(guard_at)), get_page_size())
				}
				if !guarded {
					_ = protect_virtual_memory(rawptr(uintptr(segment) + uintptr(guard_at)), get_page_size())
				}
			}
		} else {
			segment = cast(^Heap_Segment)allocate_virtual_memory_aligned(mapped, heap_get_segment_size())
		}
	}
	switch class {
	case .Small:
		slab_shift = intrinsics.constant_log2(ODIN_HEAP_SMALL_SLAB_SIZE)
		slab_size = ODIN_HEAP_SMALL_SLAB_SIZE
	case .Large, .Huge:
		slab_shift = max(uint)
		slab_size = capacity
	}
	slabs = capacity / slab_size

	if segment == nil {
		// The operating system may be out of memory.
		return
	}

	assert_contextless(uintptr(segment) & uintptr(heap_get_segment_size()-1) == 0, "The operating system returned virtual memory which isn't aligned to the Segment boundary.")
	assert_contextless(slabs > 0, "The heap allocator mismanaged the calculation for the number of slabs on making a new segment.")

	// (segment.owner and segment.heap will be set by `heap_add_segment`.)
	//
	// NOTE: This must happen before the book-keeping below is written to, as the
	// first store into the mapping is what gives the operating system the chance
	// to back it with a large page. The pages a Segment is backed by are decided
	// once, here, because a range whose first page is already there cannot be
	// given a superpage without filling the whole thing in.
	when ODIN_OS == .Linux {
		// Remade Segments keep the marking from their first life.
		if replacement == nil {
			when ODIN_HEAP_SUPERPAGES {
				if heap_should_use_superpages(bin_size) {
					vm_advise_hugepages(segment, mapped)
				} else {
					vm_avoid_hugepages(segment, mapped)
				}
			} else {
				vm_avoid_hugepages(segment, mapped)
			}
		}
	}

	// (segment.owner and segment.heap will be set by `heap_add_segment`.)
	segment.magic = heap_segment_magic(segment)
	segment.size = mapped
	segment.is_clean = true

	segment.slab_size_class = class
	segment.slab_shift = slab_shift

	segment.free_slabs = slabs

	// Distribute the allocated space among the substructures.
	alloc_at := uintptr(segment) + size_of(Heap_Segment)

	// NOTE: `align_of([]T)` should be 8, so this is safe.
	segment.slabs = transmute([]Heap_Slab)Raw_Slice{
		rawptr(alloc_at),
		slabs,
	}
	alloc_at += size_of(Heap_Slab) * uintptr(slabs)

	// Align the pointer to a suitable boundary.
	if modulo := alloc_at & (ODIN_HEAP_MAX_ALIGNMENT-1); modulo != 0 {
		pad := ODIN_HEAP_MAX_ALIGNMENT - modulo
		alloc_at += pad
		segment.padding = int(pad)
	}

	// Carefully setup the first slab, as it has a reduced capacity due to the
	// Segment and Slab structures being stored at the start of the segment.
	first_slab_capacity := slab_size - int(alloc_at - uintptr(segment))
	assert_contextless(first_slab_capacity >= bin_size, "The heap allocator mismanaged the capacity for the first slab in a new segment.")

	segment.slabs[0].data = alloc_at
	segment.slabs[0].capacity = first_slab_capacity
	alloc_at += uintptr(first_slab_capacity)

	// The rest of the slabs are full-size.
	for &slab in segment.slabs[1:] {
		slab.data = alloc_at
		slab.capacity = slab_size
		alloc_at += uintptr(slab_size)
	}

	// Because the linked lists have stack-like behavior (as opposed to queue),
	// we push them in reverse order to better accommodate cache locality of
	// contiguous allocations.
	list := &local_heap.free_slabs[class]
	for i in 1..=slabs {
		slab := &segment.slabs[slabs-i]
		assert_contextless(slab.data + uintptr(slab.capacity) <= uintptr(segment) + uintptr(capacity), "The heap allocator mismanaged the slab space in a new segment.")
		assert_contextless(slab.data % ODIN_HEAP_MAX_ALIGNMENT == 0, "The heap allocator mismanaged the alignment of a slab's first bin in a new segment.")
		assert_contextless(find_segment_from_pointer(rawptr(slab.data)) == segment, "The heap allocator was not able to do a reverse lookup of a slab for a new segment.")
		assert_contextless(slab.bin_size == 0, "The heap allocator tried to add a non-empty slab to a newly made segment.")
		_push_slab(list, slab)
	}

	heap_add_segment(segment)

	// Keep the program from touching the heap metadata.
	sanitizer.address_poison_rawptr(segment, segment.size)

	return
}

/*
Configure a Slab that can support an allocation of `bin_size`.
*/
@(no_sanitize_address)
heap_make_slab :: proc "contextless" (bin_size: int) -> (slab: ^Heap_Slab) {
	// Get a slab that can fulfill the size request.
	class := heap_get_size_class(bin_size)
	list := &local_heap.free_slabs[class]

	// A slab which this heap already holds may not have room for the request.
	// A slab of the Small or Large class always does, and a Huge slab was sized
	// for the request which made its segment, so this matters for the Huge class:
	// the slabs a dead heap left behind on a segment this heap adopted may have
	// been made for a smaller request than this one.
	//
	// Try to adopt an orphaned segment for the size request.
	//
	// NOTE: We may end up adopting an in-use segment that cannot fulfill our
	// size request. This is acceptable behavior as it will help keep the
	// overall memory usage of the program down by redistributing unowned
	// segments to heaps that can manage their remote frees.
	for slab == nil {
		if slab = heap_find_free_slab(list^, bin_size); slab != nil {
			break
		}
		if heap_adopt_orphan(bin_size, class) == nil {
			break
		}
	}

	if slab == nil {
		// Adoption didn't work, so this is where the memory this heap is not
		// using matters. Take back the bins which other threads freed on its
		// Slabs first: a Slab which is full on this side may have bins to hand
		// out again, and a Segment with no bins in flight can be given back.
		heap_merge_remote_frees()

		slab = heap_find_free_slab(list^, bin_size)
	}

	if slab == nil {
		// Let's try allocating a new segment.
		if heap_make_segment(bin_size) == nil {
			// The operating system may be out of memory.
			return
		}

		slab = heap_find_free_slab(list^, bin_size)
		assert_contextless(slab != nil, "The heap allocator made a segment with no slab that can hold the request which made it.")
	}

	// Take the slab off the list so that no other request can be given it.
	heap_remove_free_slab(slab)

	segment := find_segment_from_pointer(slab)
	assert_contextless(segment.free_slabs > 0, "The heap allocator was given a slab that belongs to a segment with no free slabs upon trying to make a new slab.")

	segment.free_slabs -= 1
	if segment.free_slabs == 0 {
		// Here we set the flag for the heuristic that helps with freeing
		// segments only when they've been thoroughly used.
		segment.may_return = true
	}

	// Set up the slab.
	slab.bin_size = bin_size

	bins := slab.capacity / bin_size
	assert_contextless(bins > 0, "The heap allocator miscalculated the number of bins for a new slab.")

	when ODIN_HEAP_DEBUG_LEVEL >= .Buffer_Overflow {
		if bins > 1 {
			// Reserve some of the bins for persistent poisoning.
			bins = slab.capacity / heap_bin_stride(bin_size)
		}
	}

	if class == .Huge {
		// A Huge Slab hands out one bin. A fresh Slab works out to one on its own,
		// because its Segment was sized for the request that made it, but a Segment
		// which a heap still owns is reused for a smaller Huge request, and the room
		// left over from the larger one would otherwise count as extra bins. Those
		// bins need never all be handed out, and a Slab is only cleared of its
		// `bin_size` once `used_bins` reaches `max_bins`, so the Slab would keep a
		// `bin_size` above `ODIN_HEAP_MAX_BIN_SIZE` while also having free bins. A
		// Huge Slab in that state is ranked when another heap adopts its Segment,
		// which a Huge Slab is not allowed to be.
		bins = 1
	}

	slab.free_bins = bins
	slab.max_bins = bins

	// Detect if this slab was used previously.
	if slab.used_bins > 0 {
		// Tidy up the slab for re-use.
		slab.used_bins = 0
		slab.free_list = nil
		// NOTE: `mem_zero_volatile` is not immune to the address sanitizer, for good reason.
		zero_size := bins * heap_bin_stride(bin_size)
		sanitizer.address_unpoison_rawptr(rawptr(slab.data), zero_size)
		intrinsics.mem_zero_volatile(rawptr(slab.data), zero_size)
		sanitizer.address_poison_rawptr(rawptr(slab.data), zero_size)
	}

	// Remote frees of this slab's bins are parked on its own list from here on,
	// and this heap merges them.

	// (slab.data is already set by `heap_make_segment`.)

	// Huge allocations are not put into any of the ranked lists.
	if class < .Huge {
		slab.bin_rank = heap_bin_size_to_rank(bin_size)
		heap_add_ranked_slab(slab)
	} else {
		slab.bin_rank = max(int)
	}

	return
}

/*
Get a slab that can fulfill the `size` request.
*/
@(no_sanitize_address)
heap_get_slab :: proc "contextless" (size: int) -> (slab: ^Heap_Slab) {
	if size <= ODIN_HEAP_MAX_BIN_SIZE {
		bin_size, rank := heap_calculate_sizes(size)

		slab = local_heap.slabs_by_rank[rank]
		if slab == nil {
			// An orphaned Segment brings its ranked Slabs with it, and one of them
			// may already serve this size. Look again after each adoption, and stop
			// once there is a free Slab to make one from, so a thread does not take
			// in every orphan, and purge every one of them again when it exits.
			class := heap_get_size_class(bin_size)
			for slab == nil && local_heap.free_slabs[class] == nil {
				if heap_adopt_orphan(bin_size, class) == nil {
					break
				}
				slab = local_heap.slabs_by_rank[rank]
			}
		}
		if slab == nil {
			// The head of the list for this rank is empty, so we'll need to
			// make a new one.
			slab = heap_make_slab(bin_size)
		}
		if slab == nil {
			// The operating system may be out of memory.
			return nil
		}
		assert_contextless(slab.bin_size == heap_round_to_bin_size(size), "The heap allocator found a slab with the wrong bin size during allocation.")
	} else {
		// We only round the size request for allocations that will fit into Small
		// or Large Slabs. For Huge Slabs, their allocations are specifically sized.
		slab = heap_make_slab(size)
		if slab == nil {
			// The operating system may be out of memory.
			return nil
		}
		assert_contextless(slab.bin_size == size, "The heap allocator made a slab with the wrong bin size during allocation.")
	}
	return
}

/*
Make a new bin-sized allocation, optionally zeroing the memory.
*/
@(no_sanitize_address)
heap_make_bin :: proc "contextless" (size: int, zero_memory: bool) -> (ptr: rawptr) {
	// Get a slab that can fulfill the size request.
	slab := heap_get_slab(size)

	if slab == nil {
		// The operating system may be out of memory.
		return
	}
	assert_contextless(slab.free_bins > 0, "The heap allocator was given a slab that had no free bins for an allocation request.")

	if slab.free_list == nil {
		assert_contextless(slab.used_bins <= slab.max_bins, "The heap allocator has exceeded the amount of used bins on one of its slabs.")

		// Fetch a new address.
		ptr = rawptr(slab.data + uintptr(slab.used_bins * heap_bin_stride(slab.bin_size)))

		// Ensure the instrumented parts of the program can use the memory
		// without triggering any of the sanitizer warnings.
		//
		// NOTE: The address sanitizer has an 8-byte alignment requirement
		// and does not seem to register any size < 8 bytes.
		sanitizer.address_unpoison(ptr, max(ODIN_HEAP_MIN_BIN_SIZE, size))

		slab.used_bins += 1

		when ODIN_HEAP_DEBUG_LEVEL >= .Ensure_Zero {
			bytes := cast([^]u8)ptr
			for i := 0; i < slab.bin_size; i += 1 {
				ensure_contextless(bytes[i] == 0, "The heap allocator's allocation space has been corrupted.")
			}
		}
	} else {
		// Pop the pointer off the free list.
		ptr = slab.free_list

		sanitizer.address_unpoison(ptr, max(ODIN_HEAP_MIN_BIN_SIZE, size))

		next := heap_mask_link(ptr, (cast(^uintptr)ptr)^)

		// Bins are aligned, so a link which is not was written by something
		// other than the allocator. Nor can it point outside its Slab, which is
		// the check mimalloc makes of every link it decodes. Both need nothing
		// but fields of the Slab already in hand, so they stay on in every build,
		// and a forged link cannot make the allocator hand out an address of
		// the attacker's choosing.
		ensure_contextless(next & (ODIN_HEAP_MIN_BIN_SIZE-1) == 0 && (next == 0 || next - slab.data < uintptr(slab.capacity)), "The heap allocator found a corrupted free list link. A freed bin was written to after it was freed, or a neighbouring allocation overflowed into it.")

		// The word a free leaves a key in, which the program now owns.
		when ODIN_HEAP_SECURE {
			if slab.bin_size > size_of(uintptr) {
				(cast([^]uintptr)ptr)[1] = 0
			}
		}

		// A link which a write through a stale pointer or an overflow has
		// clobbered may still point inside the Slab but off a bin boundary.
		// That takes a division, so like the check on untouched bins above it is
		// left to the debug levels and the sanitizers, which poison a freed bin
		// and so catch the write itself.
		when ODIN_HEAP_DEBUG_LEVEL >= .Ensure_Zero {
			if next != 0 {
				offset := next - uintptr(slab.data)
				stride := uintptr(heap_bin_stride(slab.bin_size))
				when ODIN_HEAP_DEBUG_LEVEL < .Buffer_Overflow {
					aligned := offset & (stride-1) == 0
				} else {
					aligned := offset % stride == 0
				}
				ensure_contextless(aligned, "The heap allocator found a corrupted free list link. A freed bin was written to after it was freed, or a neighbouring allocation overflowed into it.")
			}
		}
		slab.free_list = cast(^uintptr)next

		if zero_memory {
			// Ensure that the memory zeroing is not optimized out by the compiler.
			intrinsics.mem_zero_volatile(ptr, size)
			// NOTE: A full memory fence should not be needed for any newly-zeroed
			// allocation, as each thread controls its own heap, and for one thread
			// to pass a memory address to another implies some secondary
			// synchronization method, such as a mutex, which would be the way by
			// which the threads come to agree on the state of main memory.
		}
	}

	slab.free_bins -= 1
	if slab.free_bins == 0 {
		// The slab is empty, so it must be taken off the list for its rank to
		// prevent further allocation attempts on it.
		if slab.bin_size <= ODIN_HEAP_MAX_BIN_SIZE {
			// Only allocations that fit into Small and Large Slabs are placed
			// into the ranked lists.
			heap_remove_ranked_slab(slab)
		}
		assert_contextless(slab.prev_slab == nil && slab.next_slab == nil, "The heap allocator failed to ensure a full slab was unlinked.")
	}

	// Track the bins in flight, so that a Segment with none left is known to be
	// empty.
	segment := find_segment_from_pointer(rawptr(slab))
	segment.is_clean = false
	segment.allocated_bins += 1

	return
}

//
// Remote Freeing
//

/*
Atomically replace a free list's head with nil and return the entire chain.
*/
@(require_results, no_sanitize_address)
heap_take_free_list :: proc "contextless" (list: ^Tagged_Pointer) -> ^uintptr {
	old_head := transmute(Tagged_Pointer)intrinsics.atomic_load_explicit(cast(^u64)list, .Relaxed)
	for {
		if uintptr(old_head.pointer) == 0 {
			// The list is empty.
			return nil
		}
		value := old_head.pointer
		new_head := Tagged_Pointer{
			pointer = 0,
			version = old_head.version + 1,
		}

		old_head_, swapped := intrinsics.atomic_compare_exchange_weak_explicit(cast(^u64)list, transmute(u64)old_head, transmute(u64)new_head, .Acq_Rel, .Relaxed)
		if swapped {
			return cast(^uintptr)rawptr(uintptr(value))
		}
		old_head = transmute(Tagged_Pointer)old_head_
	}
}

/*
Push `ptr` onto a Slab's remote free list.

A Slab is the only place a free from another thread can be left: it outlives
every bin it holds, while the Heap which owns it does not, and the heap of a
thread which is exiting is unmapped while another thread may still be holding
one of its bins. Pushing is one atomic operation, so the thread which is freeing
never waits on the thread which owns the Slab, and the owning thread merges the
list at its next opportunity.
*/
@(private="file", no_sanitize_address)
push_onto_remote_free_list :: proc "contextless" (slab: ^Heap_Slab, list: ^Tagged_Pointer, ptr: rawptr) {
	// Poison once up front: the bin is unpublished until the exchange succeeds.
	sanitizer.address_poison_rawptr(ptr, size_of(^uintptr))

	old_head := transmute(Tagged_Pointer)intrinsics.atomic_load_explicit(cast(^u64)list, .Relaxed)
	for {
		// Write the next address to this pointer, continuing the linked list.
		(cast(^uintptr)ptr)^ = heap_mask_link(ptr, uintptr(old_head.pointer))

		new_head := Tagged_Pointer{
			pointer = i64(uintptr(ptr)),
			version = old_head.version + 1,
		}

		old_head_, swapped := intrinsics.atomic_compare_exchange_weak_explicit(cast(^u64)list, transmute(u64)old_head, transmute(u64)new_head, .Acq_Rel, .Relaxed)
		if swapped {
			return
		}
		// Lost the race; relax before retrying.
		intrinsics.cpu_relax()
		old_head = transmute(Tagged_Pointer)old_head_
	}
}

/*
Merge a Slab's remote frees into the free list this thread keeps for it, which
is how bins freed by other threads come back to the heap which owns them.

Returns whether merging gave the Segment back: the last bins of the whole
Segment may arrive here, freeing it from under the loop in
`merge_segment_remote_frees`, which must then stop touching its Slabs.
*/
@(private="file", no_sanitize_address)
merge_slab_remote_free_list :: proc "contextless" (segment: ^Heap_Segment, slab: ^Heap_Slab, merged: ^int = nil) -> (segment_freed: bool) {
	assert_contextless(slab.bin_size > 0, "The heap allocator tried to merge the remote frees of a slab which is not in use.")
	for ptr := heap_take_free_list(&slab.remote_free_list); ptr != nil; /**/ {
		next := heap_mask_link(ptr, ptr^)
		if merged != nil {
			merged^ += 1
		}
		if heap_free_bin(segment, slab, ptr) {
			// The Segment went back with this Slab. Nothing else on it can
			// still hold bins: a Segment is only given back once no bins are
			// in flight anywhere on it, so there is nothing left to merge.
			return true
		}
		ptr = cast(^uintptr)next
	}
	return false
}

/*
Merge the frees which other threads left on this Segment's Slabs.
*/
@(private="file", no_sanitize_address)
merge_segment_remote_frees :: proc "contextless" (segment: ^Heap_Segment, merged: ^int = nil) {
	for &slab in segment.slabs {
		// A Slab with no bins in flight has none on this list, and none can be
		// pushed onto it: only a thread holding one of its bins can push.
		if slab.bin_size > 0 && intrinsics.atomic_load_explicit(cast(^u64)&slab.remote_free_list, .Acquire) != 0 {
			if merge_slab_remote_free_list(segment, &slab, merged) {
				// The Segment went back with one of its Slabs. Its Slab
				// metadata may now be unmapped, so the loop over it stops
				// here, the same way `heap_merge_remote_frees` reads the
				// next Segment before merging for the same reason.
				return
			}
		}
	}
}

/*
Merge the frees which other threads left on this heap's Slabs.

This is done where the bins matter: when the heap has nothing ranked for a size
it is asked for, before it asks the operating system for a Segment, when it is
asked to give memory back, and as its thread exits.
*/
@(no_sanitize_address)
heap_merge_remote_frees :: proc "contextless" (merged: ^int = nil) {
	for segment := local_heap.segments; segment != nil; /**/ {
		// Merging a Slab's frees can give its last bins back, and with them the
		// whole Segment, so the next Segment is read before that happens.
		next_segment := segment.next_segment
		merge_segment_remote_frees(segment, merged)
		segment = next_segment
	}
}

//
// Freeing
//

@(no_sanitize_address)
heap_free_segment :: proc "contextless" (segment: ^Heap_Segment) {
	// Remove all slabs belonging to this segment from the heap.
	for &slab in segment.slabs {
		assert_contextless(slab.bin_size == 0, "The heap allocator found a slab which is not free while freeing a segment.")
		heap_remove_free_slab(&slab)
	}

	heap_remove_segment(segment)

	// Huge allocations are simply given back to the operating system when done.
	if segment.slab_size_class == .Huge {
		free_virtual_memory(segment, segment.size)
		return
	}

	// The other segments may be kept around for another heap to take. A segment
	// without any slabs in use has nothing to keep its pages around for, so they
	// are handed back rather than sitting idle in the orphanage.
	assert_contextless(segment.allocated_bins == 0, "The heap allocator found a segment with bins in flight which was not in use by any slab.")
	heap_purge_segment(segment)

	if !heap_orphan_empty_segment(segment) {
		free_virtual_memory(segment, segment.size)
	}
}

@(no_sanitize_address)
heap_free_slab :: proc "contextless" (segment: ^Heap_Segment, slab: ^Heap_Slab) -> (segment_freed: bool) {
	segment.free_slabs += 1
	assert_contextless(segment.free_slabs <= len(segment.slabs), "The heap allocator freed a slab and caused an overflow of the free slab counter.")

	if slab.bin_size <= ODIN_HEAP_MAX_BIN_SIZE {
		// Remove the slab from the array of ranked lists so that it is no
		// longer used for future allocations.
		heap_remove_ranked_slab(slab)
	}

	// Mark the slab as free.
	slab.bin_size = 0

	if segment.free_slabs == len(segment.slabs) && segment.may_return {
		heap_free_segment(segment)
		return true
	}

	// Put the now-freed slab back on the heap.
	_push_slab(&local_heap.free_slabs[segment.slab_size_class], slab)
	return false
}

/*
Return the pages of every Segment which holds no bins in flight back to the
operating system.

This runs where the heap is about to ask for more memory: pages sitting idle
are handed back first, so growth reuses what the program already gave up
before mapping anything new. Memory used again in the meantime was never given
up at all, so steady churn pays nothing for this.
*/
@(no_sanitize_address)
heap_purge_empty_segments :: proc "contextless" () {
	for segment := local_heap.segments; segment != nil; segment = segment.next_segment {
		if segment.allocated_bins == 0 {
			heap_purge_segment(segment)
		}
	}
}

/*
Return the pages that a Segment's Slabs occupy to the operating system while
keeping the Segment itself, so that it can be filled up again without asking
the operating system for memory.

The Segment must not have any bins in flight, as they would be freed from under
the program's feet.

The bins are all free, and the pages they are in are cleared or given back. The
Segment takes them back from the start the next time it is used, so they read as
zero either way, and the sanitizer is told that the bins are still poisoned.

Returns false if the operating system chose to keep the pages, which is a hint
it is free to take and not an error: the pages are simply cleared here instead.
*/
@(no_sanitize_address)
heap_purge_segment :: proc "contextless" (segment: ^Heap_Segment) -> (purged: bool) {
	assert_contextless(segment.allocated_bins == 0, "The heap allocator tried to give the pages of a segment back to the operating system while it was still in use.")

	for &slab in segment.slabs {
		assert_contextless(slab.bin_size == 0 || slab.free_bins == slab.max_bins, "The heap allocator tried to give the pages of a segment back to the operating system while one of its slabs was still in use.")
	}
	if segment.is_clean {
		return true
	}

	// (The head of the Segment holds the book-keeping, which stays behind.)
	data := uintptr(segment.slabs[0].data)
	size := segment.size - int(data - uintptr(segment))

	// Every bin is free, so the sanitizer has the whole of the data poisoned, and
	// the clearing below is a write to it.
	sanitizer.address_unpoison_rawptr(rawptr(data), size)

	purged = decommit_virtual_memory(rawptr(data), size)
	if !purged {
		// The pages are ours still, so the clearing which giving them back would
		// have done is done here, which is what lets a Slab hand its bins out
		// from the start without clearing them individually.
		intrinsics.mem_zero_volatile(rawptr(data), size)
	}

	sanitizer.address_poison_rawptr(rawptr(data), size)

	// The bins held the free lists, and the pages they were in are gone, so each
	// Slab hands its bins out from the start the next time it is used.
	for &slab in segment.slabs {
		slab.free_list = nil
		slab.used_bins = 0
	}
	segment.is_clean = true

	return
}

@(no_sanitize_address)
heap_free_bin :: proc "contextless" (segment: ^Heap_Segment, slab: ^Heap_Slab, ptr: rawptr) -> (segment_freed: bool) {
	// A bin handed back twice would corrupt the free list below and hand the
	// same memory out to two owners, so the design expects every bin to be
	// freed exactly once. Both counters are already in hand here, making this
	// a single predictable branch that survives `-disable-assert`, where the
	// production benchmarks run: unlike jemalloc, which leaves this to
	// debug-only asserts, and mimalloc, which gates even its cheap check
	// behind secure mode, this costs nothing measurable on the free path.
	ensure_contextless(slab.free_bins < slab.max_bins, "The heap allocator was asked to free a bin that is already free. This is a double free.")
	// The count cannot tell which bin is free, but the head of the free list is
	// already in hand, and a bin freed twice in a row is the double free that
	// would make the list point at itself.
	ensure_contextless(slab.free_list != cast(^uintptr)ptr, "The heap allocator was asked to free the bin it freed last. This is a double free.")
	slab.free_bins += 1
	segment.allocated_bins -= 1

	assert_contextless(slab.bin_size > 0, "The heap allocator tried to free a pointer belonging to an empty slab.")
	assert_contextless(segment.allocated_bins >= 0, "The heap allocator lost track of the number of bins in use in a segment.")

	// A bin with a second word is marked free with a key that belongs to its
	// Slab. Any word the program leaves behind may be equal to it, so a match
	// only asks for the free list to be searched for the bin, which settles it.
	// This finds a bin freed twice with others freed in between, which the head
	// of the list cannot. A bin of a single word has nowhere to keep a key, so
	// only the head check above covers it.
	when ODIN_HEAP_SECURE {
		if slab.bin_size > size_of(uintptr) {
			key := &(cast([^]uintptr)ptr)[1]
			if key^ == uintptr(slab) {
				link := slab.free_list
				for _ in 0..<slab.free_bins {
					if link == nil {
						break
					}
					ensure_contextless(link != cast(^uintptr)ptr, "The heap allocator was asked to free a bin that is already free. This is a double free.")
					link = cast(^uintptr)heap_mask_link(link, link^)
				}
			}
			key^ = uintptr(slab)
		}
	}

	// Push onto the head of the free list.
	(cast(^uintptr)ptr)^ = heap_mask_link(ptr, uintptr(slab.free_list))

	// Prevent the program from using the freed memory when the address sanitizer is enabled.
	sanitizer.address_poison_rawptr(ptr, slab.bin_size)

	slab.free_list = cast(^uintptr)ptr

	// A Slab which has been handed out in full and now holds nothing goes back
	// to its Segment, which may in turn be given back. This has to be checked
	// before the case below: a Slab of one bin is empty as soon as it is free,
	// so both cases hold at once, and ranking the Slab would leave its `bin_size`
	// set, which is what a Segment counts as a Slab in use.
	if slab.free_bins == slab.max_bins && slab.used_bins == slab.max_bins {
		if heap_free_slab(segment, slab) {
			// The Segment went back to the operating system along with the Slab,
			// so there is nothing left to give back.
			return true
		}
	} else if slab.free_bins == 1 && slab.bin_size <= ODIN_HEAP_MAX_BIN_SIZE {
		// The slab has free bins again, which means we can place it back
		// into its appropriate ranked list.
		heap_add_ranked_slab(slab)
	}

	// Hand back idle pages in batches: every interval of frees, the Segments
	// holding nothing are purged. This runs once the free above is fully done,
	// so no bin is ever counted but unlisted while the bump cursor restarts.
	if local_heap.purge_countdown == 0 {
		local_heap.purge_countdown = ODIN_HEAP_PURGE_INTERVAL
		heap_purge_empty_segments()
	} else {
		local_heap.purge_countdown -= 1
	}

	return false
}

//
// Segment Orphanage
//

// This construction is used to avoid the ABA problem.
//
// Virtually all systems we support should have a 64-bit CAS to make this work.
Tagged_Pointer :: bit_field u64 {
	// Intel 5-level paging uses up to 56 bits of a pointer on x86-64.
	// This should be enough to cover ARM64, too.
	//
	// We use an `i64` here to maintain sign extension on the upper bits for
	// systems where this is relevant, hence the extra bit over 56.
	pointer: i64 | 57,
	// We only need so many bits that enough transactions don't happen so fast
	// as to roll over the value to cause a situation where ABA can manifest.
	version: u8 | 7,
}

/*
Push an empty Segment into the global orphanage.
*/
@(no_sanitize_address)
heap_orphan_empty_segment :: proc "contextless" (segment: ^Heap_Segment) -> (accepted: bool) {
	when ODIN_HEAP_MAX_EMPTY_ORPHANED_SEGMENTS > 0 {
		old_head := transmute(Tagged_Pointer)intrinsics.atomic_load_explicit(cast(^u64)&heap_orphanage.empty, .Relaxed)
		for {
			count         := old_head.pointer & ODIN_HEAP_ORPHANAGE_COUNT_BITS
			untagged_head := uintptr(old_head.pointer) & ~uintptr(ODIN_HEAP_ORPHANAGE_COUNT_BITS)

			assert_contextless(count <= ODIN_HEAP_MAX_EMPTY_ORPHANED_SEGMENTS, "The heap orphanage for empty segments has an invalid embedded `count`.")
			if count == ODIN_HEAP_MAX_EMPTY_ORPHANED_SEGMENTS {
				break
			}

			// Set the next pointer in the list to the current head.
			intrinsics.atomic_store_explicit(&segment.next_segment, cast(^Heap_Segment)untagged_head, .Release)

			new_head := Tagged_Pointer{
				pointer = i64(uintptr(segment)) | (count + 1),
				version = old_head.version + 1,
			}

			old_head_, swapped := intrinsics.atomic_compare_exchange_weak_explicit(cast(^u64)&heap_orphanage.empty, transmute(u64)old_head, transmute(u64)new_head, .Acq_Rel, .Relaxed)
			if swapped {
				accepted = true
				break
			}
			old_head = transmute(Tagged_Pointer)old_head_
		}
	}
	return
}

/*
Push a non-empty Segment into the global orphanage.
*/
@(no_sanitize_address)
heap_orphan_segment :: proc "contextless" (segment: ^Heap_Segment) {
	intrinsics.atomic_store_explicit(&segment.owner, 0, .Release)

	// The Segment may still be linked to the rest of the heap it came from,
	// which is about to be unmapped, so the link pointing backwards is dropped
	// before another thread can adopt the Segment and walk it.
	segment.prev_segment = nil

	old_head := transmute(Tagged_Pointer)intrinsics.atomic_load_explicit(cast(^u64)&heap_orphanage.in_use, .Relaxed)
	for {
		// Set the next pointer in the list to the current head.
		intrinsics.atomic_store_explicit(&segment.next_segment, cast(^Heap_Segment)uintptr(old_head.pointer), .Release)

		new_head := Tagged_Pointer{
			pointer = i64(uintptr(segment)),
			version = old_head.version + 1,
		}

		old_head_, swapped := intrinsics.atomic_compare_exchange_weak_explicit(cast(^u64)&heap_orphanage.in_use, transmute(u64)old_head, transmute(u64)new_head, .Acq_Rel, .Relaxed)
		if swapped {
			intrinsics.atomic_add_explicit(&heap_orphanage.in_use_count, 1, .Relaxed)
			break
		}
		old_head = transmute(Tagged_Pointer)old_head_
	}
}

/*
Push `segment` onto the heap's list.
*/
@(no_sanitize_address)
heap_add_segment :: proc "contextless" (segment: ^Heap_Segment) {
	assert_contextless(segment.prev_segment == nil, "The heap allocator tried to add a segment to its heap which has a non-nil `prev_segment`. This indicates a failure to clear this value.")

	intrinsics.atomic_store_explicit(&segment.owner, get_current_thread_id(), .Release)
	intrinsics.atomic_store_explicit(&segment.heap, local_heap, .Release)
	segment.next_segment = local_heap.segments
	if local_heap.segments != nil {
		local_heap.segments.prev_segment = segment
	}
	local_heap.segments = segment

	when ODIN_HEAP_DEBUG_LEVEL >= .Statistics {
		local_heap.current_memory += segment.size
		local_heap.peak_memory = max(local_heap.peak_memory, local_heap.current_memory)
	}
}

/*
Remove `segment` from the heap.
*/
@(no_sanitize_address)
heap_remove_segment :: proc "contextless" (segment: ^Heap_Segment) {
	intrinsics.atomic_store_explicit(&segment.owner, 0, .Release)
	intrinsics.atomic_store_explicit(&segment.heap, nil, .Release)
	if segment == local_heap.segments {
		local_heap.segments = segment.next_segment
	}
	if segment.prev_segment != nil {
		segment.prev_segment.next_segment = segment.next_segment
	}
	if segment.next_segment != nil {
		segment.next_segment.prev_segment = segment.prev_segment
	}
	segment.prev_segment = nil
	segment.next_segment = nil

	when ODIN_HEAP_DEBUG_LEVEL >= .Statistics {
		local_heap.current_memory -= segment.size
	}
}

/*
Take a Heap for a thread which is starting, reusing the one of a thread which
has exited if there is one.

A program which starts and stops threads all the time would otherwise map a page
for each thread's Heap, fault it in twice, and unmap it again. A Heap is never
unmapped once it has been on the list, because a thread that loaded the old head
may still read its link after another thread has taken it. So the list holds at
most as many Heaps as there have been threads at one time.
*/
@(require_results, no_sanitize_address)
heap_acquire :: proc "contextless" () -> (heap: ^Heap) {
	old_head := transmute(Tagged_Pointer)intrinsics.atomic_load_explicit(cast(^u64)&heap_orphanage.free_heaps, .Acquire)
	for {
		heap = cast(^Heap)uintptr(old_head.pointer)
		if heap == nil {
			break
		}

		// The first word of a Heap on the list holds the link to the next one.
		next := intrinsics.atomic_load_explicit(cast(^uintptr)heap, .Acquire)
		new_head := Tagged_Pointer{
			pointer = i64(next),
			version = old_head.version + 1,
		}

		old_head_, swapped := intrinsics.atomic_compare_exchange_weak_explicit(cast(^u64)&heap_orphanage.free_heaps, transmute(u64)old_head, transmute(u64)new_head, .Acq_Rel, .Acquire)
		if swapped {
			intrinsics.mem_zero_volatile(heap, size_of(Heap))
			return heap
		}
		old_head = transmute(Tagged_Pointer)old_head_
	}

	// The list is empty, so map a page and cut it into Heaps, each on a cache line
	// of its own because each is written by its thread alone. One goes to the
	// caller and the rest to the list, so a Heap costs a fraction of a page.
	STRIDE :: (size_of(Heap) + 63) &~ 63
	page := cast([^]byte)allocate_virtual_memory(get_page_size())
	if page == nil {
		return nil
	}
	for offset := STRIDE; offset + STRIDE <= get_page_size(); offset += STRIDE {
		heap_release(cast(^Heap)&page[offset])
	}
	return cast(^Heap)page
}

/*
Hand the Heap of a thread which is exiting to the next thread that starts.
*/
@(no_sanitize_address)
heap_release :: proc "contextless" (heap: ^Heap) {
	old_head := transmute(Tagged_Pointer)intrinsics.atomic_load_explicit(cast(^u64)&heap_orphanage.free_heaps, .Relaxed)
	for {
		intrinsics.atomic_store_explicit(cast(^uintptr)heap, uintptr(old_head.pointer), .Release)

		new_head := Tagged_Pointer{
			pointer = i64(uintptr(heap)),
			version = old_head.version + 1,
		}

		old_head_, swapped := intrinsics.atomic_compare_exchange_weak_explicit(cast(^u64)&heap_orphanage.free_heaps, transmute(u64)old_head, transmute(u64)new_head, .Acq_Rel, .Relaxed)
		if swapped {
			return
		}
		old_head = transmute(Tagged_Pointer)old_head_
	}
}

/*
Take a Segment from the orphanage, in the order which costs the program the
least, and give it to this heap.

If the first one available happens to be an in-use Segment, the request for
`bin_size` and `class` is likely to not be satisfied, and the caller comes back
for another one.
*/
@(require_results, no_sanitize_address)
heap_adopt_orphan :: proc "contextless" (bin_size: int, class: Heap_Slab_Class) -> (segment: ^Heap_Segment) {
	if segment = heap_take_in_use_orphan(); segment != nil {
		return
	}

	// A Huge allocation is given a Segment of its own, sized for the request
	// alone, so the Segments in the orphanage for empty ones have nothing to offer
	// it: they are laid out for the Small or Large class, and taking one would
	// only throw it away.
	if class != .Huge {
		segment = heap_take_empty_orphan(bin_size, class)
	}

	return
}

/*
Take an in-use Segment from the orphanage, if there is one, and give it to this
heap.

The Segment keeps the layout it had, since it is still holding whatever the heap
which gave it up had allocated, and any frees which arrived from other threads
while it had no owner are merged here.
*/
@(require_results, no_sanitize_address)
heap_take_in_use_orphan :: proc "contextless" () -> (segment: ^Heap_Segment) {
	old_head := transmute(Tagged_Pointer)intrinsics.atomic_load_explicit(cast(^u64)&heap_orphanage.in_use, .Relaxed)
	for {
		segment = cast(^Heap_Segment)uintptr(old_head.pointer)
		if segment == nil {
			break
		}

		next := intrinsics.atomic_load_explicit(&segment.next_segment, .Acquire)
		new_head := Tagged_Pointer{
			pointer = i64(uintptr(next)),
			version = old_head.version + 1,
		}

		old_head_, swapped := intrinsics.atomic_compare_exchange_weak_explicit(cast(^u64)&heap_orphanage.in_use, transmute(u64)old_head, transmute(u64)new_head, .Acq_Rel, .Relaxed)
		if swapped {
			intrinsics.atomic_store_explicit(&segment.next_segment, nil, .Release)
			intrinsics.atomic_add_explicit(&heap_orphanage.in_use_count, -1, .Relaxed)
			break
		}
		old_head = transmute(Tagged_Pointer)old_head_
	}
	if segment != nil {
		heap_add_segment(segment)

		// Get the free slab list in advance.
		free_slabs_list := &local_heap.free_slabs[segment.slab_size_class]

		// Block the segment from being freed while we iterate over it.
		segment.may_return = false

		// Add the slabs in reverse order to improve cache locality.
		for i in 1..=len(segment.slabs) {
			slab := &segment.slabs[len(segment.slabs)-i]
			if slab.bin_size == 0 {
				_push_slab(free_slabs_list, slab)
			} else {
				if slab.free_bins > 0 {
					heap_add_ranked_slab(slab)
				}
				// This segment may have remote frees from the time when it had
				// no owner, and this heap is the one that merges them now.
				merge_slab_remote_free_list(segment, slab)
			}
		}

		segment.may_return = segment.free_slabs == len(segment.slabs)
	}

	return
}

/*
Take an empty Segment from the orphanage, if there is one, and lay it out for
`bin_size`.

A Segment in this orphanage was given back in full, so all of its Slabs are free
and its pages have already been returned to the operating system. One which is
already laid out for the class of the request is taken as it is, and one of
another class is made over into a Segment which suits it.
*/
@(require_results, no_sanitize_address)
heap_take_empty_orphan :: proc "contextless" (bin_size: int, class: Heap_Slab_Class) -> (segment: ^Heap_Segment) {
	old_head := transmute(Tagged_Pointer)intrinsics.atomic_load_explicit(cast(^u64)&heap_orphanage.empty, .Relaxed)
	for {
		count         := old_head.pointer & ODIN_HEAP_ORPHANAGE_COUNT_BITS
		untagged_head := uintptr(old_head.pointer) & ~uintptr(ODIN_HEAP_ORPHANAGE_COUNT_BITS)

		segment = cast(^Heap_Segment)uintptr(untagged_head)
		if segment == nil {
			assert_contextless(count == 0, "The heap allocator saw a nil pointer on the orphanage for empty segments but the count was not zero.")
			break
		}

		next := intrinsics.atomic_load_explicit(&segment.next_segment, .Acquire)
		new_head := Tagged_Pointer{
			pointer = i64(uintptr(next)) | (count - 1),
			version = old_head.version + 1,
		}

		old_head_, swapped := intrinsics.atomic_compare_exchange_weak_explicit(cast(^u64)&heap_orphanage.empty, transmute(u64)old_head, transmute(u64)new_head, .Acq_Rel, .Relaxed)
		if swapped {
			intrinsics.atomic_store_explicit(&segment.next_segment, nil, .Release)
			break
		}
		old_head = transmute(Tagged_Pointer)old_head_
	}
	if segment != nil {
		if segment.slab_size_class == class {
			// This segment matches our size class request and all of its slabs should be free.
			free_slabs_list := &local_heap.free_slabs[segment.slab_size_class]
			for i in 1..=len(segment.slabs) {
				slab := &segment.slabs[len(segment.slabs)-i]
				assert_contextless(slab.bin_size == 0, "The heap allocator found a slab that is not empty after having adopted from the orphanage for empty segments.")
				_push_slab(free_slabs_list, slab)
			}
			heap_add_segment(segment)
		} else {
			// Re-make the segment as we need.
			// This procedure will add it to the heap, as well as the empty slabs.
			heap_make_segment(bin_size, segment)
		}
	}

	return
}

//
// Globals
//

when VIRTUAL_MEMORY_SUPPORTED {
	// Upon a child thread's clean exit, this procedure will distribute any
	// remaining memory to the orphanage.
	//
	// Note that this will not run for the main thread, as no thread-local
	// cleaner procedures do.
	@(private="file", no_sanitize_address)
	heap_local_cleanup :: proc "odin" () {
		if local_heap == nil {
			// A thread without a heap could not have caused any dynamic memory
			// to be allocated, thus we exit.
			return
		}

		// Frees from other threads are parked on the Slabs they belong to, and
		// this is the last moment at which this heap can merge them. This is done
		// before any Segment is orphaned, because an orphaned Segment can be
		// adopted by another thread at any moment, and the merge reads and writes
		// the book-keeping which the adopting thread reads and writes. It is a
		// pass of its own, as the frees of a Slab can give that Slab, and with it
		// the whole Segment, back to the operating system.
		heap_merge_remote_frees()

		for segment := local_heap.segments; segment != nil; /**/ {
			next_segment := segment.next_segment

			// A segment which holds no bins at all is one the next thread to adopt
			// it has no use for the pages of until it does, so they are given back
			// now rather than waiting with the rest of the orphanage.
			if segment.allocated_bins == 0 {
				heap_purge_segment(segment)
			}

			heap_orphan_segment(segment)

			segment = next_segment
		}

		// The heap itself is an allocation brought about by the very first
		// allocation in a thread, thus we free it at the thread's exit.
		heap_release(local_heap)
		local_heap = nil
	}

	@(init, private="file")
	init_orphanage :: proc "contextless" () {
		add_thread_local_cleaner(heap_local_cleanup)
	}
}

/*
This is the global heap orphanage where Segments which are no longer in use by
a specific heap are pushed to. The two fields are lock-free linked lists.

`in_use` contains Segments that are either partially or fully allocated
and have been orphaned by their owning heaps.

`empty` contains Segments that have been entirely freed, kept on hand for quick
adoption by threads needing memory. It is doubly-tagged in that it supports an
embedded count to prevent acquiring too much unused memory from the operating
system.

`in_use_count` tracks how many Segments sit on the `in_use` list, which unlike
the `empty` list cannot embed a count (its low bits address the head) and
cannot be bounded (its Segments hold live bins). Both orphanage lists are
invisible to `get_local_heap_info`'s per-heap walk otherwise, so the counts
are reported there instead. They are maintained with wait-free atomics on
cold paths only: thread exit and Segment adoption.
*/
heap_orphanage: struct {
	in_use: Tagged_Pointer,
	empty:  Tagged_Pointer,
	// Heaps of threads which have exited, kept for the next thread to use.
	free_heaps: Tagged_Pointer,

	in_use_count: int,
}

// The size every Segment has, settled once by `heap_choose_segment_size` when
// the virtual memory layer is first set up.
@(private)
segment_size: int

// This is the Heap for the current thread.
@(thread_local) local_heap: ^Heap

//
// API
//

/*
Check that `ptr` is an address the allocator handed out.

This is a check the debug builds pay for: it finds the Slab the address belongs
to, and then asks that the address be the start of one of its bins. An address
inside an allocation, or one past the end of a Slab, is otherwise accepted and
handed out again later, over memory the program is still using.

The address has to belong to memory this heap owns for this to mean anything:
another allocator's memory is not covered by it, nor by the sanitizer's guards.
*/
@(private="file")
heap_check_free_address :: #force_inline proc "contextless" (ptr: rawptr, segment: ^Heap_Segment, slab: ^Heap_Slab) {
	// These checks read metadata that the caller is about to read anyway and
	// need no division, so they stay on in every build: an address which is not
	// the start of a bin would otherwise be handed out again over live memory.
	ensure_contextless(slab.bin_size > 0, "The heap allocator was given an address to free which belongs to a Slab that is not in use. This is a double free, or an address which never came from this heap.")

	// An address in front of the Slab's first bin, such as the Segment's own
	// book-keeping, would wrap the offset below into range.
	ensure_contextless(uintptr(ptr) >= slab.data, "The heap allocator was given an address to free which is in front of the first bin of its Slab. This is an address inside the heap's book-keeping, or one which never came from this heap.")

	offset := uintptr(ptr) - uintptr(slab.data)
	if segment.slab_size_class == .Huge {
		// A Huge Slab is sized for a single request, so there is one address it
		// can be given back.
		ensure_contextless(offset == 0, "The heap allocator was given an address to free which is not the start of the Huge allocation it belongs to.")
	} else {
		stride := uintptr(heap_bin_stride(slab.bin_size))
		when ODIN_HEAP_DEBUG_LEVEL < .Buffer_Overflow {
			// Bin sizes are powers of two, and without poisoned gaps the stride is the bin size.
			ensure_contextless(offset & (stride-1) == 0, "The heap allocator was given an address to free which is not the start of a bin. This is an address inside an allocation, or one which never came from this heap.")
		} else {
			ensure_contextless(offset % stride == 0, "The heap allocator was given an address to free which is not the start of a bin. This is an address inside an allocation, or one which never came from this heap.")
		}
		ensure_contextless(offset + stride <= uintptr(slab.capacity), "The heap allocator was given an address to free which is past the end of the Slab it belongs to.")
	}
}

/*
Allocate an arbitrary amount of memory from the heap and optionally zero it.

Callers asking not to zero it may observe bytes left behind by previous
allocations, and freed bins are handed out again immediately, so a stale
pointer never becomes safe to use through reuse.
*/
@(require_results, no_sanitize_address)
heap_alloc :: proc "contextless" (size: int, zero_memory: bool = true) -> (ptr: rawptr) {
	assert_contextless(size >= 0, "The heap allocator was given a negative size to allocate.")

	// Initialize the heap if needed.
	if intrinsics.expect(local_heap == nil, false) {
		local_heap = heap_acquire()
		if intrinsics.expect(local_heap == nil, false) {
			// The operating system may be out of memory.
			return nil
		}
	}

	// Get a suitable slab from the heap.
	ptr = heap_make_bin(size, zero_memory)

	return
}

/*
Free memory returned by `heap_alloc`.

The address must be exactly what the allocator handed out, freed exactly once.
An address which is not a Segment's, is not the start of a bin, or is the bin
freed last is caught in every build. A bin freed twice with others freed in
between is caught in a secure build (`ODIN_HEAP_SECURE`), except for a bin of a
single word, which has no room for a key.

`old_size` is what the caller believes it is giving back, where it knows, and
zero where it does not. A size larger than the bin means the caller is freeing
something other than what this allocator handed out, which jemalloc also
refuses on a sized free.
*/
@(no_sanitize_address)
heap_free :: proc "contextless" (ptr: rawptr, old_size: int = 0) {
	// Check for nil.
	if intrinsics.expect(ptr == nil, false) {
		return
	}

	segment := heap_find_segment_to_give_back(ptr)

	// NOTE: These guards won't protect us if someone uses the heap `free` on
	// the poisoned space of another allocator.
	when .Address in ODIN_SANITIZER_FLAGS {
		ensure_contextless(!sanitizer.address_is_poisoned(ptr), "The heap allocator tried to free a memory address poisoned by the sanitizer. This is either a double free or an invalid address within the heap space.")
		ensure_contextless(sanitizer.address_is_poisoned(segment), "The heap allocator tried to access the segment for a pointer being freed, and the segment was not poisoned by the address sanitizer. This is likely a free operation pointing to memory outside the scope of the heap.")
	}

	slab := &segment.slabs[(uintptr(ptr) - uintptr(segment)) >> segment.slab_shift]
	heap_check_free_address(ptr, segment, slab)
	ensure_contextless(old_size <= slab.bin_size, "The heap allocator was given a size to free which does not match the allocation. The old size must not be larger than the bin the address was handed out from.")

	// Depending on whether or not we own the address space for the pointer, we
	// will either free it directly and immediately or push it to a remote free
	// list.
	//
	// A free from another thread is parked on the Slab which holds the bin, and
	// the thread which owns that Slab merges it: a Slab is the only place such a
	// free can be left, since the heap which owns it may be gone before the bins
	// in it are.
	if intrinsics.atomic_load_explicit(&segment.owner, .Acquire) == get_current_thread_id() {
		heap_free_bin(segment, slab, ptr)
	} else {
		push_onto_remote_free_list(slab, &slab.remote_free_list, ptr)
	}
}

/*
Resize memory returned by `heap_alloc`.
*/
@(require_results, no_sanitize_address)
heap_resize :: proc "contextless" (old_ptr: rawptr, old_size: int, new_size: int, zero_memory: bool = true) -> (new_ptr: rawptr) {
	// Handle `nil` as if it was a new allocation.
	// This is the behavior seen in C's `realloc`.
	if old_ptr == nil {
		return heap_alloc(new_size, zero_memory)
	}
	assert_contextless(new_size >= 0, "The heap allocator was given a negative size to resize to.")
	if new_size < 0 {
		return nil
	}

	// Look up what the allocator actually handed out for this address.
	//
	// `old_size` comes from the caller and, like any length read from the
	// user, must not drive the `memcpy` below unchecked: a caller claiming
	// more than its bin holds would otherwise over-read the heap the way a
	// forged frame length over-reads its server, and a caller claiming less
	// could keep a too-small bin in place for a larger request.
	segment := heap_find_segment_to_give_back(old_ptr)
	slab := &segment.slabs[(uintptr(old_ptr) - uintptr(segment)) >> segment.slab_shift]
	heap_check_free_address(old_ptr, segment, slab)
	assert_contextless(slab.bin_size > 0, "The heap allocator was given an address to resize which belongs to a Slab that is not in use.")
	usable := slab.bin_size

	when ODIN_HEAP_DEBUG_LEVEL >= .Ensure_Zero {
		ensure_contextless(0 <= old_size && old_size <= usable, "The heap allocator was given a size to resize from which does not match the allocation. The old size must be within [0..=usable], where usable is the size of the bin the address was handed out from.")
	}

	// Clamp the caller's length to what is really there. Honest callers always
	// pass `old_size <= usable`, so this changes nothing for them, while a
	// forged length is cut down to the bin before it can drive the rank
	// decision, the copy, or the zeroing below. This mirrors how mimalloc
	// (`min(old_usable, newsize)`) and jemalloc (`min(old_usize, new_usize)`)
	// re-derive the old size from their own metadata instead of trusting it.
	effective_old_size := min(max(old_size, 0), usable)

	same_rank := false

	if usable <= ODIN_HEAP_MAX_BIN_SIZE && new_size <= ODIN_HEAP_MAX_BIN_SIZE {
		// The rank decision is made from the bin the address actually lives
		// in, never from the caller-supplied length.
		same_rank = slab.bin_size == heap_round_to_bin_size(new_size)
	}

	when .Address in ODIN_SANITIZER_FLAGS {
		ensure_contextless(sanitizer.address_region_is_poisoned(old_ptr, max(ODIN_HEAP_MIN_BIN_SIZE, effective_old_size)) == nil, "The heap allocator tried to resize a memory region poisoned by the sanitizer. This indicates an invalid pointer that may have never been heap allocated or has already been freed.")
		ensure_contextless(sanitizer.address_is_poisoned(segment), "The heap allocator tried to access the segment for a pointer being resized, and the segment address was not poisoned by the address sanitizer. This indicates an invalid heap pointer.")
	}

	if same_rank {
		sanitizer.address_unpoison(old_ptr, max(ODIN_HEAP_MIN_BIN_SIZE, new_size))

		// We can re-use the same bin.
		if zero_memory && new_size > effective_old_size {
			// Zero any old, dirty memory in the expanded region.
			intrinsics.mem_zero_volatile(
				rawptr(uintptr(old_ptr) + uintptr(effective_old_size)),
				new_size - effective_old_size,
			)
			// It could be argued that a full memory fence is necessary here,
			// because one thread may resize an address known to other threads,
			// but as is the case with zeroing during allocation, we treat this
			// as if the state change is not independent of the allocator.
			//
			// That is to say, if one thread resizes an address in-place, it's
			// expected that other threads will need to be notified of this by
			// the program, as with any other synchronization.
		}
		new_ptr = old_ptr
	} else if grown := heap_grow_in_place(old_ptr, effective_old_size, new_size); grown != nil {
		// The memory was made larger where it stood, which costs nothing beyond
		// the segments the operating system has to map.
		new_ptr = grown
		if zero_memory && new_size > effective_old_size {
			intrinsics.mem_zero_volatile(rawptr(uintptr(new_ptr) + uintptr(effective_old_size)), new_size - effective_old_size)
		}
	} else {
		// A change in bin rank requires a new bin; this allocator does no coalescence.
		new_ptr = heap_alloc(new_size, false)
		if intrinsics.expect(new_ptr == nil, false) {
			// The operating system may be out of memory.
			return
		}
		intrinsics.mem_copy_non_overlapping(new_ptr, old_ptr, min(effective_old_size, new_size))
		if zero_memory && new_size > effective_old_size {
			intrinsics.mem_zero_volatile(rawptr(uintptr(new_ptr) + uintptr(effective_old_size)), new_size - effective_old_size)
		}
		heap_free(old_ptr)
	}

	return
}

/*
Make an allocation larger where it stands, if it is one the Segment backing it
can simply be extended for.

Growing an allocation usually means making a copy of it, which costs a second
copy of the memory while that happens. A Huge allocation has a Segment to
itself, with nothing but its own book-keeping in front of it, so the pages
behind it can be extended as they are whenever the address space that follows
is free.

Returns nil if the memory could not be extended, leaving the allocation exactly
as it was for the caller to copy.
*/
@(no_sanitize_address)
heap_grow_in_place :: proc "contextless" (old_ptr: rawptr, old_size: int, new_size: int) -> rawptr {
	// The page which guards the end of a Huge allocation would be left in the
	// middle of the memory if it grew, so a secure heap copies instead.
	when ODIN_HEAP_SECURE {
		return nil
	}

	if new_size <= old_size || old_size <= ODIN_HEAP_MAX_BIN_SIZE {
		// Smaller allocations share a Segment, and a Segment cannot grow without
		// moving everything else in it.
		return nil
	}

	segment := find_segment_from_pointer(old_ptr)
	if intrinsics.atomic_load_explicit(&segment.owner, .Acquire) != get_current_thread_id() {
		return nil
	}
	if segment.slab_size_class != .Huge || len(segment.slabs) != 1 {
		return nil
	}

	slab := &segment.slabs[0]
	if rawptr(slab.data) != old_ptr {
		// This is not the address the program was handed.
		return nil
	}

	book_keeping := int(uintptr(slab.data) - uintptr(segment))

	// The addition below must not wrap: a new_size near max(int) would turn
	// grown_size negative, skip the operating-system grow as "already fits",
	// and still store the astronomical size in slab.bin_size, corrupting the
	// very metadata resize clamps against (CWE-190). Fail clean with nil, as
	// mimalloc does (`if (size >= SIZE_MAX - X) return NULL`) and jemalloc's
	// sz_s2u does by returning 0. Cold Huge-only path: one compare.
	if new_size > max(int) - book_keeping {
		return nil
	}
	grown_size := book_keeping + new_size

	// The book-keeping for a Huge allocation sits in front of its data, so a
	// growth small enough to fit in what is left of the mapping needs nothing
	// from the operating system: the pages are already there, they were simply
	// never handed out. Asking for a size the mapping already has would be a
	// request to shrink it, which `resize_virtual_memory_in_place` does not
	// accept.
	if grown_size > segment.size {
		if !resize_virtual_memory_in_place(segment, segment.size, grown_size) {
			return nil
		}
		segment.size = grown_size
	}

	// `capacity` is measured from `slab.data`, so the book-keeping in front of
	// it does not count towards it.
	slab.bin_size = new_size
	slab.capacity = segment.size - book_keeping

	sanitizer.address_unpoison(old_ptr, max(ODIN_HEAP_MIN_BIN_SIZE, new_size))

	return old_ptr
}
