#+build linux
#+private
package testing

import "base:intrinsics"
import "core:sync"
import "core:sys/linux"
import "core:terminal/ansi"

_ :: intrinsics
_ :: sync
_ :: linux
_ :: ansi

// Without the CRT there is no libc `signal`, `pthread_cancel` or `abort`, so
// this backend installs its handlers with `rt_sigaction` and ends a faulting
// test thread by itself.
//
// A test thread that catches a fatal signal records it for the runner, then
// ends its own thread with the raw exit syscall. Unlike `pthread_cancel` on
// the CRT path, nothing runs on the way out: locks the test held and memory it
// allocated are abandoned, and thread-local cleaners do not run.
when ODIN_NO_CRT {

	@(private="file") stop_runner_flag: i32

	@(private="file") stop_test_gate:   sync.Mutex
	@(private="file") stop_test_index:  i32
	@(private="file") stop_test_signal: i32
	@(private="file") stop_test_passed: i32
	@(private="file") stop_test_alert:  i32

	@(private="file", thread_local)
	local_test_index: i32
	@(private="file", thread_local)
	local_test_index_set: bool

	@(private="file")
	write_stderr :: proc "contextless" (s: string) {
		linux.write(linux.STDERR_FILENO, transmute([]u8)s)
	}

	@(private="file")
	stop_runner_callback :: proc "c" (sig: linux.Signal) {
		prev := intrinsics.atomic_add(&stop_runner_flag, 1)

		// If the flag was already set (if this is the second signal sent for example),
		// consider this a forced (not graceful) exit.
		if prev > 0 {
			linux.exit_group(i32(sig))
		}
	}

	@(private="file")
	stop_test_callback :: proc "c" (sig: linux.Signal) {
		if !local_test_index_set {
			// We're a thread created by a test thread.
			//
			// There's nothing we can do to inform the test runner about who
			// signalled, so hopefully the test will handle their own sub-threads.
			return
		}
		if local_test_index == -1 {
			// We're the test runner, and we ourselves have caught a signal from
			// which there is no recovery.
			//
			// The most we can do now is make sure the user's cursor is visible,
			// nuke the entire processs, and hope a useful core dump survives.
			if !global_ansi_disabled {
				write_stderr(ansi.CSI + ansi.DECTCEM_SHOW)
			}

			sigbuf: [8]byte
			sigstr: string
			{
				signum := int(sig)
				i := len(sigbuf) - 2
				for signum > 0 {
					m := signum % 10
					signum /= 10
					sigbuf[i] = cast(u8)('0' + m)
					i -= 1
				}
				sigstr = string(sigbuf[1 + i:len(sigbuf) - 1])
			}

			write_stderr(`
The test runner's main thread has caught an unrecoverable error (signal `)
			write_stderr(sigstr)
			write_stderr(`) and will now forcibly terminate.
Unless you terminated the tests yourself, this could be a dire bug and should be reported to the Odin developers.
`)

			// Try to get a core dump, as `abort` does.
			action := linux.Sig_Action{special = .SIG_DFL}
			linux.rt_sigaction(.SIGABRT, &action, nil)
			linux.tgkill(linux.getpid(), linux.gettid(), .SIGABRT)
			linux.exit_group(128 + i32(linux.Signal.SIGABRT))
		}

		if sync.mutex_guard(&stop_test_gate) {
			intrinsics.atomic_store(&stop_test_index, local_test_index)
			intrinsics.atomic_store(&stop_test_signal, i32(sig))
			passed: bool
			check_passing: {
				if location := local_test_assertion_raised.location; location != {} {
					for i in 0..<local_test_expected_failures.location_count {
						if local_test_expected_failures.locations[i] == location {
							passed = true
							break check_passing
						}
					}
				}
				if message := local_test_assertion_raised.message; message != "" {
					for i in 0..<local_test_expected_failures.message_count {
						if local_test_expected_failures.messages[i] == message {
							passed = true
							break check_passing
						}
					}
				}
				if signal := local_test_expected_failures.signal; signal == i32(sig) {
					passed = true
				}
			}
			intrinsics.atomic_store(&stop_test_passed, i32(passed))
			intrinsics.atomic_store(&stop_test_alert, 1)

			// End only this thread. The runner waits for the kernel to finish the
			// exit in `thread.pool_stop_task`, and releases the gate afterwards.
			// The faulting instruction cannot be resumed, so never return.
			linux.exit(0)
		}
	}

	@(private="file")
	install_signal_handler :: proc(sig: linux.Signal, handler: linux.Sig_Handler_Fn) {
		action := linux.Sig_Action{handler = handler, flags = {.RESTART}}
		if handler == stop_test_callback {
			// A different fatal signal must not reenter while this thread holds
			// stop_test_gate. The callback exits without restoring this mask.
			for fatal in ([4]linux.Signal{.SIGILL, .SIGFPE, .SIGSEGV, .SIGTRAP}) {
				action.mask[0] |= uint(1) << (uint(fatal) - 1)
			}
		}
		// The kernel's riscv64 sigaction has no restorer and always returns through
		// the vDSO; every other supported architecture takes `rt_sigreturn` from
		// `rt_sigaction`.
		when ODIN_ARCH != .riscv64 {
			action.flags += {.RESTORER}
		}
		err := linux.rt_sigaction(sig, &action, nil)
		assert(err == .NONE, "Unable to install the test signal handler.")
	}

	_setup_signal_handler :: proc() {
		local_test_index = -1
		local_test_index_set = true

		// Catch user interrupt / CTRL-C.
		install_signal_handler(.SIGINT, stop_runner_callback)
		// Catch polite termination request.
		install_signal_handler(.SIGTERM, stop_runner_callback)

		// For tests:
		// Catch asserts and panics.
		install_signal_handler(.SIGILL, stop_test_callback)
		// Catch arithmetic errors.
		install_signal_handler(.SIGFPE, stop_test_callback)
		// Catch segmentation faults (illegal memory access).
		install_signal_handler(.SIGSEGV, stop_test_callback)
		// Catch breakpoint and trap instructions, which is how `runtime.trap` ends
		// on arm64 and riscv64.
		install_signal_handler(.SIGTRAP, stop_test_callback)
	}

	_setup_task_signal_handler :: proc(test_index: int) {
		local_test_index = i32(test_index)
		local_test_index_set = true
	}

	_should_stop_runner :: proc() -> bool {
		return intrinsics.atomic_load(&stop_runner_flag) == 1
	}

	@(private="file")
	unlock_stop_test_gate :: proc(_: int, _: Stop_Reason, ok: bool) {
		if ok {
			sync.mutex_unlock(&stop_test_gate)
		}
	}

	@(deferred_out=unlock_stop_test_gate)
	_should_stop_test :: proc() -> (test_index: int, reason: Stop_Reason, ok: bool) {
		if intrinsics.atomic_load(&stop_test_alert) == 1 {
			intrinsics.atomic_store(&stop_test_alert, 0)

			test_index = int(intrinsics.atomic_load(&stop_test_index))
			if intrinsics.atomic_load(&stop_test_passed) != 0 {
				reason = .Successful_Stop
			} else {
				#partial switch linux.Signal(intrinsics.atomic_load(&stop_test_signal)) {
				case .SIGFPE:  reason = .Arithmetic_Error
				case .SIGILL:  reason = .Illegal_Instruction
				case .SIGSEGV: reason = .Segmentation_Fault
				case .SIGTRAP: reason = .Unhandled_Trap
				}
			}
			ok = true
		}

		return
	}
}
