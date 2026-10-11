#+build linux
package posix

import "core:c"
import "core:sys/linux"

// The Linux implementation of the XSI IPC procedures of `sys/msg.h`,
// `sys/sem.h` and `sys/shm.h` through system calls, without libc.
//
// A failure is reported the same way as for the libc procedures, with `errno`.
//
// x86-64, arm64 and riscv64 have a system call for each procedure and only
// the kernel's 64-bit structures, so nothing here ORs IPC_64 into the command
// as libc does on multiplexed `ipc` and 32-bit time targets: the kernel does
// not accept it on these architectures (musl defines IPC_64 as 0 there).

// The structures go to the kernel by pointer, so each must match the kernel's
// `struct ipc64_perm`, `msqid64_ds`, `semid64_ds` and `shmid64_ds`, which
// `linux.IPC_Perm`, `linux.Msqid_DS`, `linux.Semid_DS` and `linux.Shmid_DS` pin
// to their sizes. The 32-bit targets have other layouts that `time_t` here
// does not follow, so they are not checked.
when size_of(int) == 8 {
	#assert(size_of(ipc_perm) == size_of(linux.IPC_Perm))
	#assert(offset_of(ipc_perm, __ipc_perm_key) == offset_of(linux.IPC_Perm, key))
	#assert(offset_of(ipc_perm, uid)            == offset_of(linux.IPC_Perm, uid))
	#assert(offset_of(ipc_perm, gid)            == offset_of(linux.IPC_Perm, gid))
	#assert(offset_of(ipc_perm, cuid)           == offset_of(linux.IPC_Perm, cuid))
	#assert(offset_of(ipc_perm, cgid)           == offset_of(linux.IPC_Perm, cgid))
	#assert(offset_of(ipc_perm, mode)           == offset_of(linux.IPC_Perm, mode))
	#assert(offset_of(ipc_perm, __ipc_perm_seq) == offset_of(linux.IPC_Perm, seq))

	#assert(size_of(msqid_ds) == size_of(linux.Msqid_DS))
	#assert(offset_of(msqid_ds, msg_perm)   == offset_of(linux.Msqid_DS, perm))
	#assert(offset_of(msqid_ds, msg_stime)  == offset_of(linux.Msqid_DS, stime))
	#assert(offset_of(msqid_ds, msg_rtime)  == offset_of(linux.Msqid_DS, rtime))
	#assert(offset_of(msqid_ds, msg_ctime)  == offset_of(linux.Msqid_DS, ctime))
	#assert(offset_of(msqid_ds, msg_cbytes) == offset_of(linux.Msqid_DS, cbytes))
	#assert(offset_of(msqid_ds, msg_qnum)   == offset_of(linux.Msqid_DS, qnum))
	#assert(offset_of(msqid_ds, msg_qbytes) == offset_of(linux.Msqid_DS, qbytes))
	#assert(offset_of(msqid_ds, msg_lspid)  == offset_of(linux.Msqid_DS, lspid))
	#assert(offset_of(msqid_ds, msg_lrpid)  == offset_of(linux.Msqid_DS, lrpid))

	#assert(size_of(semid_ds) == size_of(linux.Semid_DS))
	#assert(offset_of(semid_ds, sem_perm)  == offset_of(linux.Semid_DS, perm))
	#assert(offset_of(semid_ds, sem_otime) == offset_of(linux.Semid_DS, otime))
	#assert(offset_of(semid_ds, sem_ctime) == offset_of(linux.Semid_DS, ctime))
	#assert(offset_of(semid_ds, sem_nsems) == offset_of(linux.Semid_DS, nsems))

	#assert(size_of(shmid_ds) == size_of(linux.Shmid_DS))
	#assert(offset_of(shmid_ds, shm_perm)   == offset_of(linux.Shmid_DS, perm))
	#assert(offset_of(shmid_ds, shm_segsz)  == offset_of(linux.Shmid_DS, segsz))
	#assert(offset_of(shmid_ds, shm_atime)  == offset_of(linux.Shmid_DS, atime))
	#assert(offset_of(shmid_ds, shm_dtime)  == offset_of(linux.Shmid_DS, dtime))
	#assert(offset_of(shmid_ds, shm_ctime)  == offset_of(linux.Shmid_DS, ctime))
	#assert(offset_of(shmid_ds, shm_cpid)   == offset_of(linux.Shmid_DS, cpid))
	#assert(offset_of(shmid_ds, shm_lpid)   == offset_of(linux.Shmid_DS, lpid))
	#assert(offset_of(shmid_ds, shm_nattch) == offset_of(linux.Shmid_DS, nattch))

	#assert(size_of(sembuf) == size_of(linux.Sem_Buf))
	#assert(offset_of(sembuf, sem_num) == offset_of(linux.Sem_Buf, num))
	#assert(offset_of(sembuf, sem_op)  == offset_of(linux.Sem_Buf, op))
	#assert(offset_of(sembuf, sem_flg) == offset_of(linux.Sem_Buf, flg))
}

