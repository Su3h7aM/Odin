#+build linux amd64, linux arm64, linux riscv64
#+no-instrumentation
package posix

import "base:runtime"
import "core:sys/linux"
import env "core:sys/_env"

_ :: env

// The Linux implementation of `spawn.h` through system calls.
//
// A process is created as musl's `posix_spawn` does (src/process/posix_spawn.c):
// `clone` with `CLONE_VM | CLONE_VFORK` runs a child on a stack of its own in
// the parent's memory while the parent waits. The child calls no libc, uses no
// thread-local state and allocates nothing: it makes system calls only. If it
// cannot `execve` it sends its error number through a close-on-exec pipe, and
// the parent reaps it and returns that number.
//
// The file actions and the attributes are not declared by this package: they are
// opaque objects of libc, made by its own `posix_spawn_file_actions_*` and
// `posix_spawnattr_*` procedures, and only libc can read them. So a spawn that
// has either is handed to libc's `posix_spawn`. Without libc there are no such
// objects to be made, and it fails with `.EINVAL`.

when !ODIN_NO_CRT {
	foreign import libc "system:c"

	@(default_calling_convention="c")
	foreign libc {
		@(private, link_name="posix_spawn")
		libc_posix_spawn :: proc(pid: ^pid_t, path: cstring, file_actions: rawptr, attrp: rawptr, argv: [^]cstring, envp: [^]cstring) -> Errno ---
		@(private, link_name="posix_spawnp")
		libc_posix_spawnp :: proc(pid: ^pid_t, file: cstring, file_actions: rawptr, attrp: rawptr, argv: [^]cstring, envp: [^]cstring) -> Errno ---
	}
}

// What the child needs, which it reads from the parent's memory.
@(private="file")
Spawn_Args :: struct {
	pipe:       [2]linux.Fd,
	old_mask:   linux.Sig_Set,
	// Executed directly when `candidates` is nil.
	path:       cstring,
	// Every path to try for `posix_spawnp`, each ended by a NUL, and an empty one last.
	candidates: [^]byte,
	argv:       [^]cstring,
	envp:       [^]cstring,
}

// The stack of the child. It holds a few small frames of system call wrappers, with room to spare.
@(private="file")
SPAWN_STACK_SIZE :: 8192

// The signals the kernel numbers, which the child scans for handlers.
@(private="file")
SIGNAL_COUNT :: 64

// Runs in the child, on its own stack in the parent's memory, with every signal blocked. Puts every
// handler of the parent back to the default, as the signals are unblocked before the new program
// starts and a handler of the parent must never run in a child that shares its memory. The ignored
// signals stay ignored. The child has a table of handlers of its own, so the parent's is unchanged.
@(private="file")
spawn_prepare :: proc "contextless" (args: ^Spawn_Args) -> linux.Errno {
	for sig in 1..=SIGNAL_COUNT {
		if sig == int(linux.Signal.SIGKILL) || sig == int(linux.Signal.SIGSTOP) {
			continue
		}
		act: linux.Sig_Action
		if err := linux.rt_sigaction(linux.Signal(sig), nil, &act); err != .NONE {
			return err
		}
		// SIG_DFL and SIG_IGN are the first two values of the handler word.
		if uint(act.special) <= uint(linux.Sig_Action_Special.SIG_IGN) {
			continue
		}
		act = {}
		if err := linux.rt_sigaction(linux.Signal(sig), &act, nil); err != .NONE {
			return err
		}
	}

	// The child has the mask of the caller.
	return linux.rt_sigprocmask(.SIG_SETMASK, &args.old_mask, nil)
}

