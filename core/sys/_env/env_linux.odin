#+build linux
package env

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:sys/linux"

_ :: runtime
_ :: strings
_ :: sync
_ :: linux

// Internal shared environment for Linux without libc. Direct writes to environ
// must be synchronized with all environment operations by the caller. Returned
// getenv pointers are borrowed until a subsequent environment mutation.
//
// Each owned allocation has one ownership record, independent of entry count.
// Reconciliation scans the current environ, including caller-replaced tables
// and entries. Aliases into owned storage retain the whole allocation. Borrowed
// putenv strings and inherited strings are never freed.
when ODIN_NO_CRT {
	// The environ symbol is owned by base:runtime, which publishes the
	// inherited table before C constructors run. This alias observes the same
	// storage, including constructor-installed replacements.
	@(private)
	foreign {
		@(link_name="environ")
		environment: [^]cstring
	}

	@(private)
	gate: sync.Mutex

	@(private)
	Block :: struct {
		next:      ^Block,
		bytes:     []byte,
		allocator: runtime.Allocator,
	}

	@(private)
	owned: ^Block

	@(private)
	MAX_SIZE :: int((~uint(0)) >> 1)

	@(init)
	initialize :: proc "contextless" () {
		// Startup sets runtime.args__ before package initialization. This does
		// not allocate. The runtime publishes the inherited table before C
		// constructors on paths that support it; adopt whatever pointer is
		// current then, including a constructor-installed replacement or an
		// intentional clear to nil, and never overwrite it here. Only when
		// nothing was published, such as a shared object without early
		// startup, fall back to the argument vector. Reconciliation below
		// absorbs whatever table is current, including caller-replaced ones.
		if !runtime.environ_published && raw_data(runtime.args__) != nil {
			#no_bounds_check environment = ([^]cstring)(&runtime.args__[len(runtime.args__) + 1])
		}
	}

	@(private)
	allocate :: proc(size: int, allocator: runtime.Allocator) -> (^Block, runtime.Allocator_Error) {
		if size < 0 || size > MAX_SIZE - size_of(Block) {
			return nil, .Out_Of_Memory
		}
		bytes, err := runtime.mem_alloc(size_of(Block) + size, align_of(Block), allocator)
		if err != nil {
			return nil, err
		}
		block := (^Block)(raw_data(bytes))
		block^ = Block{bytes = bytes, allocator = allocator}
		return block, nil
	}

	@(private)
	payload :: proc(block: ^Block) -> rawptr {
		return rawptr(uintptr(raw_data(block.bytes)) + uintptr(size_of(Block)))
	}

	@(private)
	free_block :: proc(block: ^Block) {
		runtime.mem_free(raw_data(block.bytes), block.allocator)
	}

	@(private)
	contains :: proc(block: ^Block, pointer: rawptr) -> bool {
		address := uintptr(pointer)
		start := uintptr(payload(block))
		return address >= start && address < uintptr(raw_data(block.bytes)) + uintptr(len(block.bytes))
	}

	@(private)
	count :: proc() -> int {
		n := 0
		if environment != nil {
			for environment[n] != nil {
				n += 1
			}
		}
		return n
	}

	// Call only while holding gate. Entries can share allocations or point
	// into them; free an allocation once, only when no current reference exists.
	@(private)
	reconcile :: proc() {
		n := count()
		link := &owned
		for link^ != nil {
			block := link^
			used := contains(block, environment)
			for i in 0..<n {
				if contains(block, rawptr(environment[i])) {
					used = true
					break
				}
			}
			if used {
				link = &block.next
			} else {
				link^ = block.next
				free_block(block)
			}
		}
	}

	@(private)
	valid_name :: proc(name: string) -> bool {
		return len(name) != 0 && strings.index_byte(name, '=') == -1 && strings.index_byte(name, 0) == -1
	}

	@(private)
	matches :: proc(entry: cstring, name: string) -> bool {
		text := string(entry)
		return len(text) > len(name) && text[:len(name)] == name && text[len(name)] == '='
	}

	@(private)
	lookup :: proc(name: string) -> cstring {
		if !valid_name(name) {
			return nil
		}
		if environment != nil {
			for i := 0; environment[i] != nil; i += 1 {
				if matches(environment[i], name) {
					return cstring(([^]byte)(rawptr(environment[i]))[len(name) + 1:])
				}
			}
		}
		return nil
	}

	getenv :: proc "contextless" (name: cstring) -> cstring {
		context = runtime.default_context()
		sync.guard(&gate)
		reconcile()
		return lookup(string(name))
	}

	lookup_copy :: proc(name: string, allocator: runtime.Allocator) -> (value: string, found: bool, err: runtime.Allocator_Error) {
		sync.guard(&gate)
		reconcile()
		pointer := lookup(name)
		if pointer == nil {
			return
		}
		found = true
		text := string(pointer)
		bytes: []byte
		bytes, err = runtime.mem_alloc(len(text), 1, allocator)
		if err == nil {
			copy(bytes, text)
			value = string(bytes)
		}
		return
	}

	lookup_into :: proc(name: string, buffer: []byte) -> (value: string, found: bool, fits: bool) {
		sync.guard(&gate)
		reconcile()
		pointer := lookup(name)
		if pointer == nil {
			return
		}
		found = true
		text := string(pointer)
		fits = len(text) <= len(buffer)
		if fits {
			copy(buffer, text)
			value = string(buffer[:len(text)])
		}
		return
	}

	// Builds a replacement table before publishing. On failure nothing changes.
	// A nil entry means remove all matching names. Caller holds gate.
	@(private)
	replace :: proc(name: string, entry: cstring, allocator: runtime.Allocator) -> runtime.Allocator_Error {
		n := count()
		if n > MAX_SIZE / size_of(cstring) - 2 {
			return .Out_Of_Memory
		}
		block, err := allocate((n + 2) * size_of(cstring), allocator)
		if err != nil {
			return err
		}
		table := ([^]cstring)(payload(block))
		at := 0
		inserted := false
		for i in 0..<n {
			if matches(environment[i], name) {
				if entry != nil && !inserted {
					table[at] = entry
					at += 1
					inserted = true
				}
			} else {
				table[at] = environment[i]
				at += 1
			}
		}
		if entry != nil && !inserted {
			table[at] = entry
			at += 1
		}
		table[at] = nil
		block.next = owned
		owned = block
		environment = table
		reconcile()
		return nil
	}

	setenv :: proc "contextless" (name, value: cstring, overwrite: bool, allocator: runtime.Allocator) -> linux.Errno {
		err, _ := setenv_text(string(name), string(value), overwrite, allocator)
		return err
	}

	setenv_text :: proc "contextless" (key, text: string, overwrite: bool, allocator: runtime.Allocator) -> (linux.Errno, runtime.Allocator_Error) {
		context = runtime.default_context()
		if !valid_name(key) {
			return .EINVAL, nil
		}
		sync.guard(&gate)
		reconcile()
		if existing := lookup(key); existing != nil && (!overwrite || string(existing) == text) {
			return .NONE, nil
		}
		if len(text) > MAX_SIZE - 2 || len(key) > MAX_SIZE - len(text) - 2 {
			return .ENOMEM, .Out_Of_Memory
		}
		block, err := allocate(len(key) + len(text) + 2, allocator)
		if err != nil {
			return .ENOMEM, err
		}
		bytes := ([^]byte)(payload(block))[:len(key) + len(text) + 2]
		copy(bytes, key)
		bytes[len(key)] = '='
		copy(bytes[len(key) + 1:], text)
		bytes[len(bytes) - 1] = 0
		// Keep the new string reachable during replacement's reconciliation.
		block.next = owned
		owned = block
		if err = replace(key, cstring(raw_data(bytes)), allocator); err != nil {
			owned = block.next
			free_block(block)
			return .ENOMEM, err
		}
		return .NONE, nil
	}

	unsetenv :: proc "contextless" (name: cstring, allocator: runtime.Allocator) -> linux.Errno {
		return unsetenv_text(string(name), allocator)
	}

	unsetenv_text :: proc "contextless" (key: string, allocator: runtime.Allocator) -> linux.Errno {
		context = runtime.default_context()
		if !valid_name(key) {
			return .EINVAL
		}
		sync.guard(&gate)
		reconcile()
		if lookup(key) == nil {
			return .NONE
		}
		if replace(key, nil, allocator) != nil {
			return .ENOMEM
		}
		return .NONE
	}

	putenv :: proc "contextless" (text: cstring, allocator: runtime.Allocator) -> linux.Errno {
		context = runtime.default_context()
		string := string(text)
		eq := strings.index_byte(string, '=')
		if eq == -1 {
			// Linux putenv without '=' removes the name.
			return unsetenv(text, allocator)
		}
		key := string[:eq]
		if !valid_name(key) {
			return .EINVAL
		}
		sync.guard(&gate)
		reconcile()
		if replace(key, text, allocator) != nil {
			return .ENOMEM
		}
		return .NONE
	}

	clear_environment :: proc() {
		sync.guard(&gate)
		environment = nil
		reconcile()
	}

	// An independent, nil-terminated table and strings in one allocation.
	Snapshot :: struct {
		values:    []cstring,
		bytes:     []byte,
		allocator: runtime.Allocator,
	}

	take_snapshot :: proc "contextless" (allocator: runtime.Allocator) -> (snapshot: Snapshot, err: runtime.Allocator_Error) {
		context = runtime.default_context()
		sync.guard(&gate)
		reconcile()
		n := count()
		if n > MAX_SIZE / size_of(cstring) - 1 {
			return snapshot, .Out_Of_Memory
		}
		size := (n + 1) * size_of(cstring)
		for i in 0..<n {
			length := len(environment[i])
			if length > MAX_SIZE - size - 1 {
				return snapshot, .Out_Of_Memory
			}
			size += length + 1
		}
		bytes: []byte
		bytes, err = runtime.mem_alloc(size, align_of(cstring), allocator)
		if err != nil {
			return
		}
		values := ([^]cstring)(raw_data(bytes))[:n + 1]
		at := (n + 1) * size_of(cstring)
		for i in 0..<n {
			text := string(environment[i])
			values[i] = cstring(&bytes[at])
			copy(bytes[at:], text)
			at += len(text)
			bytes[at] = 0
			at += 1
		}
		values[n] = nil
		snapshot = Snapshot{values, bytes, allocator}
		return
	}

	release_snapshot :: proc "contextless" (snapshot: Snapshot) {
		context = runtime.default_context()
		runtime.mem_free(raw_data(snapshot.bytes), snapshot.allocator)
	}
}
