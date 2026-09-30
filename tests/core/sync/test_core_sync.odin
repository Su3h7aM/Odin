// NOTE(Feoramund): These tests should be run a few hundred times, with and
// without `-sanitize:thread` enabled, to ensure maximum safety.
//
// Keep in mind that running with the debug logs uncommented can result in
// failures disappearing due to the delay of sending the log message causing
// different synchronization patterns.

package test_core_sync

import "base:intrinsics"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

FAIL_TIME        :: 1 * time.Second
SLEEP_TIME       :: 1 * time.Millisecond
SMALL_SLEEP_TIME :: 10 * time.Microsecond

// This needs to be high enough to cause a data race if any of the
// synchronization primitives fail.
THREADS :: 8

// Manually wait on all threads to finish.
//
// This reduces a dependency on a `Wait_Group` or similar primitives.
//
// It's also important that we wait for every thread to finish, as it's
// possible for a thread to finish after the test if we don't check, despite
// joining it to the test thread.
wait_for :: proc(threads: []^thread.Thread) {
	wait_loop: for {
		count := len(threads)
		for v in threads {
			if thread.is_done(v) {
				count -= 1
			}
		}
		if count == 0 {
			break wait_loop
		}
		thread.yield()
	}
	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}
}

//
// core:sync/primitives.odin
//

@test
test_mutex :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, FAIL_TIME)

	Data :: struct {
		m: sync.Mutex,
		number: int,
	}

	p :: proc(th: ^thread.Thread) {
		data := cast(^Data)th.data

		// log.debugf("MUTEX-%v> locking", th.id)
		sync.mutex_lock(&data.m)
		data.number += 1
		// log.debugf("MUTEX-%v> unlocking", th.id)
		sync.mutex_unlock(&data.m)
		// log.debugf("MUTEX-%v> leaving", th.id)
	}

	data: Data
	threads: [THREADS]^thread.Thread

	for &v in threads {
		v = thread.create(p)
		v.data = &data
		v.init_context = context
		thread.start(v)
	}

	wait_for(threads[:])

	testing.expect_value(t, data.number, THREADS)
}

@test
test_rw_mutex :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, FAIL_TIME)

	Data :: struct {
		m1: sync.RW_Mutex,
		m2: sync.RW_Mutex,
		number1: int,
		number2: int,
	}

	p :: proc(th: ^thread.Thread) {
		data := cast(^Data)th.data

		sync.rw_mutex_shared_lock(&data.m1)
		n := data.number1
		sync.rw_mutex_shared_unlock(&data.m1)

		sync.rw_mutex_lock(&data.m2)
		data.number2 += n
		sync.rw_mutex_unlock(&data.m2)
	}

	data: Data
	threads: [THREADS]^thread.Thread

	sync.rw_mutex_lock(&data.m1)

	for &v in threads {
		v = thread.create(p)
		v.data = &data
		v.init_context = context
		thread.start(v)
	}

	data.number1 = 1
	sync.rw_mutex_unlock(&data.m1)

	wait_for(threads[:])

	testing.expect_value(t, data.number2, THREADS)
}

// A thread which holds an Atomic_Recursive_Mutex can take it again with
// try_lock, each level needs its own unlock, and the lock is free afterwards.
@test
test_atomic_recursive_mutex_try_lock :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, FAIL_TIME)

	Data :: struct {
		m: sync.Atomic_Recursive_Mutex,
		other_thread_acquired: bool,
	}
	data: Data
	m := &data.m

	testing.expect(t, sync.atomic_recursive_mutex_try_lock(m), "first try_lock should succeed")
	testing.expect(t, sync.atomic_recursive_mutex_try_lock(m), "try_lock by the owner should succeed")
	sync.atomic_recursive_mutex_lock(m)
	testing.expect_value(t, m.recursion, 3)

	sync.atomic_recursive_mutex_unlock(m)
	sync.atomic_recursive_mutex_unlock(m)

	// One level is still held, so another thread must not get the lock.
	th := thread.create_and_start_with_data(&data, proc(p: rawptr) {
		data := cast(^Data)p
		if sync.atomic_recursive_mutex_try_lock(&data.m) {
			data.other_thread_acquired = true
			sync.atomic_recursive_mutex_unlock(&data.m)
		}
	})
	wait_for([]^thread.Thread{ th })
	testing.expect(t, !data.other_thread_acquired, "another thread took a held Atomic_Recursive_Mutex")

	sync.atomic_recursive_mutex_unlock(m)
	testing.expect_value(t, m.recursion, 0)
	testing.expect(t, sync.atomic_recursive_mutex_try_lock(m), "the lock should be free after the last unlock")
	sync.atomic_recursive_mutex_unlock(m)
}