// Starts the new program, and returns the error number of why that failed.
@(private="file")
spawn_exec :: proc "contextless" (args: ^Spawn_Args) -> linux.Errno {
	if args.candidates == nil {
		return linux.execve(args.path, args.argv, args.envp)
	}

	// As `execvp`: a file that is not there, or whose directory is not, is tried in the next
	// directory, one that cannot be run is remembered and reported if none can, and any other error
	// ends the search.
	denied := false
	next := args.candidates
	for next[0] != 0 {
		candidate := cstring(rawptr(next))
		err := linux.execve(candidate, args.argv, args.envp)
		if err == .EACCES {
			denied = true
		} else if err != .ENOENT && err != .ENOTDIR {
			return err
		}
		next = next[len(candidate) + 1:]
	}
	return .EACCES if denied else .ENOENT
}

// The child of the spawn. What it returns is the exit status, which the clone entry exits with.
// The child stays allocation-free until exec: system calls only (signal
// reset, execve, pipe write), so fork-style allocator hazards do not apply
// here even without atfork handlers.
@(private="file")
spawn_child :: proc "c" (arg: rawptr) -> i32 {
	args := (^Spawn_Args)(arg)
	linux.close(args.pipe[0])

	err := spawn_prepare(args)
	if err == .NONE {
		err = spawn_exec(args)
	}

	// An error number is smaller than the atomic size of a pipe write.
	code := i32(err)
	for {
		_, werr := linux.write(args.pipe[1], ([^]u8)(&code)[:size_of(code)])
		if werr != .EINTR {
			break
		}
	}
	return 127
}

// Creates the child and waits until it has started the new program or failed to.
@(private="file")
spawn :: proc "contextless" (pid: ^pid_t, path: cstring, candidates: [^]byte, argv, envp: [^]cstring) -> Errno {
	args := Spawn_Args{
		path       = path,
		candidates = candidates,
		argv       = argv,
		envp       = envp,
	}

	// Block every signal, so that none runs a handler in the child before it has put them back,
	// and so that none cancels this thread half way. The child inherits the mask.
	all_signals := linux.Sig_Set{max(uint)}
	linux.rt_sigprocmask(.SIG_BLOCK, &all_signals, &args.old_mask)
	defer linux.rt_sigprocmask(.SIG_SETMASK, &args.old_mask, nil)

	if err := linux.pipe2(&args.pipe, {.CLOEXEC}); err != .NONE {
		return Errno(err)
	}

	stack: [SPAWN_STACK_SIZE]byte = ---
	top := rawptr(uintptr(&stack[0]) + SPAWN_STACK_SIZE)
	flags := u32(linux.CLONE_VM | linux.CLONE_VFORK) | u32(linux.Signal.SIGCHLD)
	child, cerr := linux.clone(spawn_child, top, flags, &args)
	linux.close(args.pipe[1])

	// The child has started the new program, or has ended after saying why it could not.
	code: i32
	if cerr == .NONE {
		read: int
		for {
			err: linux.Errno
			read, err = linux.read(args.pipe[0], ([^]u8)(&code)[:size_of(code)])
			if err != .EINTR {
				break
			}
		}
		if read == size_of(code) {
			status: u32
			for {
				if _, err := linux.wait4(child, &status, {}, nil); err != .EINTR {
					break
				}
			}
		} else {
			code = 0
		}
	} else {
		code = i32(cerr)
	}
	linux.close(args.pipe[0])

	if code == 0 && pid != nil {
		pid^ = pid_t(child)
	}
	return Errno(code)
}

/*
Creates a child process from a provided filepath.

The child starts with every signal handler of the parent reset to the default, and with the signal
mask of the caller. It inherits the open descriptors that are not close-on-exec. Everything else is
as for `execve`, which it ends with.

`file_actions` and `attrp` are the objects of libc's `posix_spawn_file_actions_*` and
`posix_spawnattr_*`. When either is not nil the call is libc's, and without libc it fails with
`.EINVAL`.

Returns: 0 on success, with the child pid returned in the pid argument, or the error number of why
the child could not be created or could not start the program. It does not set errno.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/posix_spawn.html ]]
*/
posix_spawn :: proc "c" (pid: ^pid_t, path: cstring, file_actions: rawptr, attrp: rawptr, argv: [^]cstring, envp: [^]cstring) -> Errno {
	if file_actions != nil || attrp != nil {
		when ODIN_NO_CRT {
			return .EINVAL
		} else {
			return libc_posix_spawn(pid, path, file_actions, attrp, argv, envp)
		}
	}
	return spawn(pid, path, nil, argv, envp)
}

