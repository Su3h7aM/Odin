#+build linux
package runtime

// The environ symbol for Linux without the C runtime, owned here on every
// architecture so core:sys/_env can alias one symbol everywhere. Startup
// publishes the inherited table before C constructors run and records the
// publication; the leaf adopts whatever pointer is current without
// overwriting constructor-installed replacements, including an intentional
// clear to nil. Architectures without early publication keep the leaf
// fallback from the argument vector, as before.
when ODIN_NO_CRT {
	@(private, export, link_name="environ")
	environ: [^]cstring

	// Set alongside environ by every early-publication path. Public so the
	// environment leaf can distinguish a published table, even a nil
	// clearing, from no publication at all.
	environ_published: bool

	// Records the inherited table; envp follows the argv terminator on the
	// initial stack. Returns it for callers that also need it directly.
	// Contextless: safe before any context exists.
	publish_startup_environ :: proc "contextless" (argv: [^]cstring, argc: i32) -> [^]cstring {
		envp := ([^]cstring)(uintptr(argv) + uintptr(argc+1) * size_of(cstring))
		environ = envp
		environ_published = true
		return envp
	}
}
