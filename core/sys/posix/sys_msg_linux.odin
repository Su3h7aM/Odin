#+build linux
package posix

import "core:c"
import "core:sys/linux"

// The Linux implementation of the `sys/msg.h` procedures through system
// calls, without libc. See `sys_ipc_linux.odin`.

/*
Provides various operation as specified by the given cmd.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/msgctl.html ]]
*/
msgctl :: proc "c" (msqid: FD, cmd: IPC_Cmd, buf: ^msqid_ds) -> result {
	_, err := linux.msgctl(linux.Key(msqid), linux.IPC_Cmd(cmd), (^linux.Msqid_DS)(buf))
	return errno_result(err)
}

/*
Returns the message queue identifier associated with the argument key.

Returns: -1 (setting errno) on failure, the identifier otherwise

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/msgget.html ]]
*/
msgget :: proc "c" (key: key_t, msgflg: IPC_Flags) -> FD {
	id, err := linux.msgget(linux.Key(key), kernel_ipc_flags(transmute(c.int)msgflg))
	return errno_ipc_id(id, err)
}

/*
Read a message from the queue.

Returns: -1 (setting errno) on failure, the bytes received otherwise

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/msgrcv.html ]]
*/
msgrcv :: proc "c" (
	msgid:  FD,
	msgp:   rawptr,
	msgsz:  c.size_t,
	msgtyp: c.long,
	msgflg: IPC_Flags,
) -> c.ssize_t {
	n, err := linux.msgrcv(linux.Key(msgid), msgp, int(msgsz), int(msgtyp), kernel_ipc_flags(transmute(c.int)msgflg))
	return errno_ssize(n, err)
}

/*
Send a message on the queue.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/msgsnd.html ]]
*/
msgsnd :: proc "c" (msgid: FD, msgp: rawptr, msgsz: c.size_t, msgflg: IPC_Flags) -> result {
	return errno_result(linux.msgsnd(linux.Key(msgid), msgp, int(msgsz), kernel_ipc_flags(transmute(c.int)msgflg)))
}