// The commands and flags are passed to the kernel as they are.
#assert(IPC_CREAT   == 1 << uint(linux.IPC_Flags_Bits.IPC_CREAT))
#assert(IPC_EXCL    == 1 << uint(linux.IPC_Flags_Bits.IPC_EXCL))
#assert(IPC_NOWAIT  == 1 << uint(linux.IPC_Flags_Bits.IPC_NOWAIT))
#assert(MSG_NOERROR == 1 << uint(linux.IPC_Flags_Bits.MSG_NOERROR))
#assert(SEM_UNDO    == 1 << uint(linux.IPC_Flags_Bits.SEM_UNDO))
#assert(SHM_RDONLY  == 1 << uint(linux.IPC_Flags_Bits.SHM_RDONLY))
#assert(SHM_RND     == 1 << uint(linux.IPC_Flags_Bits.SHM_RND))
#assert(int(IPC_Cmd.RMID) == int(linux.IPC_Cmd.IPC_RMID))
#assert(int(IPC_Cmd.SET)  == int(linux.IPC_Cmd.IPC_SET))
#assert(int(IPC_Cmd.STAT) == int(linux.IPC_Cmd.IPC_STAT))
#assert(int(Sem_Cmd.GETPID)  == int(linux.IPC_Cmd.GETPID))
#assert(int(Sem_Cmd.GETVAL)  == int(linux.IPC_Cmd.GETVAL))
#assert(int(Sem_Cmd.GETALL)  == int(linux.IPC_Cmd.GETALL))
#assert(int(Sem_Cmd.GETNCNT) == int(linux.IPC_Cmd.GETNCNT))
#assert(int(Sem_Cmd.GETZCNT) == int(linux.IPC_Cmd.GETZCNT))
#assert(int(Sem_Cmd.SETVAL)  == int(linux.IPC_Cmd.SETVAL))
#assert(int(Sem_Cmd.SETALL)  == int(linux.IPC_Cmd.SETALL))

// The kernel takes the flags as an int with the mode in the low nine bits, and
// every flag it defines is in the low 16, which is the width `linux.IPC_Flags`
// carries. `IPC_Flag_Bits` does not name the mode bits, so a caller sets them
// by transmuting an integer.
@(private)
kernel_ipc_flags :: #force_inline proc "contextless" (flags: c.int) -> linux.IPC_Flags {
	return transmute(linux.IPC_Flags)u16(flags)
}

// Returns the identifier from the get calls, or -1 setting errno.
@(private)
errno_ipc_id :: #force_inline proc "contextless" (id: linux.Key, err: linux.Errno) -> FD {
	if err != .NONE {
		set_errno(Errno(err))
		return -1
	}
	return FD(id)
}

/*
Generate an IPC key.

The key is built from the low 16 bits of the file's inode number, the low 8 bits of its
device number and the low 8 bits of `id`, as glibc and musl build it.

Returns: -1 (setting errno) on failure, the key otherwise

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/ftok.html ]]
*/
ftok :: proc "c" (path: cstring, id: c.int) -> key_t {
	st: linux.Stat
	if err := linux.stat(path, &st); err != .NONE {
		set_errno(Errno(err))
		return -1
	}
	key := u32(st.ino & 0xffff) | u32(st.dev & 0xff) << 16 | u32(id & 0xff) << 24
	return key_t(i32(key))
}
