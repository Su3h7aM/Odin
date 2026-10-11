#+build linux
package posix

import "base:intrinsics"
import "core:c"
import "core:sys/linux"

// The Linux implementation of the `sys/sem.h` procedures through system
// calls, without libc. See `sys_ipc_linux.odin`.

/*
Provides various semaphore control operation as specified by cmd.

The fourth argument is a `semun`, passed by value, for `SETVAL`, `SETALL`,
`GETALL`, `SET` and `STAT`; the other commands take none. Like libc, only
those commands read it.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/semctl.html ]]
*/
semctl :: proc "c" (semid: FD, semnum: c.int, cmd: Sem_Cmd, #c_vararg args: ..semun) -> c.int {
	arg: semun
	#partial switch cmd {
	case .SETVAL, .SETALL, .GETALL, .SET, .STAT:
		// The union is one pointer wide and is passed in the same slot as a
		// pointer, so it is read as one.
		list: c.va_list
		intrinsics.c_va_start(&list, args)
		defer intrinsics.c_va_end(&list)
		arg = transmute(semun)intrinsics.c_va_arg(&list, uintptr)
	}
	n, err := linux.semctl(linux.Key(semid), i32(semnum), linux.IPC_Cmd(cmd), transmute(linux.Sem_Un)arg)
	return errno_int(n, err)
}

/*
Returns the semaphore identifier associated with key.

Returns: -1 (setting errno) on failure, a semaphore file descriptor otherwise

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/semget.html ]]
*/
semget :: proc "c" (key: key_t, nsems: c.int, semflg: IPC_Flags) -> FD {
	// The kernel does not check that the count fits `semid_ds.sem_nsems` as
	// POSIX types it, which musl rejects here too.
	if nsems > c.int(max(c.ushort)) {
		set_errno(.EINVAL)
		return -1
	}
	id, err := linux.semget(linux.Key(key), i32(nsems), kernel_ipc_flags(transmute(c.int)semflg))
	return errno_ipc_id(id, err)
}

/*
Perform atomically a user-defined array of semaphore operations in array order on the set of
semaphores associated with the semaphore identifier specified by the argument semid.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/semop.html ]]
*/
semop :: proc "c" (semid: FD, sops: [^]sembuf, nsops: c.size_t) -> result {
	return errno_result(linux.semop(linux.Key(semid), ([^]linux.Sem_Buf)(sops)[:nsops]))
}