// The default of `execvp`.
@(private="file")
DEFAULT_PATH :: "/bin:/usr/bin"

// Longest name of a file, and longest path, on Linux.
@(private="file")
NAME_MAX :: 255
@(private="file")
PATH_MAX :: 4096

// Builds the paths for `posix_spawnp` to try, one for each directory of `search`, from the heap.
// A directory that leaves no room for the name is left out, and an empty one is the current one.
@(private="file")
path_candidates :: proc "contextless" (file: cstring, search: string) -> [^]byte {
	name := string(file)
	// Two passes over the directories: the first measures, the second fills.
	size := 1
	for pass in 0..<2 {
		buf: [^]byte
		if pass == 1 {
			buf = ([^]byte)(runtime.heap_alloc(size, false))
			if buf == nil {
				return nil
			}
		}
		at := 0
		rest := search
		for {
			end := len(rest)
			for i in 0..<len(rest) {
				if rest[i] == ':' {
					end = i
					break
				}
			}
			dir := rest[:end]
			if len(dir) == 0 {
				dir = "."
			}
			if len(dir) + 1 + len(name) < PATH_MAX {
				if pass == 1 {
					at += copy(buf[at:size], dir)
					buf[at] = '/'
					at += 1
					at += copy(buf[at:size], name)
					buf[at] = 0
					at += 1
				} else {
					size += len(dir) + 1 + len(name) + 1
				}
			}
			if end == len(rest) {
				break
			}
			rest = rest[end + 1:]
		}
		if pass == 1 {
			buf[at] = 0
			return buf
		}
	}
	return nil
}

/*
Creates a child process from a provided file name, searching the directories of the PATH
environment variable of the caller for it when it has no slash.

Like `posix_spawn` otherwise. A file that is found but is not a binary is not run as a shell script.
The search uses the calling process environment, not envp, and defaults to "/bin:/usr/bin"
when PATH is absent.

Returns: 0 on success, with the child pid returned in the pid argument, or the error number of why
the child could not be created or could not start the program. It does not set errno.

[[ More; https://pubs.opengroup.org/onlinepubs/9699919799/functions/posix_spawn.html ]]
*/
posix_spawnp :: proc "c" (pid: ^pid_t, file: cstring, file_actions: rawptr, attrp: rawptr, argv: [^]cstring, envp: [^]cstring) -> Errno {
	if file_actions != nil || attrp != nil {
		when ODIN_NO_CRT {
			return .EINVAL
		} else {
			return libc_posix_spawnp(pid, file, file_actions, attrp, argv, envp)
		}
	}

	name := string(file)
	if len(name) == 0 {
		return .ENOENT
	}
	for i in 0..<len(name) {
		if name[i] == '/' {
			return spawn(pid, file, nil, argv, envp)
		}
	}
	if len(name) > NAME_MAX {
		return .ENAMETOOLONG
	}

	search := DEFAULT_PATH
	when ODIN_NO_CRT {
		context = runtime.default_context()
		path, found, err := env.lookup_copy("PATH", runtime.heap_allocator())
		if err != nil {
			return .ENOMEM
		}
		defer delete(path, runtime.heap_allocator())
		if found {
			search = path
		}
	} else {
		if path := getenv("PATH"); path != nil {
			search = string(path)
		}
	}
	candidates := path_candidates(file, search)
	if candidates == nil {
		return .ENOMEM
	}
	defer runtime.heap_free(candidates)
	return spawn(pid, nil, candidates, argv, envp)
}