@test
test_recursive_mutex_try_lock :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, FAIL_TIME)

	m: sync.Recursive_Mutex
	testing.expect(t, sync.recursive_mutex_try_lock(&m), "first try_lock should succeed")
	testing.expect(t, sync.recursive_mutex_try_lock(&m), "try_lock by the owner should succeed")
	sync.recursive_mutex_unlock(&m)
	sync.recursive_mutex_unlock(&m)
	testing.expect(t, sync.recursive_mutex_try_lock(&m), "the lock should be free after the last unlock")
	sync.recursive_mutex_unlock(&m)
}

@test
test_recursive_mutex :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, FAIL_TIME)

	Data :: struct {
		m: sync.Recursive_Mutex,
		number: int,
	}

	p :: proc(th: ^thread.Thread) {
		data := cast(^Data)th.data

		// log.debugf("REC_MUTEX-%v> locking", th.id)
		tried1 := sync.recursive_mutex_try_lock(&data.m)
		for _ in 0..<3 {
			sync.recursive_mutex_lock(&data.m)
		}
		tried2 := sync.recursive_mutex_try_lock(&data.m)
		// log.debugf("REC_MUTEX-%v> locked", th.id)
		data.number += 1
		// log.debugf("REC_MUTEX-%v> unlocking", th.id)
		for _ in 0..<3 {
			sync.recursive_mutex_unlock(&data.m)
		}
		if tried1 { sync.recursive_mutex_unlock(&data.m) }
		if tried2 { sync.recursive_mutex_unlock(&data.m) }
		// log.debugf("REC_MUTEX-%v> leaving", th.id)
	}

	data: Data
	threads: [THREADS]^thread.Thread

	for &v in threads {
		v = thread.create(p)
		v.data = &data
		v.init_context = context
		thread.start(v)
	}

	wait_for(threads[:])

	testing.expect_value(t, data.number, THREADS)
}

@test
test_cond :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, FAIL_TIME)

	Data :: struct {
		c: sync.Cond,
		m: sync.Mutex,
		i: int,
		number: int,
	}

	p :: proc(th: ^thread.Thread) {
		data := cast(^Data)th.data

		sync.mutex_lock(&data.m)

		for intrinsics.atomic_load(&data.i) != 1 {
			sync.cond_wait(&data.c, &data.m)
		}

		data.number += intrinsics.atomic_load(&data.i)

		sync.mutex_unlock(&data.m)
	}

	data: Data
	threads: [THREADS]^thread.Thread
	data.i = -1

	sync.mutex_lock(&data.m)

	for &v in threads {
		v = thread.create(p)
		v.data = &data
		v.init_context = context
		thread.start(v)
	}

	time.sleep(SLEEP_TIME)
	data.i = 1
	sync.mutex_unlock(&data.m)
	sync.cond_broadcast(&data.c)

	wait_for(threads[:])

	testing.expect_value(t, data.number, THREADS)
}

@test
test_cond_with_timeout :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, FAIL_TIME)

	c: sync.Cond
	m: sync.Mutex
	sync.mutex_lock(&m)
	sync.cond_wait_with_timeout(&c, &m, SLEEP_TIME)
}

@test
test_semaphore :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, FAIL_TIME)

	Data :: struct {
		s: sync.Sema,
		number: int,
	}

	p :: proc(th: ^thread.Thread) {
		data := cast(^Data)th.data

		// log.debugf("SEM-%v> waiting", th.id)
		sync.sema_wait(&data.s)
		data.number += 1
		// log.debugf("SEM-%v> posting", th.id)
		sync.sema_post(&data.s)
		// log.debugf("SEM-%v> leaving", th.id)
	}

	data: Data
	threads: [THREADS]^thread.Thread

	for &v in threads {
		v = thread.create(p)
		v.data = &data
		v.init_context = context
		thread.start(v)
	}
	sync.sema_post(&data.s)

	wait_for(threads[:])

	testing.expect_value(t, data.number, THREADS)
}

