#+build linux
package tests_nbio

import "core:nbio"
import "core:net"
import "core:sys/linux"
import "core:testing"
import "core:time"

// A spawned child inherits every descriptor which is not close-on-exec, so an
// accepted connection must not outlive an exec into a tool the program starts.
@(test)
accepted_sockets_are_close_on_exec :: proc(t: ^testing.T) {
	if event_loop_guard(t) {
		testing.set_fail_timeout(t, time.Minute)

		is_cloexec :: proc(fd: int) -> bool {
			flags, errno := linux.fcntl_getfd(linux.Fd(fd), linux.F_GETFD)
			return errno == nil && int(flags) & 1 != 0
		}

		server, ep := open_next_available_local_port(t)

		// The accept of `core:net`.
		{
			client, dial_err := net.dial_tcp(ep)
			ev(t, dial_err, nil)

			accepted, _, accept_err := net.accept_tcp(server)
			ev(t, accept_err, nil)
			testing.expect(t, is_cloexec(int(accepted)), "net.accept_tcp returned a socket without close-on-exec")

			net.close(accepted)
			net.close(client)
		}

		// The accept of `core:nbio`.
		{
			client, dial_err := net.dial_tcp(ep)
			ev(t, dial_err, nil)

			nbio.accept_poly(server, t, proc(op: ^nbio.Operation, t: ^testing.T) {
				ev(t, op.accept.err, nil)
				testing.expect(t, is_cloexec(int(op.accept.client)), "nbio.accept returned a socket without close-on-exec")
				net.close(op.accept.client)
			})

			ev(t, nbio.run(), nil)
			net.close(client)
		}

		nbio.close(server)
	}
}
