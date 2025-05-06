package runtime

import "base:intrinsics"

// Atomic access to a `Tagged_Pointer` word.
//
// Targets with a 64-bit word use a lock-free 64-bit compare-and-swap. Targets
// with a 32-bit word, such as linux_i386, may have no lock-free 64-bit atomic,
// so there every access takes one spin lock instead. Both paths give the same
// results, and neither needs a C library.

HEAP_TAGGED_USE_LOCK :: size_of(rawptr) < 8

when HEAP_TAGGED_USE_LOCK {
	@(private="file")
	heap_tagged_lock: u32

	@(private="file")
	heap_tagged_lock_acquire :: proc "contextless" () {
		for {
			_, acquired := intrinsics.atomic_compare_exchange_weak_explicit(&heap_tagged_lock, 0, 1, .Acquire, .Relaxed)
			if acquired {
				return
			}
			intrinsics.cpu_relax()
		}
	}

	@(private="file")
	heap_tagged_lock_release :: proc "contextless" () {
		intrinsics.atomic_store_explicit(&heap_tagged_lock, 0, .Release)
	}
}

// Loads a `Tagged_Pointer` atomically.
@(require_results)
heap_tagged_load :: #force_inline proc "contextless" (word: ^Tagged_Pointer, $order: intrinsics.Atomic_Memory_Order) -> Tagged_Pointer {
	when HEAP_TAGGED_USE_LOCK {
		heap_tagged_lock_acquire()
		value := word^
		heap_tagged_lock_release()
		return value
	} else {
		return transmute(Tagged_Pointer)intrinsics.atomic_load_explicit(cast(^u64)word, order)
	}
}

// Compares `word` with `old` and, when they are equal, replaces it with `new`.
// Returns the value `word` held before the call, and whether the swap happened.
@(require_results)
heap_tagged_cas :: #force_inline proc "contextless" (word: ^Tagged_Pointer, old, new: Tagged_Pointer, $success, $failure: intrinsics.Atomic_Memory_Order) -> (Tagged_Pointer, bool) {
	when HEAP_TAGGED_USE_LOCK {
		heap_tagged_lock_acquire()
		observed := word^
		swapped := transmute(u64)observed == transmute(u64)old
		if swapped {
			word^ = new
		}
		heap_tagged_lock_release()
		return observed, swapped
	} else {
		observed, swapped := intrinsics.atomic_compare_exchange_weak_explicit(cast(^u64)word, transmute(u64)old, transmute(u64)new, success, failure)
		return transmute(Tagged_Pointer)observed, swapped
	}
}

// Atomically ORs `bits` into a `Tagged_Pointer` word.
heap_tagged_or :: #force_inline proc "contextless" (word: ^Tagged_Pointer, bits: u64, $order: intrinsics.Atomic_Memory_Order) {
	when HEAP_TAGGED_USE_LOCK {
		heap_tagged_lock_acquire()
		(cast(^u64)word)^ |= bits
		heap_tagged_lock_release()
	} else {
		intrinsics.atomic_or_explicit(cast(^u64)word, bits, order)
	}
}

// Atomically ANDs `bits` into a `Tagged_Pointer` word.
heap_tagged_and :: #force_inline proc "contextless" (word: ^Tagged_Pointer, bits: u64, $order: intrinsics.Atomic_Memory_Order) {
	when HEAP_TAGGED_USE_LOCK {
		heap_tagged_lock_acquire()
		(cast(^u64)word)^ &= bits
		heap_tagged_lock_release()
	} else {
		intrinsics.atomic_and_explicit(cast(^u64)word, bits, order)
	}
}