@test
test_semaphore_with_timeout :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, FAIL_TIME)

	s: sync.Sema
	sync.sema_wait_with_timeout(&s, SLEEP_TIME)
}

@test
test_futex :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, FAIL_TIME)

	Data :: struct {
		f: sync.Futex,
		i: int,
		number: int,
	}

	p :: proc(th: ^thread.Thread) {
		data := cast(^Data)th.data

		// log.debugf("FUTEX-%v> waiting", th.id)
		sync.futex_wait(&data.f, 3)
		// log.debugf("FUTEX-%v> done", th.id)

		n := data.i
		intrinsics.atomic_add(&data.number, n)
	}

	data: Data
	data.i = -1
	data.f = 3
	threads: [THREADS]^thread.Thread

	for &v in threads {
		v = thread.create(p)
		v.data = &data
		v.init_context = context
		thread.start(v)
	}

	data.i = 1
	// Change the futex variable to keep late-starters from stalling.
	data.f = 0
	sync.futex_broadcast(&data.f)

	wait_for(threads[:])

	testing.expect_value(t, data.number, THREADS)
}

@test
test_futex_with_timeout :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, FAIL_TIME)

	f: sync.Futex = 1
	sync.futex_wait_with_timeout(&f, 1, SLEEP_TIME)
}

//
// core:sync/extended.odin
//

@test
test_wait_group :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, FAIL_TIME)

	Data :: struct {
		step1: sync.Wait_Group,
		step2: sync.Wait_Group,
		i: int,
		number: int,
	}

	p :: proc(th: ^thread.Thread) {
		data := cast(^Data)th.data

		sync.wait_group_wait(&data.step1)

		n := data.i
		intrinsics.atomic_add(&data.number, n)

		sync.wait_group_done(&data.step2)
	}

	data: Data
	data.i = -1
	threads: [THREADS]^thread.Thread

	sync.wait_group_add(&data.step1, 1)
	sync.wait_group_add(&data.step2, THREADS)

	for &v in threads {
		v = thread.create(p)
		v.data = &data
		v.init_context = context
		thread.start(v)
	}

	time.sleep(SMALL_SLEEP_TIME)
	data.i = 1
	sync.wait_group_done(&data.step1)

	sync.wait_group_wait(&data.step2)

	wait_for(threads[:])

	testing.expect_value(t, data.step1.counter, 0)
	testing.expect_value(t, data.step2.counter, 0)
	testing.expect_value(t, data.number, THREADS)
}

@test
test_wait_group_with_timeout :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, FAIL_TIME)

	wg: sync.Wait_Group
	sync.wait_group_wait_with_timeout(&wg, SLEEP_TIME)
}

@test
test_barrier :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, FAIL_TIME)

	Data :: struct {
		b: sync.Barrier,
		i: int,
		number: int,

	}

	p :: proc(th: ^thread.Thread) {
		data := cast(^Data)th.data

		sync.barrier_wait(&data.b)

		intrinsics.atomic_add(&data.number, data.i)
	}

	data: Data
	data.i = -1
	threads: [THREADS]^thread.Thread

	sync.barrier_init(&data.b, THREADS + 1) // +1 for this thread, of course.

	for &v in threads {
		v = thread.create(p)
		v.data = &data
		v.init_context = context
		thread.start(v)
	}
	time.sleep(SMALL_SLEEP_TIME)
	data.i = 1
	sync.barrier_wait(&data.b)

	wait_for(threads[:])

	testing.expect_value(t, data.b.index, 0)
	testing.expect_value(t, data.b.generation_id, 1)
	testing.expect_value(t, data.b.thread_count, THREADS + 1)
	testing.expect_value(t, data.number, THREADS)
}

