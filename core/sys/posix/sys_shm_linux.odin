#+build linux
package posix

import "core:c"
import "core:sys/linux"

// The Linux implementation of the `sys/shm.h` procedures through system
// calls, without libc. See `sys_ipc_linux.odin`.

/*
Attaches the shared memory segment associated with the identifier
into the address space of the calling process.

Returns: `(rawptr)(~uintptr(0))`, as C's `(void *)-1` (setting errno), on failure, the address otherwise

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/shmat.html ]]
*/
shmat :: proc "c" (shmid: FD, shmaddr: rawptr, shmflag: SHM_Flags) -> rawptr {
	addr, err := linux.shmat(linux.Key(shmid), shmaddr, kernel_ipc_flags(transmute(c.int)shmflag))
	if err != .NONE {
		set_errno(Errno(err))
		return rawptr(~uintptr(0))
	}
	return addr
}

/*
Provides various shared memory operation as specified by the given cmd.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/shmctl.html ]]
*/
shmctl :: proc "c" (shmid: FD, cmd: IPC_Cmd, buf: ^shmid_ds) -> result {
	return errno_result(linux.shmctl_ds(linux.Key(shmid), linux.IPC_Cmd(cmd), (^linux.Shmid_DS)(buf)))
}

/*
Detaches the shared memory segment located at the address specified.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/shmdt.html ]]
*/
shmdt :: proc "c" (shmaddr: rawptr) -> result {
	return errno_result(linux.shmdt(shmaddr))
}

/*
Returns the shared memory identifier associated with key.

Returns: -1 (setting errno) on failure, the shared memory ID otherwise

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/shmget.html ]]
*/
shmget :: proc "c" (key: key_t, size: c.size_t, shmflag: SHM_Flags) -> FD {
	id, err := linux.shmget(linux.Key(key), uint(size), kernel_ipc_flags(transmute(c.int)shmflag))
	return errno_ipc_id(id, err)
}
