// Optional C-interop declarations for the C standard library. Linux core
// paths use `core:sys/linux` instead and do not depend on libc.
// Pure type and constant declarations can be used under `-no-crt`; CRT
// procedures declared here require the C runtime and fail to link without it.
package libc
