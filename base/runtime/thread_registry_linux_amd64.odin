#+build linux
#+no-instrumentation
package runtime

import "base:intrinsics"

// Owned-thread registry and targeted-signal credential/cancel protocol for
// Linux amd64 without the C runtime.
//
// Used by the Linux amd64 no-CRT profile. Managed builds keep libc threads.
//
// Ownership and lifetime rules:
//   - Every live owned thread has exactly one registry entry. Entry storage
//     is owned by the embedder (core thread mapping) and must outlive the
//     kernel thread's exit; unregister before freeing, never after.
//   - All entry fields are atomic-only: the broadcast poller, signal
//     handlers, and list surgery access them concurrently.
//   - The registry spinlock is held only for short pointer surgery, never
//     across a blocking call or a callback. Signal handlers use bounded
//     try-spins plus a broadcaster deadline, never unbounded spins.
//   - The broadcast op struct lives in static storage; there is no aux
//     pointer with caller lifetime. Only immediates cross threads.

// The node and op types are defined on every Linux architecture so embedders
// can name them unconditionally, as can the small numeric constants; the
// protocol itself runs on amd64 noCRT only, matching the single native
// thread backend.
//
// Embedder-owned per-thread node. The embedder (core thread mapping)
// allocates this alongside state that already outlives the kernel thread's
// exit, registers before unmasking protocol signals, and unregisters before
// freeing. Idempotent unregister covers abnormal exits.
Owned_Thread_Entry :: struct {
	next:             ^Owned_Thread_Entry,
	tid:              i32, // atomic; 0 until the kernel reports it
	state:            u32, // atomic; Owned_Thread_State
	ack:              u64, // atomic; last applied broadcast sequence
	// Raw result of the last SETXID op application: 0 on success, negative
	// errno on failure. Stored before ack (all entry accesses are
	// sequentially consistent), so any observer that sees ack == current seq
	// also sees the matching result. Without this the broadcaster could
	// report success for a thread whose apply failed silently, leaving
	// divergent privileges behind a 0 return.
	apply_result:     i32, // atomic; valid once ack is current
	exit_code:        i32, // atomic; consumed by the cancel handler
	cancel_requested: u32, // atomic flag; validated by the cancel handler
	// Async-cancel deferral across runtime critical sections. A thread
	// terminated while holding broadcast_lock or registry_lock would leave
	// the lock held forever; instead critical sections increment
	// cancel_mask, the 32 handler then only records cancel_pending and
	// returns, and the unmask replays the cancel with a self signal after
	// the locks are released. The user-visible contract stays asynchronous:
	// termination is deferred across runtime internals only, never dropped.
	cancel_mask:      u32, // atomic; >0 while in a runtime critical section
	cancel_pending:   u32, // atomic; a deferred cancel awaits replay
	// Bring-up result recorded by the child before it marks itself Running:
	// 0 when the protocol unmask succeeded, negative kernel errno when the
	// unmask failed. The creator's readiness handshake reads this paired
	// with Running, so a child with blocked protocol signals never runs
	// user code unnoticed.
	bringup_error:    i32, // atomic; set once by the child before Running
}

Owned_Thread_State :: enum u32 {
	Starting = 0,
	Running  = 1,
}

// Credential families the broadcast applies. Immediates only, so the op
// needs no lifetime beyond the broadcast call itself.
Owned_Cred_Op :: enum u32 {
	None        = 0,
	Set_Uid     = 1,
	Set_Gid     = 2,
	Set_Res_Uid = 3,
	Set_Res_Gid = 4,
	Set_Re_Uid  = 5,
	Set_Re_Gid  = 6,
}

// Protocol signals, reserved in the owned profile. These match the
// managed profile's glibc reservation model (SIGCANCEL 32, SIGSETXID
// 33), so neither profile steals user-visible real-time signals: user
// code owns 34..64. Numbers are kernel numbers; no libc SIGRTMIN exists
// here to consult.
OWNED_SIGCANCEL :: 32
OWNED_SIGSETXID :: 33
OWNED_FIRST_USER_RT :: 34
OWNED_LAST_RT     :: 64

