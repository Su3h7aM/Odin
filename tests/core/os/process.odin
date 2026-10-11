#+build !windows
package tests_core_os

import "core:os"
import "core:log"
import "core:testing"

@(test)
test_process_exec :: proc(t: ^testing.T) {
	state, stdout, stderr, err := os.process_exec({
		command = {"echo", "hellope"},
	}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)

	if err == .Unsupported {
		log.warn("process_exec unsupported")
		return
	}

	testing.expect_value(t, state.exited,  true)
	testing.expect_value(t, state.success, true)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, string(stdout), "hellope\n")
	testing.expect_value(t, string(stderr), "")
}

@(test)
test_process_kill_without_process :: proc(t: ^testing.T) {
	// A zero Process has pid 0, which `kill` would take as the caller's own process group.
	testing.expect(t, os.process_kill(os.Process{}) != nil, "killing a zero Process must fail")
	testing.expect(t, os.process_terminate(os.Process{}) != nil, "terminating a zero Process must fail")
}

@(test)
test_process_kill_group :: proc(t: ^testing.T) {
	// The shell leaves a `sleep` behind in the group when it is killed on its own.
	process, err := os.process_start({
		command   = {"sh", "-c", "sleep 30 & wait"},
		new_group = true,
	})
	if err == .Unsupported {
		log.warn("process_start unsupported")
		return
	}
	testing.expect_value(t, err, nil)

	testing.expect_value(t, os.process_kill_group(process), nil)

	state, wait_err := os.process_wait(process)
	testing.expect_value(t, wait_err, nil)
	testing.expect_value(t, state.exited,  true)
	testing.expect_value(t, state.success, false)

	// Without `new_group` the child is in our group, so no group has its pid.
	process, err = os.process_start({command = {"sleep", "30"}})
	testing.expect_value(t, err, nil)
	testing.expect(t, os.process_kill_group(process) != nil, "no group should have the pid of a child that did not lead one")

	testing.expect_value(t, os.process_kill(process), nil)
	_, wait_err = os.process_wait(process)
	testing.expect_value(t, wait_err, nil)
}
