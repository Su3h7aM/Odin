#+build windows, darwin, netbsd, openbsd, freebsd
package posix

import "core:c/libc"

// Linux uses the owned arithmetic in stdlib_linux.odin on both profiles;
// these need no libc state. Every other OS keeps the libc aliases.
//
// This lives in its own file instead of a `when ODIN_OS != .Linux` block,
// because Odin rejects a global `when` that declares a builtin name such as
// `abs`.
abs   :: libc.abs
labs  :: libc.labs
llabs :: libc.llabs
div   :: libc.div
ldiv  :: libc.ldiv
lldiv :: libc.lldiv