when ODIN_NO_CRT && ODIN_ARCH == .amd64 {
	// Raw syscall numbers, asm/unistd_64.h and arch/x86/entry/syscalls.
	_SYS_write          :: 1
	_SYS_gettid        :: 186
	_SYS_rt_sigaction  :: 13
	_SYS_rt_sigprocmask :: 14
	_SYS_rt_sigreturn  :: 15
	_SYS_sched_yield   :: 24
	_SYS_getpid        :: 39
	_SYS_exit          :: 60
	_SYS_exit_group     :: 231
	_SYS_clock_gettime :: 228
	_SYS_setuid        :: 105
	_SYS_setgid        :: 106
	_SYS_setreuid      :: 113
	_SYS_setregid      :: 114
	_SYS_setresuid     :: 117
	_SYS_setresgid     :: 119
	_SYS_tgkill        :: 234
	_SYS_CLOCK_MONOTONIC :: 1

	_SA_RESTORER :: u64(1) << 26
	_SA_SIGINFO  :: u64(1) << 2
	_SI_TKILL    :: i32(-6)

	// Kernel sigaction for rt_sigaction, asm-generic/signal.h layout on
	// amd64: handler, flags, restorer, then the 64-bit mask.
	_Kernel_Sigaction :: struct {
		handler:  rawptr,
		flags:    u64,
		restorer: rawptr,
		mask:     u64,
	}

	// First bytes of siginfo_t, asm-generic/siginfo.h: signo, errno, code,
	// then the kill-specific pid/uid pair the handler validates.
	_Kernel_Siginfo :: struct {
		signo: i32,
		errno: i32,
		code:  i32,
		_pad:  i32,
		pid:   i32,
		uid:   u32,
	}

	_Kernel_Timespec :: struct {
		sec:  i64,
		nsec: i64,
	}

	@(private="file") registry_lock: uintptr
	@(private="file") registry_head: ^Owned_Thread_Entry
	@(private="file") broadcast_seq: u64
	@(private="file") broadcast_kind: u32
	@(private="file") broadcast_a, broadcast_b, broadcast_c: i64
	@(private="file") process_pid: i32

	// Signal handlers retry reads while an operation is being committed.
	@(private="file") broadcast_epoch: u64

	// Serializes whole broadcasts. Targets never need this lock to apply or
	// acknowledge (handlers are lock-free), so a waiting broadcaster cannot
	// deadlock a target, and a target blocked joining a broadcast still acks
	// other broadcasters' signals. Same-thread re-entry needs no error path:
	// every hold span blocks application signals first (see the mask helpers),
	// so a user handler can never interrupt the holding thread; any handler
	// that does run holds no gate by invariant, and its nested coordinated
	// setter is a fresh broadcast that serializes normally. Concurrent
	// same-op broadcasts would otherwise steal each other's sequence numbers
	// and all time out.
	@(private="file") broadcast_lock: uintptr
	@(private="file") initial_entry: Owned_Thread_Entry

	// Application-signal mask for lock holds. setuid/setgid are
	// async-signal-safe per man7 signal-safety, so a coordinated setter may
	// run inside a user signal handler that interrupted anything, including
	// another registry/broadcast critical section on this same thread. Every
	// registry_lock take therefore blocks application signals first, keeping
	// only the protocol pair (32 cancel, 33 setxid) deliverable: a handler
	// cannot observe a half-held registry, and 33 still reaches targets
	// sitting in their own masked takes (the 33 path takes no locks) while
	// 32 defers through the cancel guard. Block/restore pairs nest by
	// save/restore (not refcount): each restores exactly what it saved.
	@(private="file")
	_owned_app_signals_block :: proc "contextless" () -> u64 {
		block: u64 = ~u64(0) &~ ((u64(1) << (OWNED_SIGCANCEL - 1)) | (u64(1) << (OWNED_SIGSETXID - 1)))
		old: u64
		_ = intrinsics.syscall(_SYS_rt_sigprocmask, 0 /* SIG_BLOCK */, uintptr(rawptr(&block)), uintptr(rawptr(&old)), 8)
		return old
	}
	@(private="file")
	_owned_app_signals_restore :: proc "contextless" (old: u64) {
		cur := old
		_ = intrinsics.syscall(_SYS_rt_sigprocmask, 2 /* SIG_SETMASK */, uintptr(rawptr(&cur)), 0, 8)
	}

	// Set once _owned_credentials_init installs both handlers. Broadcasts,
	// unmasking, and termination use signals only past this point; before it
	// every path stays direct-only so a reserved signal is never unmasked
	// with its default (terminate) disposition. Written once during
	// single-threaded startup; plain storage is sufficient.
	@(private="file") protocol_ready: bool

	// Per-thread self pointer for signal handlers, which cannot safely walk
	// the list. Set at bootstrap for the initial thread and by each child
	// before it unmasks protocol signals.
	@(private="file", thread_local)
	owned_self_entry: ^Owned_Thread_Entry

	// Whether the protocol handlers are installed. Core creation,
	// termination, and broadcast paths consult this so nothing signals
	// before startup wiring runs.
	_owned_protocol_ready :: proc "contextless" () -> bool {
		return protocol_ready
	}

	// 0 on success, negative kernel errno on failure. int because this file
	// cannot import core and its Errno type.
	_raw_check :: #force_inline proc "contextless" (r: int) -> int {
		if r < 0 && r >= -4095 {
			return r
		}
		return 0
	}

	_raw_gettid :: #force_inline proc "contextless" () -> i32 {
		return i32(intrinsics.syscall(_SYS_gettid))
	}

	_raw_getpid :: #force_inline proc "contextless" () -> i32 {
		return i32(intrinsics.syscall(_SYS_getpid))
	}

	// Fail-closed whole-process termination for irrecoverable credential
	// divergence. Past publication a broadcast failure means threads may
	// hold different privileges with no rollback possible, so returning an
	// ordinary error (or merely refusing future calls while the diverged
	// threads keep running) is fail-open. This writes a diagnostic with
	// the raw write syscall and ends the process with exit_group: no
	// allocation, no locks, no libc, no cleanup to wedge. Never returns.
	@(private="file")
	_owned_fatal_diverged :: proc "contextless" (code: int) -> ! {
		msg: [96]u8
		n := 0
		emit :: proc "contextless" (buf: ^[96]u8, n: ^int, s: string) {
			for i in 0..<len(s) {
				if n^ >= len(buf^) {
					return
				}
				buf^[n^] = s[i]
				n^ += 1
			}
		}
		emit(&msg, &n, "odin: credential broadcast diverged (errno ")
		v := code
		if v < 0 {
			if n < len(msg) {
				msg[n] = '-'
				n += 1
			}
			v = -v
		}
		start := n
		if v == 0 {
			if n < len(msg) {
				msg[n] = '0'
				n += 1
			}
		} else {
			for v > 0 && n < len(msg) {
				msg[n] = u8(v % 10) + '0'
				n += 1
				v /= 10
			}
			for i := start; i < (start + n) / 2; i += 1 {
				j := start + n - 1 - i
				msg[i], msg[j] = msg[j], msg[i]
			}
		}
		emit(&msg, &n, ")\n")
		off := 0
		for off < n {
			r := int(intrinsics.syscall(_SYS_write, 2, uintptr(rawptr(&msg[off])), uintptr(n - off)))
			if r < 0 {
				if r != -4 /* EINTR */ {
					break
				}
			} else if r == 0 {
				break
			} else {
				off += r
			}
		}
		intrinsics.syscall(_SYS_exit_group, 1)
		unreachable()
	}

	// Single typed leaf for unmasking the two protocol signals, so every
	// in-file mask call shares one correct 4-argument rt_sigprocmask with
	// sigsetsize 8. A 3-argument call leaves the 4th kernel argument (r10,
	// the set size) as stale residue, which fails or misbehaves depending
	// on residue and optimization level. Raw kernel behaviour documented
	// here, not replicated per call site. Returns the _raw_check'd result;
	// bring-up callers must record it (a failed unmask leaves protocol
	// signals blocked and must fail thread creation loudly, never run
	// user code with a silently blocked protocol).
	@(private="file")
	_owned_unmask_protocol :: proc "contextless" () -> int {
		unmask: u64 = (u64(1) << (OWNED_SIGCANCEL - 1)) | (u64(1) << (OWNED_SIGSETXID - 1))
		return _raw_check(int(intrinsics.syscall(_SYS_rt_sigprocmask, 1 /* SIG_UNBLOCK */, uintptr(rawptr(&unmask)), 0, 8)))
	}

	// Bootstrap the registry. Called once after TP install, before environ
	// publication and before any constructor or thread spawn. Allocation-free
	// and infallible by construction: BSS zero-state plus two raw syscalls
	// that cannot fail. Registers the initial thread as running.
	_owned_thread_registry_bootstrap :: proc "contextless" () {
		registry_lock = 0
		registry_head = nil
		broadcast_seq = 0
		process_pid = _raw_getpid()
		initial_entry = Owned_Thread_Entry{
			next             = nil,
			tid              = _raw_gettid(),
			state            = u32(Owned_Thread_State.Running),
			ack              = 0,
			apply_result     = 0,
			exit_code        = 0,
			cancel_requested = 0,
			cancel_mask      = 0,
			cancel_pending   = 0,
			bringup_error    = 0,
		}
		registry_head = &initial_entry
		owned_self_entry = &initial_entry
	}

	// Deferral helpers for every runtime critical section. Masking is
	// self-only (same thread sets and clears its own entry's counter), so
	// the signal handler's observation is exact: masked means this thread
	// is inside a critical section right now. Unmask replays a deferred
	// cancel with a self signal after the locks are released; a thread
	// that was exiting anyway simply exits there. Nil TLS (foreign
	// threads) masks nothing; foreign threads also ignore the cancel
	// signal, so they can neither strand a lock nor need replay.
	// Deliberately package-visible (not file-private): core thread guards
	// its own mutex holds with these. Odin names, no C link names, no
	// POSIX public API; the contract is documented above.
	_owned_cancel_mask_self :: proc "contextless" () {
		e := owned_self_entry
		if e != nil {
			intrinsics.atomic_add(&e.cancel_mask, 1)
		}
	}
	_owned_cancel_unmask_self :: proc "contextless" () {
		e := owned_self_entry
		if e == nil {
			return
		}
		// atomic_sub returns the previous value; 1 means the counter just
		// reached zero. A signal arriving after the decrement sees an
		// unmasked thread and exits directly; one arriving before set the
		// pending flag, which the exchange below replays. No interleaving
		// loses an armed cancel.
		if intrinsics.atomic_sub(&e.cancel_mask, 1) == 1 {
			if intrinsics.atomic_exchange(&e.cancel_pending, 0) != 0 {
				// Group-scoped: a recycled tid must never route the replay
				// into an unrelated process.
				_ = intrinsics.syscall(_SYS_tgkill, uintptr(process_pid), uintptr(_raw_gettid()), uintptr(OWNED_SIGCANCEL))
			}
		}
	}
	// Register an embedder-owned entry. The entry must be initialized
	// (STARTING, tid 0 allowed) and must stay valid until unregistered.
	// Hold the birth gate until the cloned child publishes Running.
	// Infallible: pure pointer surgery under a short spinlock hold, with
	// async-cancel deferred across the hold so a terminated holder can
	// never strand the lock.
	_owned_thread_register :: proc "contextless" (entry: ^Owned_Thread_Entry) {
		_owned_cancel_mask_self()
		// Async-signal-safe: a user handler interrupting this take and
		// calling a coordinated setter must not observe it half-held.
		saved := _owned_app_signals_block()
		for intrinsics.atomic_exchange(&registry_lock, 1) != 0 {
		}
		entry.next = registry_head
		registry_head = entry
		intrinsics.atomic_exchange(&registry_lock, 0)
		_owned_app_signals_restore(saved)
		_owned_cancel_unmask_self()
	}

	// Unregister an entry. Idempotent: silently skips entries not listed, so
	// exit paths, cancel handlers, and joiners may all call it defensively.
	_owned_thread_unregister :: proc "contextless" (entry: ^Owned_Thread_Entry) {
		_owned_cancel_mask_self()
		saved := _owned_app_signals_block()
		for intrinsics.atomic_exchange(&registry_lock, 1) != 0 {
		}
		prev: ^Owned_Thread_Entry
		for it := registry_head; it != nil; it = it.next {
			if it == entry {
				if prev == nil {
					registry_head = it.next
				} else {
					prev.next = it.next
				}
				break
			}
			prev = it
		}
		intrinsics.atomic_exchange(&registry_lock, 0)
		_owned_app_signals_restore(saved)
		_owned_cancel_unmask_self()
	}

	// Child side of fork: no sibling thread survives, so keep only the
	// forking thread's own entry and reset the locks a dead sibling may
	// have held (a dead sibling's hold would wedge the child's first registry
	// use; the reset is necessary, not blind, and no handler in the child
	// touches these locks before the reset completes). The forker is
	// identified by its TLS self pointer, never by matching the child's new
	// tid against old entries: after fork the child tid equals no old entry,
	// and a tid scan drops the forker and empties the registry.
	// Non-allocating and async-signal-safe: plain stores only, no walk, no
	// free. The child is a separate process: it legitimately inherits the
	// fork caller's credentials at the fork instant, and the parent's later
	// changes do not propagate. Accordingly the reset DISCARDS the inherited
	// parent request state (seq, kind, args, epoch) instead of re-applying
	// the parent op: the kernel-inherited creds stand as the child's truth,
	// and re-applying would be both unnecessary and wrong across the process
	// boundary. Discarding also closes the real hazard: an inherited odd
	// epoch (fork during the parent's publish) would never close in the
	// child and would stall every future bring-up seqlock read. Stale cancel
	// requests and deferral state do not survive into the child. Heap and
	// temp-allocator state are explicitly not touched here; see the fork
	// documentation.
	_owned_thread_registry_atfork_child :: proc "contextless" () {
		// A handler interrupting the reset and calling a setter must see
		// either the old or the new state, never the half-reset middle.
		saved := _owned_app_signals_block()
		registry_lock = 0
		// No broadcast waiter survives here: the forking thread keeps its
		// own wait loop, so the inherited hold must be released for later
		// broadcasts. Sequence and op state stay monotonic and benign.
		broadcast_lock = 0
		process_pid = _raw_getpid()
		kept := owned_self_entry
		if kept != nil {
			// Establish exactly one deferral hold regardless of inherited
			// depth: the child holds no lock (both were just reset above),
			// but a signal landing mid-reset must defer rather than exit.
			kept.next = nil
			intrinsics.atomic_store(&kept.cancel_mask, 1)
			// Pristine protocol state: zero the inherited request so the
			// child's first broadcast starts from the never-broadcast
			// sentinel exactly like a fresh process.
			broadcast_seq = 0
			broadcast_kind = 0
			broadcast_a = 0
			broadcast_b = 0
			broadcast_c = 0
			broadcast_epoch = 0
			intrinsics.atomic_store(&kept.ack, 0)
			intrinsics.atomic_store(&kept.apply_result, 0)
			intrinsics.atomic_store(&kept.tid, _raw_gettid())
			intrinsics.atomic_store(&kept.cancel_requested, 0)
			intrinsics.atomic_store(&kept.exit_code, 0)
			intrinsics.atomic_store(&kept.cancel_pending, 0)
			intrinsics.atomic_store(&kept.state, u32(Owned_Thread_State.Running))
		}
		registry_head = kept
		owned_self_entry = kept
		_owned_cancel_unmask_self()
		_owned_app_signals_restore(saved)
	}

	// Number of registered entries, including starting threads. Lets callers
	// take the allocation-free single-threaded fast path.
	_owned_thread_count :: proc "contextless" () -> int {
		_owned_cancel_mask_self()
		saved := _owned_app_signals_block()
		for intrinsics.atomic_exchange(&registry_lock, 1) != 0 {
		}
		n := 0
		for it := registry_head; it != nil; it = it.next {
			n += 1
		}
		intrinsics.atomic_exchange(&registry_lock, 0)
		_owned_app_signals_restore(saved)
		_owned_cancel_unmask_self()
		return n
	}

	// Applies one credential op directly. Shared by the signal handler, the
	// child bring-up path, and the fork reset: a leaf over raw syscalls with
	// no state access, so it is async-signal-safe. Returns the _raw_check'd
	// result (0 or negative errno); unknown families apply nothing and
	// return 0 so a skew can never stall a broadcast.
	@(private="file")
	_owned_apply_cred_op :: #force_inline proc "contextless" (kind: u32, a, b, c: i64) -> int {
		switch kind {
		case 1: return _raw_check(int(intrinsics.syscall(_SYS_setuid, uintptr(a))))
		case 2: return _raw_check(int(intrinsics.syscall(_SYS_setgid, uintptr(a))))
		case 3: return _raw_check(int(intrinsics.syscall(_SYS_setresuid, uintptr(a), uintptr(b), uintptr(c))))
		case 4: return _raw_check(int(intrinsics.syscall(_SYS_setresgid, uintptr(a), uintptr(b), uintptr(c))))
		case 5: return _raw_check(int(intrinsics.syscall(_SYS_setreuid, uintptr(a), uintptr(b))))
		case 6: return _raw_check(int(intrinsics.syscall(_SYS_setregid, uintptr(a), uintptr(b))))
		}
		return 0
	}

	// Bounded seqlock read; a failed read leaves the handler's ack stale.
	@(private="file")
	_owned_read_published_op :: proc "contextless" () -> (seq: u64, kind: u32, a, b, c: i64, ok: bool) {
		for _ in 0..<1000 {
			e1 := intrinsics.atomic_load(&broadcast_epoch)
			if (e1 & 1) != 0 {
				continue // publisher mid-publish; retry
			}
			s := intrinsics.atomic_load(&broadcast_seq)
			k := intrinsics.atomic_load(&broadcast_kind)
			x := intrinsics.atomic_load(&broadcast_a)
			y := intrinsics.atomic_load(&broadcast_b)
			z := intrinsics.atomic_load(&broadcast_c)
			e2 := intrinsics.atomic_load(&broadcast_epoch)
			if e1 != e2 {
				continue
			}
			return s, k, x, y, z, true
		}
		return 0, 0, 0, 0, 0, false
	}

	// Creator-held from registration through child Running. Clone inherits
	// current credentials; later broadcasts cannot skip the new thread.
	// No allocation or user callbacks while held. Release on every failure.
	_owned_thread_birth_begin :: proc "contextless" () -> u64 {
		_owned_cancel_mask_self()
		saved := _owned_app_signals_block()
		for intrinsics.atomic_exchange(&broadcast_lock, 1) != 0 {
			_ = intrinsics.syscall(_SYS_sched_yield)
		}
		return saved
	}

	_owned_thread_birth_end :: proc "contextless" (saved: u64) {
		intrinsics.atomic_exchange(&broadcast_lock, 0)
		_owned_cancel_unmask_self()
		_owned_app_signals_restore(saved)
	}

	// The creator holds the birth gate until this procedure publishes
	// Running. The kernel-inherited credentials are already current. The
	// caller restores the intended application-signal mask after return.
	_owned_thread_child_enter :: proc "contextless" (entry: ^Owned_Thread_Entry) {
		self_tid := _raw_gettid()
		intrinsics.atomic_store(&entry.tid, self_tid)
		// TLS bind first: the cancel guard below addresses this entry
		// through the self pointer, and any signal after the unmask must
		// find it.
		owned_self_entry = entry
		// Defer cancellation until protocol identity is initialized. The
		// creator owns the gate; the child never acquires or releases it.
		_owned_cancel_mask_self()
		_ = _owned_app_signals_block()
		intrinsics.atomic_store(&entry.apply_result, 0)
		intrinsics.atomic_store(&entry.ack, intrinsics.atomic_load(&broadcast_seq))
		if protocol_ready {
			// Publish failure before Running so the creator can abort.
			intrinsics.atomic_store(&entry.bringup_error, i32(_owned_unmask_protocol()))
		}
		intrinsics.atomic_store(&entry.state, u32(Owned_Thread_State.Running))
		_owned_cancel_unmask_self()
		if protocol_ready {
			// A cancel armed before the TLS self pointer existed was
			// ignored by the handler (nil entry); replay it here so an
			// armed request can never be lost across birth. Guards are down
			// (gate released, cancel unmasked), so the self signal drives
			// the handler directly; still before user code runs.
			if intrinsics.atomic_load(&entry.cancel_requested) != 0 {
				_ = intrinsics.syscall(_SYS_tgkill, uintptr(process_pid), uintptr(intrinsics.atomic_load(&entry.tid)), uintptr(OWNED_SIGCANCEL))
			}
		}
	}

	// Signal restorer for the protocol handlers: raw rt_sigreturn, which
	// never returns. Plain code address, no context use.
	@(private="file")
	_owned_sig_restorer :: proc "contextless" () {
		intrinsics.syscall(_SYS_rt_sigreturn)
		for {
		}
	}

	// Protocol handler for both reserved signals, installed with SA_SIGINFO.
	// Validates everything before acting: a foreign or stray 32/33 (wrong
	// sender, wrong code, no active request) is ignored. Allocation-free,
	// lock-free on the hot path; the cancel unlink is bounded-try with the
	// join path as backstop. Never returns for cancellation.
	@(private="file")
	_owned_protocol_handler :: proc "c" (sig: i32, info: ^_Kernel_Siginfo, _ctx: rawptr) {
		if info == nil {
			return
		}
		// Only synchronous self-process targeted delivery participates.
		// Anything else, including kill(2) from another process, is ignored.
		// The signo must match the dispatched signal as well: a misdirected
		// or forged siginfo never drives either protocol path. This gate
		// covers the cancel signal (32) exactly like the credential signal
		// (33): matching signo, SI_TKILL code, and sender pid are all
		// required before either path acts.
		if info.signo != sig || info.code != _SI_TKILL || info.pid != process_pid {
			return
		}
		entry := owned_self_entry
		if entry == nil {
			return
		}
		if sig == OWNED_SIGCANCEL {
			// Separate handler state from the credential path: without an
			// authorized pending request this is a stray signal, not an order.
			if intrinsics.atomic_load(&entry.cancel_requested) == 0 {
				return
			}
			// Deferred across runtime critical sections: exiting while
			// holding broadcast_lock or registry_lock would strand the lock
			// for the whole process. Record pending and return; the unmask
			// replays the cancel after the locks are released. Masking is
			// self-set, so a set mask means this thread is inside one now.
			if intrinsics.atomic_load(&entry.cancel_mask) != 0 {
				intrinsics.atomic_store(&entry.cancel_pending, 1)
				return
			}
			// Best-effort unlink with bounded spins; the lock is only ever
			// held for pointer surgery, and the join path unregisters
			// defensively, so giving up here cannot strand the join. The
			// take masks application signals like every other registry
			// take: a nested user handler calling a setter must not observe
			// it half-held (nested 32 still reaches us and exits via the
			// bounded give-up path, never a deadlock).
			saved := _owned_app_signals_block()
			for _ in 0..<100000 {
				if intrinsics.atomic_exchange(&registry_lock, 1) == 0 {
					prev: ^Owned_Thread_Entry
					for it := registry_head; it != nil; it = it.next {
						if it == entry {
							if prev == nil {
								registry_head = it.next
							} else {
								prev.next = it.next
							}
							break
						}
						prev = it
					}
					intrinsics.atomic_exchange(&registry_lock, 0)
					break
				}
			}
			_owned_app_signals_restore(saved)
			// End only this thread. No cleaners, locks, or memory run on the
			// way out; the kernel clears the clear-tid word and wakes the
			// joiner. Matches the documented terminate contract.
			intrinsics.syscall(_SYS_exit, uintptr(intrinsics.atomic_load(&entry.exit_code)))
			for {
			}
		} else if sig == OWNED_SIGSETXID {
			cur := intrinsics.atomic_load(&broadcast_seq)
			if cur == 0 || intrinsics.atomic_load(&entry.ack) == cur {
				return // stale or duplicate delivery
			}
			// A delayed duplicate for an older op converges forward: ops
			// are absolute, so applying the latest published op is always
			// correct, and the op already applied stays applied. A read
			// that races publication for the whole window leaves the ack
			// stale; the broadcaster then ends the process (fail-closed)
			// rather than recording a false ack.
			seq, kind, a, b, c, ok := _owned_read_published_op()
			if !ok || seq == 0 {
				return
			}
			res := _owned_apply_cred_op(kind, a, b, c)
			// Stored before ack (all entry accesses are sequentially
			// consistent): any observer that sees the ack match also sees
			// this result. A nonzero result fails the broadcast even though
			// the ack matches, so failed applies can never hide behind a 0
			// return with divergent privileges.
			intrinsics.atomic_store(&entry.apply_result, i32(res))
			intrinsics.atomic_store(&entry.ack, seq)
		}
	}

	// Installs both protocol handlers before unmasking either signal and
	// before any constructor runs. Never unmasks a reserved signal with its
	// default disposition (terminate). 0 on success, negative kernel errno.
	// The caller terminates startup with a diagnostic on failure.
	_owned_credentials_init :: proc "contextless" () -> int {
		h: _Kernel_Sigaction
		h.handler = rawptr(_owned_protocol_handler)
		h.flags = _SA_SIGINFO | _SA_RESTORER
		h.restorer = rawptr(_owned_sig_restorer)
		h.mask = 0
		if r := _raw_check(int(intrinsics.syscall(_SYS_rt_sigaction, uintptr(OWNED_SIGCANCEL), uintptr(rawptr(&h)), 0, 8))); r != 0 {
			return r
		}
		if r := _raw_check(int(intrinsics.syscall(_SYS_rt_sigaction, uintptr(OWNED_SIGSETXID), uintptr(rawptr(&h)), 0, 8))); r != 0 {
			return r
		}
		// Single typed leaf: the full 4-argument unmask with sigsetsize 8.
		if r := _owned_unmask_protocol(); r != 0 {
			return r
		}
		protocol_ready = true
		return 0
	}

	// Synchronous process-wide update. A caller failure leaves publication
	// unchanged; failure to converge after mutation terminates the process.
	// Allocation-free, with application signals and async cancellation deferred.
	_owned_credentials_broadcast :: proc "contextless" (kind: u32, a, b, c: i64) -> int {
		if kind < 1 || kind > 6 {
			return -22 // EINVAL: validated before any mutation is possible
		}
		saved_bcast := _owned_app_signals_block()
		defer _owned_app_signals_restore(saved_bcast)
		_owned_cancel_mask_self()
		defer _owned_cancel_unmask_self()
		for intrinsics.atomic_exchange(&broadcast_lock, 1) != 0 {
			_ = intrinsics.syscall(_SYS_sched_yield)
		}
		defer intrinsics.atomic_exchange(&broadcast_lock, 0)

		// Count under the birth gate, not before acquiring it: a creator
		// may have finished while we waited. Registration and clone hold
		// this same gate until the child is Running.
		cap := 0
		for intrinsics.atomic_exchange(&registry_lock, 1) != 0 {
		}
		for it := registry_head; it != nil; it = it.next {
			cap += 1
		}
		intrinsics.atomic_exchange(&registry_lock, 0)
		if cap > 1 && !protocol_ready {
			return -22 // EINVAL: no handler installed, no mutation yet
		}

		// Keep readers out while applying the caller. A failed syscall
		// closes the epoch without changing the last committed operation.
		intrinsics.atomic_store(&broadcast_epoch, intrinsics.atomic_load(&broadcast_epoch) + 1)
		if self_res := _owned_apply_cred_op(kind, a, b, c); self_res != 0 {
			intrinsics.atomic_store(&broadcast_epoch, intrinsics.atomic_load(&broadcast_epoch) + 1)
			return self_res
		}
		intrinsics.atomic_store(&broadcast_kind, kind)
		intrinsics.atomic_store(&broadcast_a, a)
		intrinsics.atomic_store(&broadcast_b, b)
		intrinsics.atomic_store(&broadcast_c, c)
		seq := intrinsics.atomic_add(&broadcast_seq, 1) + 1
		if entry := owned_self_entry; entry != nil {
			intrinsics.atomic_store(&entry.apply_result, 0)
			intrinsics.atomic_store(&entry.ack, seq)
		}
		intrinsics.atomic_store(&broadcast_epoch, intrinsics.atomic_load(&broadcast_epoch) + 1)
		if cap <= 1 {
			return 0
		}
		self := _raw_gettid()

		deadline := _owned_monotonic_ns() + 2_000_000_000

		first_err := 0
		for _ in 0..<4 {
			// Signal sweep under one short signal-masked take: deliver to
			// every running other that still needs the op. Membership pins
			// lifetime — a found-in-list entry cannot be freed mid-sweep,
			// because freeing strictly follows removal under this same
			// lock — so no heap snapshot is needed to name targets safely.
			// Entries whose ack matches but whose apply failed are NOT
			// re-signalled (deterministic ops do not heal by retry); they
			// fail at the final check instead.
			saved := _owned_app_signals_block()
			for intrinsics.atomic_exchange(&registry_lock, 1) != 0 {
			}
			need := 0
			for it := registry_head; it != nil; it = it.next {
				tid := intrinsics.atomic_load(&it.tid)
				st := intrinsics.atomic_load(&it.state)
				ak := intrinsics.atomic_load(&it.ack)
				if tid > 0 && tid != self && st == u32(Owned_Thread_State.Running) && ak != seq {
					// Group-scoped delivery: the (tgid, tid) pair cannot
					// resolve into an unrelated process on tid reuse, where
					// the default disposition would terminate it. Sender and
					// request validation protects our receivers; the group
					// scope protects everyone else.
					r := _raw_check(int(intrinsics.syscall(_SYS_tgkill, uintptr(process_pid), uintptr(tid), uintptr(OWNED_SIGSETXID))))
					if r != 0 && r != -3 /* ESRCH */ && first_err == 0 {
						first_err = r
					}
					need += 1
				}
			}
			intrinsics.atomic_exchange(&registry_lock, 0)
			_owned_app_signals_restore(saved)
			if need == 0 {
				break
			}
			// Settle wait: fresh masked scans, never a snapshot that could
			// go stale under birth/exit churn. Done means ack matches AND
			// the recorded apply result is 0. Rounds with only bad results
			// left (nothing still unacked) stop early: no ack can fix a
			// failed apply, and the final sweep reports it.
			for {
				pending := 0
				unacked := 0
				saved_wait := _owned_app_signals_block()
				for intrinsics.atomic_exchange(&registry_lock, 1) != 0 {
				}
				for it := registry_head; it != nil; it = it.next {
					tid := intrinsics.atomic_load(&it.tid)
					st := intrinsics.atomic_load(&it.state)
					if tid > 0 && tid != self && st == u32(Owned_Thread_State.Running) {
						ak := intrinsics.atomic_load(&it.ack)
						if ak != seq {
							pending += 1
							unacked += 1
						} else if intrinsics.atomic_load(&it.apply_result) != 0 {
							pending += 1
						}
					}
				}
				intrinsics.atomic_exchange(&registry_lock, 0)
				_owned_app_signals_restore(saved_wait)
				if pending == 0 || unacked == 0 {
					break
				}
				_ = intrinsics.syscall(_SYS_sched_yield)
				if _owned_monotonic_ns() >= deadline {
					break
				}
			}
		}
		// Final convergence sweep under a single lock hold, so membership
		// is stable and no racing join can free an entry mid-sweep. The
		// tkill probes use signo 0 (existence only, nothing delivered) and
		// are nonblocking; cancel is deferred across the hold, and the 32
		// handler's unlink is bounded-try, so the hold cannot deadlock
		// either way. A registered entry whose tid is verifiably dead (a
		// thread lost to a fatal signal never unregisters) carries no
		// credentials and counts as done. A recycled tid that answers reads
		// as live (fail-closed). The ack is re-read after each probe so a
		// late ack landing mid-sweep still counts.
		saved_final := _owned_app_signals_block()
		for intrinsics.atomic_exchange(&registry_lock, 1) != 0 {
		}
		stragglers := 0
		bad_result := 0
		for it := registry_head; it != nil; it = it.next {
			tid := intrinsics.atomic_load(&it.tid)
			st := intrinsics.atomic_load(&it.state)
			if tid > 0 && tid != self && st == u32(Owned_Thread_State.Running) {
				ak := intrinsics.atomic_load(&it.ack)
				if ak != seq {
					// Membership is stable under this hold, so the probe
					// and the re-read below cannot race a free.
					probe := _raw_check(int(intrinsics.syscall(_SYS_tgkill, uintptr(process_pid), uintptr(tid), 0)))
					if probe == -3 /* ESRCH */ {
						continue // dead tid carries nothing: done
					}
					ak = intrinsics.atomic_load(&it.ack)
					if ak != seq {
						stragglers += 1
					} else if r := intrinsics.atomic_load(&it.apply_result); r != 0 && bad_result == 0 {
						bad_result = int(r)
					}
				} else if r := intrinsics.atomic_load(&it.apply_result); r != 0 && bad_result == 0 {
					bad_result = int(r)
				}
			}
		}
		intrinsics.atomic_exchange(&registry_lock, 0)
		_owned_app_signals_restore(saved_final)
		// Past publication every failure ends the process: mutation was
		// possible and rollback is not. first_err with no stragglers and no
		// bad results is the proven-consistent case (every live thread
		// applied with result 0), so it returns ordinarily: recorded, not
		// discarded, and nothing diverged.
		if stragglers > 0 {
			_owned_fatal_diverged(-110)
		}
		if bad_result != 0 {
			_owned_fatal_diverged(bad_result)
		}
		return first_err
	}

	// Monotonic clock in nanoseconds for broadcast deadlines. The raw call
	// cannot fail on Linux; a zero reading only shortens a deadline.
	@(private="file")
	_owned_monotonic_ns :: proc "contextless" () -> i64 {
		now: _Kernel_Timespec
		_ = intrinsics.syscall(_SYS_clock_gettime, _SYS_CLOCK_MONOTONIC, uintptr(rawptr(&now)))
		return now.sec * 1_000_000_000 + now.nsec
	}
}