@test
test_auto_reset :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, FAIL_TIME)

	Data :: struct {
		a: sync.Auto_Reset_Event,
		number: int,
	}

	p :: proc(th: ^thread.Thread) {
		data := cast(^Data)th.data

		// log.debugf("AUR-%v> entering", th.id)
		sync.auto_reset_event_wait(&data.a)
		// log.debugf("AUR-%v> adding", th.id)
		data.number += 1
		// log.debugf("AUR-%v> signalling", th.id)
		sync.auto_reset_event_signal(&data.a)
		// log.debugf("AUR-%v> leaving", th.id)
	}

	data: Data
	threads: [THREADS]^thread.Thread

	for &v in threads {
		v = thread.create(p)
		v.data = &data
		v.init_context = context
		thread.start(v)
	}

	// There is a chance that this test can stall if a signal is sent before
	// all threads are queued, because it's possible for some number of threads
	// to get to the waiting state, the signal to fire, all of the waited
	// threads to pass successfully, then the other threads come in with no-one
	// to run a signal.
	//
	// So we'll just test a fully-waited queue of cascading threads.
	for {
		status := intrinsics.atomic_load(&data.a.status)
		if status == -THREADS {
			// log.debug("All Auto_Reset_Event threads have queued.")
			break
		}
		intrinsics.cpu_relax()
	}

	sync.auto_reset_event_signal(&data.a)

	wait_for(threads[:])

	// The last thread should leave this primitive in a signalled state.
	testing.expect_value(t, data.a.status, 1)
	testing.expect_value(t, data.number, THREADS)
}

@test
test_auto_reset_already_signalled :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, FAIL_TIME)

	a: sync.Auto_Reset_Event
	sync.auto_reset_event_signal(&a)
	sync.auto_reset_event_wait(&a)
	testing.expect_value(t, a.status, 0)
}

@test
test_ticket_mutex :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, FAIL_TIME)

	Data :: struct {
		m: sync.Ticket_Mutex,
		number: int,
	}

	p :: proc(th: ^thread.Thread) {
		data := cast(^Data)th.data

		// log.debugf("TIC-%i> entering", th.id)
		// intrinsics.debug_trap()
		sync.ticket_mutex_lock(&data.m)
		// log.debugf("TIC-%i> locked", th.id)
		data.number += 1
		// log.debugf("TIC-%i> unlocking", th.id)
		sync.ticket_mutex_unlock(&data.m)
		// log.debugf("TIC-%i> leaving", th.id)
	}

	data: Data
	threads: [THREADS]^thread.Thread

	for &v in threads {
		v = thread.create(p)
		v.data = &data
		v.init_context = context
		thread.start(v)
	}

	wait_for(threads[:])

	testing.expect_value(t, data.m.ticket, THREADS)
	testing.expect_value(t, data.m.serving, THREADS)
	testing.expect_value(t, data.number, THREADS)
}

@test
test_benaphore :: proc(t: ^testing.T) {
	when ODIN_ARCH == .riscv64 {
		// NOTE(Jeroen): Regularly times out on the simulated RISC-V CI runners,
		//               so we're skipping the test there.
		return
	}

	testing.set_fail_timeout(t, FAIL_TIME)

	Data :: struct {
		b: sync.Benaphore,
		number: int,
	}

	p :: proc(th: ^thread.Thread) {
		data := cast(^Data)th.data
		sync.benaphore_lock(&data.b)
		data.number += 1
		sync.benaphore_unlock(&data.b)
	}

	data: Data
	threads: [THREADS]^thread.Thread

	for &v in threads {
		v = thread.create(p)
		v.data = &data
		v.init_context = context
		thread.start(v)
	}

	wait_for(threads[:])

	testing.expect_value(t, data.b.counter, 0)
	testing.expect_value(t, data.number, THREADS)
}

@test
test_recursive_benaphore :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, FAIL_TIME)

	Data :: struct {
		b: sync.Recursive_Benaphore,
		number: int,
	}

	p :: proc(th: ^thread.Thread) {
		data := cast(^Data)th.data

		// log.debugf("REC_BEP-%i> entering", th.id)
		tried1 := sync.recursive_benaphore_try_lock(&data.b)
		for _ in 0..<3 {
			sync.recursive_benaphore_lock(&data.b)
		}
		tried2 := sync.recursive_benaphore_try_lock(&data.b)
		// log.debugf("REC_BEP-%i> locked", th.id)
		data.number += 1
		for _ in 0..<3 {
			sync.recursive_benaphore_unlock(&data.b)
		}
		if tried1 { sync.recursive_benaphore_unlock(&data.b) }
		if tried2 { sync.recursive_benaphore_unlock(&data.b) }
		// log.debugf("REC_BEP-%i> leaving", th.id)
	}

	data: Data
	threads: [THREADS]^thread.Thread

	for &v in threads {
		v = thread.create(p)
		v.data = &data
		v.init_context = context
		thread.start(v)
	}

	wait_for(threads[:])

	// The benaphore should be unowned at the end.
	testing.expect_value(t, data.b.counter, 0)
	testing.expect_value(t, data.b.owner, 0)
	testing.expect_value(t, data.b.recursion, 0)
	testing.expect_value(t, data.number, THREADS)
}

