#+private
package os

import "base:runtime"

@(require_results)
file_allocator :: proc() -> runtime.Allocator {
	return heap_allocator()
}

@(private="file")
MAX_TEMP_ARENA_COUNT :: 2
@(private="file")
MAX_TEMP_ARENA_COLLISIONS :: MAX_TEMP_ARENA_COUNT - 1
// First block for the per-thread scratch arenas. These arenas only hold
// short-lived cstring conversions (usually one or two paths), so a small
// first block avoids the 4 MB default arena block on every thread that
// touches the filesystem. The arena still grows on demand for larger uses
// such as process spawn argument lists.
@(private="file")
TEMP_ARENA_INITIAL_BLOCK_SIZE :: 16 * 1024
@(private="file", thread_local)
global_default_temp_allocator_arenas: [MAX_TEMP_ARENA_COUNT]runtime.Arena

@(fini, private)
temp_allocator_fini :: proc "contextless" () {
	for &arena in global_default_temp_allocator_arenas {
		runtime.arena_destroy(&arena)
	}
	global_default_temp_allocator_arenas = {}
}

Temp_Allocator :: struct {
	using arena: ^runtime.Arena,
	using allocator: runtime.Allocator,
	tmp: runtime.Arena_Temp,
	loc: runtime.Source_Code_Location,
}
	
TEMP_ALLOCATOR_GUARD_END :: proc(temp: Temp_Allocator) {
	runtime.arena_temp_end(temp.tmp, temp.loc)
}

@(deferred_out=TEMP_ALLOCATOR_GUARD_END)
TEMP_ALLOCATOR_GUARD :: #force_inline proc(collisions: []runtime.Allocator, loc := #caller_location) -> Temp_Allocator {
	assert(len(collisions) <= MAX_TEMP_ARENA_COLLISIONS, "Maximum collision count exceeded. MAX_TEMP_ARENA_COUNT must be increased!")
	good_arena: ^runtime.Arena
	for i in 0..<MAX_TEMP_ARENA_COUNT {
		good_arena = &global_default_temp_allocator_arenas[i]
		for c in collisions {
			if good_arena == c.data {
				good_arena = nil
			}
		}
		if good_arena != nil {
			break
		}
	}
	assert(good_arena != nil)
	if good_arena.backing_allocator.procedure == nil {
		good_arena.backing_allocator = heap_allocator()
		if good_arena.minimum_block_size == 0 {
			good_arena.minimum_block_size = TEMP_ARENA_INITIAL_BLOCK_SIZE
		}
		when ODIN_OS == .Linux && !ODIN_NO_CRT {
			// First use (or first use after the exit cleanup destroyed
			// these arenas): the fini cleaner must run again at the next
			// cleanup, so clear its completion bit for this thread.
			runtime._managed_thread_cleanup_reactivate(temp_allocator_fini)
		}
	}
	tmp := runtime.arena_temp_begin(good_arena, loc)
	return { good_arena, runtime.arena_allocator(good_arena), tmp, loc }
}

temp_allocator_begin :: runtime.arena_temp_begin
temp_allocator_end :: runtime.arena_temp_end
@(deferred_out=_temp_allocator_end)
temp_allocator_scope :: proc(tmp: Temp_Allocator) -> (runtime.Arena_Temp) {
	return temp_allocator_begin(tmp.arena)
}
@(private="file")
_temp_allocator_end :: proc(tmp: runtime.Arena_Temp) {
	temp_allocator_end(tmp)
}

@(init, private)
init_thread_local_cleaner :: proc "contextless" () {
	// Same idempotent helper the first-use path uses: exactly one slot no
	// matter which runs first.
	when ODIN_OS == .Linux && (!ODIN_NO_CRT || ODIN_ARCH == .amd64) {
		runtime._managed_thread_cleanup_reactivate(temp_allocator_fini)
	} else {
		runtime.add_thread_local_cleaner(temp_allocator_fini)
	}
}
