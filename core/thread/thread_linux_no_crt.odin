#+build linux
#+private
package thread

import "base:runtime"
import "base:intrinsics"
import "core:sync"
import "core:sys/linux"
import "core:strings"

_ :: runtime
_ :: intrinsics
_ :: sync
_ :: linux
_ :: strings

when ODIN_NO_CRT {
	when ODIN_ARCH != .amd64 && ODIN_ARCH != .arm64 && ODIN_ARCH != .riscv64 {
		#panic("core:thread without CRT on Linux requires amd64, arm64, or riscv64")
	}

	_IS_SUPPORTED :: true

	Thread_Os_Specific :: struct {
		mapping:  ^Linux_Thread_Mapping,
		start_ok: sync.Sema,
	}

	// The kernel's clear_tid word must outlive Thread, including self-cleanup.
	Linux_Thread_Mapping :: struct {
		memory: rawptr,
		size:   uint,
		tid:    linux.Pid,
		mask:   linux.Sig_Set,
		abort:  bool,
		next:   ^Linux_Thread_Mapping,
	}

	when ODIN_ARCH == .amd64 {
		// Registry node address for the credential/cancel protocol. The node
		// lives in tail space past the mapping inside the same allocation,
		// so it outlives the kernel thread's exit exactly like the mapping
		// itself. amd64 only; the allocation has no tail space elsewhere.
		@(private="file")
		_registry_node :: proc "contextless" (mapping: ^Linux_Thread_Mapping) -> ^runtime.Owned_Thread_Entry {
			addr := uintptr(mapping) + uintptr(size_of(Linux_Thread_Mapping))
			addr = (addr + 7) &~ 7
			return (^runtime.Owned_Thread_Entry)(rawptr(addr))
		}
	}

	pending_mappings_mutex: sync.Mutex
	pending_mappings: ^Linux_Thread_Mapping

	// Bounded cache of proven-exited thread mappings for stack reuse.
	// Thread creation maps an 8 MiB stack plus a guard page and tears it
	// down again at join; at 4800 create/join pairs that VM churn dominates
	// the lifecycle cost (measured +40% vs the libc thread path, which
	// caches stacks). A cached mapping is only ever handed out after the
	// joiner observed the kernel-cleared tid word, so the kernel is done
	// with it. Reuse re-initializes TLS and the registry node, rewrites
	// the tid pair at the next clone, and leaves the guard page mapping
	// untouched. Stack bytes are not scrubbed, matching libc stack reuse.
	// At most THREAD_MAPPING_CACHE_MAX idle mappings are kept; overflow is
	// released immediately, and a failed fresh mapping drains the cache
	// and retries once, so the cache is bounded and reclaimable.
	THREAD_MAPPING_CACHE_MAX :: 8

	thread_mapping_cache_mutex: sync.Mutex
	thread_mapping_cache: [THREAD_MAPPING_CACHE_MAX]^Linux_Thread_Mapping
	thread_mapping_cache_len: int

	_pop_cached_mapping :: proc "contextless" (size: uint) -> ^Linux_Thread_Mapping {
		// Same async-cancel deferral as the pending-mappings paths: a
		// thread terminated while holding this mutex would strand it for
		// every later create.
		when ODIN_ARCH == .amd64 {
			runtime._owned_cancel_mask_self()
			defer runtime._owned_cancel_unmask_self()
		}
		sync.mutex_lock(&thread_mapping_cache_mutex)
		defer sync.mutex_unlock(&thread_mapping_cache_mutex)
		for i := 0; i < thread_mapping_cache_len; i += 1 {
			if thread_mapping_cache[i].size == size {
				mapping := thread_mapping_cache[i]
				thread_mapping_cache_len -= 1
				thread_mapping_cache[i] = thread_mapping_cache[thread_mapping_cache_len]
				thread_mapping_cache[thread_mapping_cache_len] = nil
				return mapping
			}
		}
		return nil
	}

	_push_cached_mapping :: proc "contextless" (mapping: ^Linux_Thread_Mapping) -> bool {
		when ODIN_ARCH == .amd64 {
			runtime._owned_cancel_mask_self()
			defer runtime._owned_cancel_unmask_self()
		}
		sync.mutex_lock(&thread_mapping_cache_mutex)
		defer sync.mutex_unlock(&thread_mapping_cache_mutex)
		if thread_mapping_cache_len < THREAD_MAPPING_CACHE_MAX {
			thread_mapping_cache[thread_mapping_cache_len] = mapping
			thread_mapping_cache_len += 1
			return true
		}
		return false
	}

	_drain_cached_mappings :: proc "contextless" () {
		when ODIN_ARCH == .amd64 {
			runtime._owned_cancel_mask_self()
			defer runtime._owned_cancel_unmask_self()
		}
		sync.mutex_lock(&thread_mapping_cache_mutex)
		defer sync.mutex_unlock(&thread_mapping_cache_mutex)
		for i := 0; i < thread_mapping_cache_len; i += 1 {
			m := thread_mapping_cache[i]
			thread_mapping_cache[i] = nil
			linux.munmap(m.memory, m.size)
		}
		thread_mapping_cache_len = 0
	}

	_reap_pending_mappings :: proc "contextless" () {
		// Async-cancel deferral across the mutex hold: a thread terminated
		// while holding pending_mappings_mutex would strand it for every
		// later create/join/exit. Deferred first so the replay observes the
		// unlocked mutex: defers run LIFO (unlock, then unmask).
		// The hooks exist only where the protocol runs (amd64 noCRT); other
		// targets install no 32 handler, so termination cannot strand these
		// mutexes there.
		when ODIN_ARCH == .amd64 {
			runtime._owned_cancel_mask_self()
			defer runtime._owned_cancel_unmask_self()
		}
		sync.mutex_lock(&pending_mappings_mutex)
		defer sync.mutex_unlock(&pending_mappings_mutex)
		prev: ^Linux_Thread_Mapping
		for it := pending_mappings; it != nil; /**/ {
			next := it.next
			if sync.atomic_load_explicit(&it.tid, .Acquire) == 0 {
				if prev == nil {
					pending_mappings = next
				} else {
					prev.next = next
				}
				when ODIN_ARCH == .amd64 {
					runtime._owned_thread_unregister(_registry_node(it))
				}
				linux.munmap(it.memory, it.size)
			} else {
				prev = it
			}
			it = next
		}
	}

	_queue_pending_mapping :: proc "contextless" (mapping: ^Linux_Thread_Mapping) {
		// Same deferral as the reap path: never strand the mutex under an
		// async cancel; replay only after the unlock below has run.
		when ODIN_ARCH == .amd64 {
			runtime._owned_cancel_mask_self()
			defer runtime._owned_cancel_unmask_self()
		}
		sync.mutex_lock(&pending_mappings_mutex)
		defer sync.mutex_unlock(&pending_mappings_mutex)
		mapping.next = pending_mappings
		pending_mappings = mapping
	}

	_linux_thread_entry :: proc "c" (arg: rawptr) -> i32 {
		t := (^Thread)(arg)
		mapping := t.mapping
		context = runtime.default_context()
		when ODIN_ARCH == .amd64 {
			// Keep application signals blocked until Running. A handler
			// calling a credential setter before then would wait on the
			// creator's gate while the creator waits on this child.
			runtime._owned_thread_child_enter(_registry_node(mapping))
		}
		err := linux.rt_sigprocmask(.SIG_SETMASK, &mapping.mask, nil)
		assert_contextless(err == .NONE)
		// Always consume the post, even if Started is already set. Otherwise a
		// self-cleanup thread could free Thread before start posts its semaphore.
		sync.wait(&t.start_ok)
		if mapping.abort {
			when ODIN_ARCH == .amd64 {
				runtime._owned_thread_unregister(_registry_node(mapping))
			}
			return 0
		}

		init_context := t.init_context
		context = _select_context_for_thread(init_context)
		_set_name(t)
		t.procedure(t)
		all_signals := linux.Sig_Set{max(uint)}
		err = linux.rt_sigprocmask(.SIG_BLOCK, &all_signals, nil)
		assert_contextless(err == .NONE)
		self_cleanup := .Self_Cleanup in sync.atomic_load(&t.flags)
		if self_cleanup {
			// Free before cleaners tear down this thread's allocator state.
			// The kernel's clear_tid word is in mapping, not the freed Thread.
			free(t, t.creation_allocator)
		}
		_maybe_destroy_default_temp_allocator(init_context)
		runtime.run_thread_local_cleaners()
		if self_cleanup {
			_queue_pending_mapping(mapping)
		} else {
			sync.atomic_or(&t.flags, {.Done})
		}
		when ODIN_ARCH == .amd64 {
			// Unregister before the kernel exits this thread; the mapping
			// (and node) stays valid until the joiner releases it. Join and
			// the cancel handler unregister defensively as well.
			runtime._owned_thread_unregister(_registry_node(mapping))
		}
		return 0
	}

	when ODIN_ARCH == .amd64 {
		// No allocation or user callback while the birth gate is held.
		// The child inherits current credentials and becomes signal-ready
		// before any subsequent broadcast can begin.
		_clone_owned_thread :: proc "contextless" (t: ^Thread, stack, tp: rawptr) -> (pid: linux.Pid, err: linux.Errno) {
			mapping := t.mapping
			node := _registry_node(mapping)
			saved := runtime._owned_thread_birth_begin()
			defer runtime._owned_thread_birth_end(saved)
			mapping.mask = linux.Sig_Set{uint(saved)}
			runtime._owned_thread_register(node)

			all_signals := linux.Sig_Set{max(uint)}
			restore_mask: linux.Sig_Set
			if err = linux.rt_sigprocmask(.SIG_BLOCK, &all_signals, &restore_mask); err != .NONE {
				runtime._owned_thread_unregister(node)
				return
			}
			flags := u32(linux.CLONE_VM | linux.CLONE_FS | linux.CLONE_FILES | linux.CLONE_SIGHAND | linux.CLONE_THREAD | linux.CLONE_SYSVSEM | linux.CLONE_SETTLS | linux.CLONE_PARENT_SETTID | linux.CLONE_CHILD_CLEARTID)
			pid, err = linux.clone(_linux_thread_entry, stack, flags, t, &mapping.tid, tp, &mapping.tid)
			mask_err := linux.rt_sigprocmask(.SIG_SETMASK, &restore_mask, nil)
			assert_contextless(mask_err == .NONE)
			if err != .NONE {
				runtime._owned_thread_unregister(node)
				return
			}
			for intrinsics.atomic_load(&node.state) != u32(runtime.Owned_Thread_State.Running) {
				if sync.atomic_load_explicit(&mapping.tid, .Acquire) == 0 {
					break
				}
				linux.sched_yield()
			}
			return
		}
	}

	_create :: proc(procedure: Thread_Proc, priority: Thread_Priority, name: Maybe(string)) -> ^Thread {
		when ODIN_NO_THREAD_LOCAL {
			return nil
		}
		_reap_pending_mappings()
		layout, ok := runtime.linux_no_crt_tls_layout()
		if !ok || layout.size == 0 {
			return nil
		}
		page := uint(runtime.get_page_size())
		stack_size := uint(8*1024*1024)
		limit: linux.RLimit
		if linux.prlimit64(0, .STACK, nil, &limit) == .NONE && limit.cur > 0 && limit.cur != max(uint) {
			stack_size = limit.cur
		}
		// Leave room for runtime entry and cleaners with a small stack limit.
		stack_size = max(stack_size, uint(64*1024))
		if stack_size > uint(max(int)) - page || layout.size > uintptr(max(int)) - uintptr(page) - size_of(Linux_Thread_Mapping) - (align_of(Linux_Thread_Mapping) - 1) {
			return nil
		}
		stack_size = (stack_size + page - 1) & ~(page - 1)
		metadata_offset := (uint(layout.size) + align_of(Linux_Thread_Mapping) - 1) & ~(uint(align_of(Linux_Thread_Mapping)) - 1)
		extra := metadata_offset + size_of(Linux_Thread_Mapping)
		when ODIN_ARCH == .amd64 {
			// Tail space past the mapping holds the registry node, with a
			// few slack bytes covering its alignment shift. The overflow
			// check below accounts for it; other architectures skip all of it.
			extra += size_of(runtime.Owned_Thread_Entry) + size_of(rawptr)
		}
		if stack_size > uint(max(int)) - page - extra {
			return nil
		}
		size := page + stack_size + extra
		memory: rawptr
		mapping: ^Linux_Thread_Mapping
		if cached := _pop_cached_mapping(size); cached != nil {
			mapping = cached
			mapping.abort = false
			mapping.next = nil
			memory = mapping.memory
		} else {
			fresh, mmap_err := linux.mmap(0, size, {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
			if mmap_err != .NONE {
				_drain_cached_mappings()
				fresh, mmap_err = linux.mmap(0, size, {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
				if mmap_err != .NONE {
					return nil
				}
			}
			if linux.mprotect(fresh, page, {}) != .NONE {
				linux.munmap(fresh, size)
				return nil
			}
			memory = fresh
		}
		stack := rawptr(uintptr(memory) + uintptr(page + stack_size))
		tp := runtime.linux_no_crt_tls_init(layout, stack)
		if mapping == nil {
			mapping = (^Linux_Thread_Mapping)(rawptr(uintptr(stack) + uintptr(metadata_offset)))
			mapping.memory = memory
			mapping.size = size
		}
		when ODIN_ARCH == .amd64 {
			// Initialize the node before taking the birth gate. The clone
			// helper registers it only after allocation is complete.
			node := _registry_node(mapping)
			node.next = nil
			intrinsics.atomic_store(&node.tid, 0)
			intrinsics.atomic_store(&node.state, u32(runtime.Owned_Thread_State.Starting))
			intrinsics.atomic_store(&node.ack, 0)
			intrinsics.atomic_store(&node.apply_result, 0)
			intrinsics.atomic_store(&node.exit_code, 0)
			intrinsics.atomic_store(&node.cancel_requested, 0)
			intrinsics.atomic_store(&node.cancel_mask, 0)
			intrinsics.atomic_store(&node.cancel_pending, 0)
			intrinsics.atomic_store(&node.bringup_error, 0)
		}
		when ODIN_ARCH == .amd64 {
			// A terminated creator must not orphan a child waiting for
			// start_ok. Replay cancellation after the create decision.
			runtime._owned_cancel_mask_self()
			defer runtime._owned_cancel_unmask_self()
		}
		t := new(Thread)
		if t == nil {
			when ODIN_ARCH == .amd64 {
				runtime._owned_thread_unregister(_registry_node(mapping))
			}
			linux.munmap(memory, size)
			return nil
		}
		t.creation_allocator = context.allocator
		t.mapping = mapping
		t.procedure = procedure
		t.name = name

		pid: linux.Pid
		clone_err: linux.Errno
		when ODIN_ARCH == .amd64 {
			pid, clone_err = _clone_owned_thread(t, stack, tp)
		} else {
			all_signals := linux.Sig_Set{max(uint)}
			if linux.rt_sigprocmask(.SIG_BLOCK, &all_signals, &mapping.mask) != .NONE {
				free(t, t.creation_allocator)
				linux.munmap(memory, size)
				return nil
			}
			flags := u32(linux.CLONE_VM | linux.CLONE_FS | linux.CLONE_FILES | linux.CLONE_SIGHAND | linux.CLONE_THREAD | linux.CLONE_SYSVSEM | linux.CLONE_SETTLS | linux.CLONE_PARENT_SETTID | linux.CLONE_CHILD_CLEARTID)
			pid, clone_err = linux.clone(_linux_thread_entry, stack, flags, t, &mapping.tid, tp, &mapping.tid)
			mask_err := linux.rt_sigprocmask(.SIG_SETMASK, &mapping.mask, nil)
			assert(mask_err == .NONE)
		}
		if clone_err != .NONE {
			when ODIN_ARCH == .amd64 {
				runtime._owned_thread_unregister(_registry_node(mapping))
			}
			free(t, t.creation_allocator)
			linux.munmap(memory, size)
			return nil
		}
		when ODIN_ARCH == .amd64 {
			// The helper released the birth gate only after readiness or
			// kernel exit. Failed bring-up never reaches user code.
			bnode := _registry_node(mapping)
			if sync.atomic_load_explicit(&mapping.tid, .Acquire) == 0 || intrinsics.atomic_load(&bnode.bringup_error) != 0 {
				mapping.abort = true
				_join(t)
				free(t, t.creation_allocator)
				return nil
			}
		}
		t.id = int(pid)
		// pthread's default SCHED_OTHER policy has priority zero for all three
		// priorities. Set it explicitly rather than inherit realtime scheduling.
		params: linux.Sched_Param
		if linux.sched_setscheduler(pid, i32(linux.Sched_Policy.OTHER), &params) != .NONE {
			mapping.abort = true
			_join(t)
			free(t, t.creation_allocator)
			return nil
		}
		return t
	}

	_start :: proc(t: ^Thread) {
		sync.atomic_or(&t.flags, {.Started})
		sync.post(&t.start_ok)
	}

	_is_done :: proc(t: ^Thread) -> bool {
		return .Done in sync.atomic_load(&t.flags)
	}

	_join :: proc(t: ^Thread) {
		_reap_pending_mappings()
		if t.id == int(linux.gettid()) {
			return
		}
		if .Joined in sync.atomic_or(&t.flags, {.Joined}) {
			return
		}
		if .Started not_in sync.atomic_load(&t.flags) {
			_start(t)
		}
		mapping := t.mapping
		for tid := sync.atomic_load_explicit(&mapping.tid, .Acquire); tid != 0; tid = sync.atomic_load_explicit(&mapping.tid, .Acquire) {
			// CHILD_CLEARTID wakes a shared futex, not FUTEX_WAIT_PRIVATE.
			err := linux.futex_wait((^linux.Futex)(&mapping.tid), .WAIT, {}, u32(tid))
			assert(err == .NONE || err == .EINTR || err == .EAGAIN)
		}
		// The kernel has finished the thread, whether it returned, faulted,
		// or was terminated: mark it done here since nobody else will. The
		// normal path already set this itself; the or is idempotent.
		sync.atomic_or(&t.flags, {.Done})
		when ODIN_ARCH == .amd64 {
			runtime._owned_thread_unregister(_registry_node(mapping))
		}
		// The futex wait above proved kernel exit, so the mapping may back
		// the next thread. Overflow is released immediately.
		if !_push_cached_mapping(mapping) {
			linux.munmap(mapping.memory, mapping.size)
		}
		t.mapping = nil
		_reap_pending_mappings()
	}

	_join_multiple :: proc(threads: ..^Thread) {
		for t in threads {
			_join(t)
		}
	}

	_destroy :: proc(t: ^Thread) {
		_join(t)
		free(t, t.creation_allocator)
	}

	_terminate :: proc(t: ^Thread, exit_code: int) {
		when ODIN_ARCH == .amd64 {
			// Asynchronous forceful termination through the owned cancel
			// protocol: the target performs no cleanup on the way out, so
			// locks it held stay held and memory it owned stays owned. Only
			// the low 8 bits of the exit code survive the raw thread exit.
			// A thread that already exited needs no signal; join reaps it.
			// Before startup wiring installs the handlers, signaling would
			// hit default dispositions: keep the old explicit panic instead.
			if runtime._owned_protocol_ready() && t.mapping != nil {
				intrinsics.atomic_store(&_registry_node(t.mapping).exit_code, i32(exit_code))
				intrinsics.atomic_store(&_registry_node(t.mapping).cancel_requested, 1)
				// A zero tid means not yet born or already reaped: the
				// bring-up replay covers pre-birth arming, and a reaped
				// thread needs nothing. The arm above is kept in both
				// cases; only the signal is conditional.
				tid := sync.atomic_load_explicit(&t.mapping.tid, .Acquire)
				if tid != 0 {
					// Group-scoped like the registry's own sends: a recycled
					// tid must never route the cancel into an unrelated
					// process, where the default disposition would terminate
					// it. ESRCH (or a zero tid above) means already exited: a
					// valid no-op. Any other delivery error asserts loudly:
					// this void API must not claim a termination it did not
					// deliver.
					err := linux.tgkill(linux.getpid(), tid, linux.Signal(runtime.OWNED_SIGCANCEL))
					assert(err == .NONE || err == .ESRCH)
				}
				return
			}
			if t.mapping == nil {
				return
			}
		}
		panic("thread.terminate is unsupported without CRT on Linux; asynchronous cancellation cannot safely run thread-local cleaners")
	}

	_yield :: proc() {
		linux.sched_yield()
	}

	_set_name :: proc(t: ^Thread) {
		name, ok := t.name.?
		if !ok {
			return
		}
		linux_thread_set_name(name)
	}

	_get_name :: proc(t: ^Thread, allocator: runtime.Allocator, loc: runtime.Source_Code_Location) -> (string, runtime.Allocator_Error) {
		if t == nil {
			return linux_thread_self_name(allocator, loc)
		}
		return linux_thread_get_name(t.id, allocator, loc)
	}
}