@test
test_once :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, FAIL_TIME)

	Data :: struct {
		once: sync.Once,
		number: int,
	}

	write :: proc "contextless" (data: rawptr) {
		data := cast(^Data)data
		data.number += 1
	}

	p :: proc(th: ^thread.Thread) {
		data := cast(^Data)th.data
		// log.debugf("ONCE-%v> entering", th.id)
		sync.once_do_with_data_contextless(&data.once, write, data)
		// log.debugf("ONCE-%v> leaving", th.id)
	}

	data: Data
	threads: [THREADS]^thread.Thread

	for &v in threads {
		v = thread.create(p)
		v.data = &data
		v.init_context = context
		thread.start(v)
	}

	wait_for(threads[:])

	testing.expect_value(t, data.once.done, true)
	testing.expect_value(t, data.number, 1)
}

@test
test_park :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, FAIL_TIME)

	Data :: struct {
		car: sync.Parker,
		number: int,
	}

	data: Data

	th := thread.create_and_start_with_data(&data, proc(data: rawptr) {
		data := cast(^Data)data
		time.sleep(SLEEP_TIME)
		sync.unpark(&data.car)
		data.number += 1
	})

	sync.park(&data.car)

	wait_for([]^thread.Thread{ th })

	PARKER_EMPTY :: 0
	testing.expect_value(t, data.car.state, PARKER_EMPTY)
	testing.expect_value(t, data.number, 1)
}

@test
test_park_with_timeout :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, FAIL_TIME)

	car: sync.Parker
	sync.park_with_timeout(&car, SLEEP_TIME)
}

// An `unpark` which lands while the owner waits must end the wait, and both the
// woken and the timed out Parker must be reusable afterwards.
@test
test_park_with_timeout_unpark :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, FAIL_TIME)

	PARKER_EMPTY :: 0

	car: sync.Parker

	// A timeout leaves the Parker empty.
	sync.park_with_timeout(&car, SLEEP_TIME)
	testing.expect_value(t, car.state, PARKER_EMPTY)

	// A token which is already there is consumed without waiting.
	sync.unpark(&car)
	sync.park_with_timeout(&car, FAIL_TIME)
	testing.expect_value(t, car.state, PARKER_EMPTY)

	// A futex wake without an unpark is spurious and must not end the wait.
	spurious_th := thread.create_and_start_with_data(&car, proc(data: rawptr) {
		car := cast(^sync.Parker)data
		time.sleep(SLEEP_TIME)
		sync.futex_signal(&car.state)
	})
	spurious_start := time.tick_now()
	sync.park_with_timeout(&car, 20 * time.Millisecond)
	testing.expect(t, time.tick_since(spurious_start) >= 10 * time.Millisecond, "spurious wake ended park_with_timeout early")
	wait_for([]^thread.Thread{ spurious_th })
	testing.expect_value(t, car.state, PARKER_EMPTY)

	// An unpark while waiting ends the wait long before the timeout.
	th := thread.create_and_start_with_data(&car, proc(data: rawptr) {
		time.sleep(SLEEP_TIME)
		sync.unpark(cast(^sync.Parker)data)
	})

	start := time.tick_now()
	sync.park_with_timeout(&car, 10 * time.Second)
	testing.expect(t, time.tick_since(start) < FAIL_TIME / 2, "park_with_timeout did not return after unpark")

	wait_for([]^thread.Thread{ th })
	testing.expect_value(t, car.state, PARKER_EMPTY)
}

@test
test_one_shot_event :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, FAIL_TIME)

	Data :: struct {
		event: sync.One_Shot_Event,
		number: int,
	}

	data: Data

	th := thread.create_and_start_with_data(&data, proc(data: rawptr) {
		data := cast(^Data)data
		time.sleep(SLEEP_TIME)
		sync.one_shot_event_signal(&data.event)
		data.number += 1
	})

	sync.one_shot_event_wait(&data.event)

	wait_for([]^thread.Thread{ th })

	testing.expect_value(t, data.event.state, 1)
	testing.expect_value(t, data.number, 1)
}
