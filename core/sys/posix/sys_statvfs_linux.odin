#+build linux amd64, linux arm64, linux riscv64
package posix

import "core:c"
import "core:sys/linux"

// The Linux implementation of `sys/statvfs.h` through system calls, without libc.
//
// The kernel reports `Stat_FS`, whose layout differs from `statvfs_t`, so
// each field is copied over following statvfs(3). Only the two POSIX flag
// bits reach `f_flag`, and `f_favail` always equals `f_ffree` on Linux.

// `VFS_Flags` names the same bits as the kernel's `FS_Flags`.
#assert(int(VFS_Flag_Bits.RDONLY) == int(linux.FS_Flags_Bits.RDONLY))
#assert(int(VFS_Flag_Bits.NOSUID) == int(linux.FS_Flags_Bits.NOSUID))

@(private="file")
statvfs_from_statfs :: proc "contextless" (kfs: ^linux.Stat_FS) -> statvfs_t {
	flags := VFS_Flags{}
	if .RDONLY in kfs.flags {
		flags += {.RDONLY}
	}
	if .NOSUID in kfs.flags {
		flags += {.NOSUID}
	}
	return {
		f_bsize   = c.ulong(kfs.bsize),
		f_frsize  = c.ulong(kfs.frsize),
		f_blocks  = fsblkcnt_t(kfs.blocks),
		f_bfree   = fsblkcnt_t(kfs.bfree),
		f_bavail  = fsblkcnt_t(kfs.bavail),
		f_files   = fsblkcnt_t(kfs.files),
		f_ffree   = fsblkcnt_t(kfs.ffree),
		f_favail  = fsblkcnt_t(kfs.ffree),
		f_fsid    = transmute(c.ulong)kfs.fsid,
		f_flag    = flags,
		f_namemax = c.ulong(kfs.namelen),
		f_type    = c.uint(u32(kfs.type)),
	}
}

/*
Obtains information about the file system containing the fildes.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/statvfs.html ]]
*/
fstatvfs :: proc "c" (fildes: FD, buf: ^statvfs_t) -> result {
	kfs: linux.Stat_FS
	if err := linux.fstatfs(linux.Fd(fildes), &kfs); err != .NONE {
		set_errno(Errno(err))
		return .FAIL
	}
	buf^ = statvfs_from_statfs(&kfs)
	return .OK
}

/*
Obtains information about the file system containing the file named by path.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/statvfs.html ]]
*/
statvfs :: proc "c" (path: cstring, buf: ^statvfs_t) -> result {
	kfs: linux.Stat_FS
	if err := linux.statfs(path, &kfs); err != .NONE {
		set_errno(Errno(err))
		return .FAIL
	}
	buf^ = statvfs_from_statfs(&kfs)
	return .OK
}
