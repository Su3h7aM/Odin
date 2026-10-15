#+build linux amd64
package main

// Run in a disposable user namespace with at least two mapped IDs:
// odin build tests/core/thread/native_credentials -no-crt -out:/tmp/odin-credentials
// timeout 15 unshare -Ur --map-auto /tmp/odin-credentials
// This needs a separate process because it changes every native thread's IDs.
import "base:intrinsics"
import "base:runtime"
import "core:sys/linux"
import "core:sys/posix"
import "core:thread"

entry: runtime.Owned_Thread_Entry
child_tid: linux.Pid
child_go, phase: u32
child_uid, child_gid: u32
inherited_mask: linux.Sig_Set

child :: proc "c" (_: rawptr) -> i32 {
	for intrinsics.atomic_load(&child_go) == 0 {
		linux.sched_yield()
	}
	runtime._owned_thread_child_enter(&entry)
	assert_contextless(linux.rt_sigprocmask(.SIG_SETMASK, &inherited_mask, nil) == .NONE)
	for intrinsics.atomic_load(&phase) != 3 {
		linux.sched_yield()
	}
	intrinsics.atomic_store(&child_uid, u32(linux.getuid()))
	intrinsics.atomic_store(&child_gid, u32(linux.getgid()))
	runtime._owned_thread_unregister(&entry)
	return 0
}

change_credentials :: proc() {
	for intrinsics.atomic_load(&phase) == 0 {
		linux.sched_yield()
	}
	assert(posix.setgid(1) == .OK)
	assert(posix.setuid(1) == .OK)
	assert(posix.setgid(max(posix.gid_t)) == .FAIL)
	intrinsics.atomic_store(&phase, 2)
}

main :: proc() {
	assert(linux.getuid() == 0, "run this fixture in the user namespace documented above")
	layout, ok := runtime.linux_no_crt_tls_layout()
	assert(ok)
	size := uint(1024*1024) + uint(layout.size)
	memory, err := linux.mmap(0, size, {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
	assert(err == .NONE)
	defer linux.munmap(memory, size)
	stack := rawptr(uintptr(memory) + 1024*1024)
	tp := runtime.linux_no_crt_tls_init(layout, stack)
	broadcaster := thread.create_and_start(change_credentials)
	assert(broadcaster != nil)
	defer free(broadcaster)

	// Park a real clone before bring-up. Neither credential operation may
	// complete until the birth gate makes this child a broadcast target.
	saved := runtime._owned_thread_birth_begin()
	inherited_mask = linux.Sig_Set{uint(saved)}
	runtime._owned_thread_register(&entry)
	all_signals := linux.Sig_Set{max(uint)}
	restore_mask: linux.Sig_Set
	assert(linux.rt_sigprocmask(.SIG_BLOCK, &all_signals, &restore_mask) == .NONE)
	flags := u32(linux.CLONE_VM | linux.CLONE_FS | linux.CLONE_FILES | linux.CLONE_SIGHAND | linux.CLONE_THREAD | linux.CLONE_SYSVSEM | linux.CLONE_SETTLS | linux.CLONE_PARENT_SETTID | linux.CLONE_CHILD_CLEARTID)
	_, clone_err := linux.clone(child, stack, flags, nil, &child_tid, tp, &child_tid)
	assert(linux.rt_sigprocmask(.SIG_SETMASK, &restore_mask, nil) == .NONE)
	assert(clone_err == .NONE)
	intrinsics.atomic_store(&phase, 1)
	pause := linux.Time_Spec{0, 10_000_000}
	linux.nanosleep(&pause, nil)
	assert(intrinsics.atomic_load(&phase) == 1)
	intrinsics.atomic_store(&child_go, 1)
	for intrinsics.atomic_load(&entry.state) != u32(runtime.Owned_Thread_State.Running) {
		linux.sched_yield()
	}
	runtime._owned_thread_birth_end(saved)
	thread.join(broadcaster)
	assert(intrinsics.atomic_load(&phase) == 2)

	// Simulate a delayed acknowledgement after the failed request. The
	// handler must still see the preceding committed setuid, not setgid(-1).
	intrinsics.atomic_store(&entry.ack, 0)
	assert(linux.tgkill(linux.getpid(), child_tid, linux.Signal(runtime.OWNED_SIGSETXID)) == .NONE)
	for intrinsics.atomic_load(&entry.ack) == 0 {
		linux.sched_yield()
	}
	assert(intrinsics.atomic_load(&entry.apply_result) == 0)
	intrinsics.atomic_store(&phase, 3)
	for intrinsics.atomic_load(&child_tid) != 0 {
		linux.sched_yield()
	}
	assert(child_uid == 1 && child_gid == 1)
	assert(u32(linux.getuid()) == child_uid && u32(linux.getgid()) == child_gid)
}
