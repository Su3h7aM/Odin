#+build linux
package tests_nbio

import "core:nbio"
import "core:net"
import "core:os"
import "core:testing"
import "core:time"

@(private="file")
open_descriptors :: proc() -> (count: int) {
	// The tests share one descriptor table and run in parallel, so an entry can
	// close while the directory is being read. Read it again when that happens.
	for _ in 0 ..< 100 {
		infos, err := os.read_directory_by_path("/proc/self/fd", -1, context.allocator)
		if err == nil {
			count = len(infos)
			os.file_info_slice_delete(infos, context.allocator)
			return
		}
	}
	return -1
}

// Every sendfile makes a pipe to move the data through, and both ends of it
// have to be closed once the operation is done.
@(test)
sendfile_closes_its_pipe :: proc(t: ^testing.T) {
	if event_loop_guard(t) {
		testing.set_fail_timeout(t, time.Minute)

		CONTENT :: #load(#file)

		round :: proc(t: ^testing.T) {
			sock, ep := open_next_available_local_port(t)

			nbio.accept_poly(sock, t, proc(op: ^nbio.Operation, t: ^testing.T) {
				ev(t, op.accept.err, nil)
				nbio.open_poly3(#file, t, op.accept.socket, op.accept.client, proc(op: ^nbio.Operation, t: ^testing.T, server, client: net.TCP_Socket) {
					ev(t, op.open.err, nil)
					nbio.sendfile_poly2(client, op.open.handle, t, server, proc(op: ^nbio.Operation, t: ^testing.T, server: net.TCP_Socket) {
						ev(t, op.sendfile.err, nil)
						ev(t, op.sendfile.sent, len(CONTENT))
						nbio.close(op.sendfile.file)
						nbio.close(op.sendfile.socket)
						nbio.close(server) // The listening socket.
					})
				})
			})

			nbio.dial_poly(ep, t, proc(op: ^nbio.Operation, t: ^testing.T) {
				ev(t, op.dial.err, nil)
				buf := make([]byte, len(CONTENT), context.temp_allocator)
				nbio.recv_poly(op.dial.socket, {buf}, t, proc(op: ^nbio.Operation, t: ^testing.T) {
					ev(t, op.recv.err, nil)
					nbio.close(op.recv.socket.(net.TCP_Socket))
				}, all = true)
			})

			ev(t, nbio.run(), nil)
		}

		// The first round sets up whatever the loop keeps for good.
		round(t)

		ROUNDS :: 64

		before := open_descriptors()
		for _ in 0 ..< ROUNDS {
			round(t)
		}
		after := open_descriptors()

		// A leaked pipe end adds one descriptor per sendfile, so ROUNDS leaks grow
		// the count by at least ROUNDS. The lower threshold leaves room for bounded
		// descriptor churn from other tests running in parallel.
		testing.expectf(t, before >= 0 && after - before < ROUNDS, "descriptors grew from %v to %v over %v sendfiles", before, after, ROUNDS)
	}
}
