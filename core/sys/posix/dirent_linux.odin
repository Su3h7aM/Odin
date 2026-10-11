#+build linux
package posix

import "base:runtime"
import "core:sys/linux"

@(private="file")
Linux_Directory_Stream :: struct {
	fd:       linux.Fd,
	position: int,
	length:   int,
	location: i64,
	// Aligned storage for every possible u16 getdents64 record length.
	buffer:   [8192]u64,
}

#assert(offset_of(dirent, d_name) == 19)
#assert(offset_of(dirent, d_ino) == offset_of(linux.Dirent, ino))
#assert(offset_of(dirent, d_off) == offset_of(linux.Dirent, off))
#assert(offset_of(dirent, d_reclen) == offset_of(linux.Dirent, reclen))
#assert(offset_of(dirent, d_type) == offset_of(linux.Dirent, type))
#assert(align_of(dirent) <= align_of(u64))

// Opens a directory stream with a close-on-exec descriptor. The caller must
// release it with closedir. Returns nil and sets errno on failure.
opendir :: proc "c" (path: cstring) -> DIR {
	fd, err := linux.open(path, {.DIRECTORY, .CLOEXEC})
	if err != .NONE {
		set_errno(Errno(err))
		return nil
	}
	dir := fdopendir(FD(fd))
	if dir == nil {
		linux.close(fd)
	}
	return dir
}

// Takes ownership of a readable directory descriptor on success, preserving
// its offset and FD_CLOEXEC flag. On failure returns nil, sets errno, and leaves
// ownership with the caller. Release a successful stream with closedir.
fdopendir :: proc "c" (dirp: FD) -> DIR {
	fd := linux.Fd(dirp)
	st: linux.Stat
	if err := linux.fstat(fd, &st); err != .NONE {
		set_errno(Errno(err))
		return nil
	}
	if st.mode & linux.S_IFMT != linux.S_IFDIR {
		set_errno(.ENOTDIR)
		return nil
	}
	flags, flags_err := linux.fcntl_getfl(fd, linux.F_GETFL)
	if flags_err != .NONE {
		set_errno(Errno(flags_err))
		return nil
	}
	if .PATH in flags || .WRONLY in flags {
		set_errno(.EBADF)
		return nil
	}
	location, seek_err := linux.lseek(fd, 0, .CUR)
	if seek_err != .NONE {
		set_errno(Errno(seek_err))
		return nil
	}
	stream := (^Linux_Directory_Stream)(runtime.heap_alloc(size_of(Linux_Directory_Stream)))
	if stream == nil {
		set_errno(.ENOMEM)
		return nil
	}
	stream.fd = fd
	stream.location = location
	return DIR(stream)
}

// Closes the owned descriptor and releases the stream, invalidating returned
// entries even if closing fails. Returns .FAIL and sets errno on failure.
closedir :: proc "c" (dirp: DIR) -> result {
	if dirp == nil {
		set_errno(.EBADF)
		return .FAIL
	}
	stream := (^Linux_Directory_Stream)(dirp)
	err := linux.close(stream.fd)
	runtime.heap_free(stream)
	return errno_result(err)
}

// Returns an entry borrowed from the stream, overwritten by the next readdir
// call. Returns nil at end of stream without changing errno. Errors return nil
// and set errno. A name may extend past d_name: use its NUL terminator and
// d_reclen rather than the declared array capacity, as with libc readdir.
// Access to a shared stream must be synchronized by the caller.
readdir :: proc "c" (dirp: DIR) -> ^dirent {
	if dirp == nil {
		set_errno(.EBADF)
		return nil
	}
	stream := (^Linux_Directory_Stream)(dirp)
	if stream.position == stream.length {
		length, err := linux.getdents(stream.fd, ([^]u8)(&stream.buffer[0])[:size_of(stream.buffer)])
		if err != .NONE {
			set_errno(Errno(err))
			return nil
		}
		stream.position = 0
		stream.length = length
		if length == 0 {
			return nil
		}
	}
	// Linux getdents64 and the public dirent have the same prefix. Return the
	// complete borrowed record, including names beyond the fixed d_name array.
	remaining := stream.length - stream.position
	if remaining < 20 || stream.position % 8 != 0 {
		set_errno(.EIO)
		return nil
	}
	buffer := ([^]u8)(&stream.buffer[0])[:stream.length]
	entry := (^dirent)(rawptr(&buffer[stream.position]))
	reclen := int(entry.d_reclen)
	if reclen < 20 || reclen > remaining || reclen % 8 != 0 {
		set_errno(.EIO)
		return nil
	}
	terminated := false
	for ch in buffer[stream.position + 19:stream.position + reclen] {
		if ch == 0 {
			terminated = true
			break
		}
	}
	if !terminated {
		set_errno(.EIO)
		return nil
	}
	stream.position += reclen
	stream.location = entry.d_off
	return entry
}

// Repositions the stream to its beginning and discards buffered entries.
// Sets errno if the underlying seek fails.
rewinddir :: proc "c" (dirp: DIR) {
	seekdir(dirp, 0)
}

// Returns the borrowed descriptor, or -1 and sets errno for a nil stream.
// The caller must not close it or change the associated file position.
dirfd :: proc "c" (dirp: DIR) -> FD {
	if dirp == nil {
		set_errno(.EBADF)
		return -1
	}
	return FD((^Linux_Directory_Stream)(dirp).fd)
}

// Returns the next entry's opaque Linux d_off cookie, not a byte offset.
// Returns -1 and sets errno on failure. Pass a successful value to seekdir on
// this stream to restore the position.
telldir :: proc "c" (dirp: DIR) -> dir_loc {
	if dirp == nil {
		set_errno(.EBADF)
		return -1
	}
	location := (^Linux_Directory_Stream)(dirp).location
	if location < i64(min(dir_loc)) || location > i64(max(dir_loc)) {
		set_errno(.EOVERFLOW)
		return -1
	}
	return dir_loc(location)
}

// Restores a cookie returned by telldir and discards buffered entries.
// Sets errno on failure, leaving the buffered position unchanged.
seekdir :: proc "c" (dirp: DIR, loc: dir_loc) {
	if dirp == nil {
		set_errno(.EBADF)
		return
	}
	stream := (^Linux_Directory_Stream)(dirp)
	location, err := linux.lseek(stream.fd, i64(loc), .SET)
	if err != .NONE {
		set_errno(Errno(err))
		return
	}
	stream.position = 0
	stream.length = 0
	stream.location = location
}
