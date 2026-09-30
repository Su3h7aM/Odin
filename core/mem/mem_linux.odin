#+build linux
package mem

import "base:runtime"

// The runtime parses the page size from the auxiliary vector at startup, so
// there is no need to call into libc for it.
@(init, private, no_sanitize_address)
query_page_size_init :: proc "contextless" () {
	PAGE_SIZE = max(PAGE_SIZE, runtime.get_page_size())

	// is power of two
	assert_contextless(PAGE_SIZE != 0 && (PAGE_SIZE & (PAGE_SIZE-1)) == 0)
}
