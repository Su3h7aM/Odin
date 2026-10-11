package test_core_compress

/*
	Copyright 2021 Jeroen van Rijn <nom@duclavier.com>.
	Made available under Odin's license.

	List of contributors:
		Jeroen van Rijn: Initial implementation.

	A test suite for ZLIB, GZIP and Shoco.
*/

import "core:testing"

import "core:compress"
import "core:compress/zlib"
import "core:compress/gzip"
import "core:compress/shoco"
import "core:bytes"
import "core:hash"

@test
zlib_test :: proc(t: ^testing.T) {
	ODIN_DEMO := []u8{
		120, 156, 101, 144,  77, 110, 131,  48,  16, 133, 215, 204,  41, 158,  44,
		 69,  73,  32, 148, 182,  75,  35,  14, 208, 125,  47,  96, 185, 195, 143,
		130,  13,  50,  38,  81,  84, 101, 213,  75, 116, 215,  43, 246,   8,  53,
		 82, 126,   8, 181, 188, 152, 153, 111, 222, 147, 159, 123, 165, 247, 170,
		 98,  24, 213,  88, 162, 198, 244, 157, 243,  16, 186, 115,  44,  75, 227,
		  5,  77, 115,  72, 137, 222, 117, 122, 179, 197,  39,  69, 161, 170, 156,
		 50, 144,   5,  68, 130,   4,  49, 126, 127, 190, 191, 144,  34,  19,  57,
		 69,  74, 235, 209, 140, 173, 242, 157, 155,  54, 158, 115, 162, 168,  12,
		181, 239, 246, 108,  17, 188, 174, 242, 224,  20,  13, 199, 198, 235, 250,
		194, 166, 129,  86,   3,  99, 157, 172,  37, 230,  62,  73, 129, 151, 252,
		 70, 211,   5,  77,  31, 104, 188, 160, 113, 129, 215,  59, 205,  22,  52,
		123, 160,  83, 142, 255, 242,  89, 123,  93, 149, 200,  50, 188,  85,  54,
		252,  18, 248, 192, 238, 228, 235, 198,  86, 224, 118, 224, 176, 113, 166,
		112,  67, 106, 227, 159, 122, 215,  88,  95, 110, 196, 123, 205, 183, 224,
		 98,  53,   8, 104, 213, 234, 201, 147,   7, 248, 192,  14, 170,  29,  25,
		171,  15,  18,  59, 138, 112,  63,  23, 205, 110, 254, 136, 109,  78, 231,
		 63, 234, 138, 133, 204,
	}

	buf: bytes.Buffer
	err := zlib.inflate(ODIN_DEMO, &buf)

	testing.expect(t, err == nil, "ZLIB failed to decompress ODIN_DEMO")
	s := bytes.buffer_to_string(&buf)

	testing.expect(t, s[68] == 240 && s[69] == 159 && s[70] == 152, "ZLIB result should've contained 😃 at position 68.")
	testing.expect(t, len(s) == 438, "ZLIB result has an unexpected length.")
	bytes.buffer_destroy(&buf)
}

@test
gzip_test :: proc(t: ^testing.T) {
	// Small GZIP file with fextra, fname and fcomment present.
	TEST: []u8 = {
		0x1f, 0x8b, 0x08, 0x1c, 0xcb, 0x3b, 0x3a, 0x5a,
		0x02, 0x03, 0x07, 0x00, 0x61, 0x62, 0x03, 0x00,
		0x63, 0x64, 0x65, 0x66, 0x69, 0x6c, 0x65, 0x6e,
		0x61, 0x6d, 0x65, 0x00, 0x54, 0x68, 0x69, 0x73,
		0x20, 0x69, 0x73, 0x20, 0x61, 0x20, 0x63, 0x6f,
		0x6d, 0x6d, 0x65, 0x6e, 0x74, 0x00, 0x2b, 0x48,
		0xac, 0xcc, 0xc9, 0x4f, 0x4c, 0x01, 0x00, 0x15,
		0x6a, 0x2c, 0x42, 0x07, 0x00, 0x00, 0x00,
	}

	buf: bytes.Buffer
	err := gzip.load(TEST, &buf)

	testing.expect(t, err == nil, "GZIP failed to decompress TEST")
	testing.expect(t, bytes.buffer_to_string(&buf) == "payload", "GZIP result wasn't 'payload'")

	bytes.buffer_destroy(&buf)
}

@test
shoco_test :: proc(t: ^testing.T) {

	Shoco_Tests :: []struct{
		compressed:     []u8,
		raw:            []u8,
		short_pack:     int,
		short_sentinel: int,
	}{
		{ #load("../assets/Shoco/README.md.shoco"), #load("../assets/Shoco/README.md"), 10, 1006 },
		{ #load("../assets/Shoco/LICENSE.shoco"),   #load("../assets/Shoco/LICENSE"),   25, 68   },
	}

	for v in Shoco_Tests {
		v := v
		// Compressed source files are not encoded with carriage returns but git replaces raw files lf with crlf on commit (on windows only)
		// So replace crlf with lf on windows
		v.raw, _ = bytes.replace_all(v.raw, { 0xD, 0xA }, { 0xA }, context.temp_allocator)

		expected_raw        := len(v.raw)
		expected_compressed := len(v.compressed)

		biggest_unpacked := shoco.decompress_bound(expected_compressed)
		biggest_packed   := shoco.compress_bound(expected_raw)

		buffer := make([]u8, max(biggest_packed, biggest_unpacked))
		defer delete(buffer)

		size, err := shoco.decompress(v.compressed, buffer[:])
		testing.expectf(t, err == nil, "Expected `decompress` to return `nil`, got %v", err)

		testing.expectf(t, size == expected_raw, "Decompressed %v bytes into %v. Expected to decompress into %v bytes", len(v.compressed), size, expected_raw)
		testing.expect(t, string(buffer[:size]) == string(v.raw), "Decompressed contents don't match")

		size, err = shoco.compress(string(v.raw), buffer[:])
		testing.expect(t, err == nil, "Expected `compress` to return `nil`.")

		testing.expectf(t, size == expected_compressed, "Compressed %v bytes into %v. Expected to compress into %v bytes", expected_raw, size, expected_compressed)

		size, err = shoco.decompress(v.compressed, buffer[:expected_raw - 10])
		testing.expectf(t, err == .Output_Too_Short, "Decompressing into too small a buffer returned %v, expected `.Output_Too_Short`", err)

		size, err = shoco.compress(string(v.raw), buffer[:expected_compressed - 10])
		testing.expectf(t, err == .Output_Too_Short, "Compressing into too small a buffer returned %v, expected `.Output_Too_Short`", err)

		size, err = shoco.decompress(v.compressed[:v.short_pack], buffer[:])
		testing.expectf(t, err == .Stream_Too_Short, "Insufficient data after pack returned %v, expected `.Stream_Too_Short`", err)

		size, err = shoco.decompress(v.compressed[:v.short_sentinel], buffer[:])
		testing.expectf(t, err == .Stream_Too_Short, "No more data after non-ASCII sentinel returned %v, expected `.Stream_Too_Short`", err)
	}
}

// Only the helper-level limit tests can run against the default multi-gigabyte
// COMPRESS_OUTPUT_ALLOCATE_MAX. The tests that allocate up to the maximum skip
// unless the limit was lowered (e.g. -define:COMPRESS_OUTPUT_ALLOCATE_MAX=65536).
ZLIB_LIMIT_TEST_THRESHOLD :: 1 << 20

make_stored_zlib_stream :: proc(payload: []u8, allocator := context.allocator) -> []u8 {
	context.allocator = allocator
	out: [dynamic]u8
	append(&out, 0x78, 0x01)
	offset := 0
	for offset < len(payload) {
		chunk := min(65535, len(payload) - offset)
		if offset + chunk == len(payload) {
			append(&out, u8(1))
		} else {
			append(&out, u8(0))
		}
		append(&out, u8(chunk & 0xff), u8(chunk >> 8))
		nlen := ~u16(chunk)
		append(&out, u8(nlen & 0xff), u8(nlen >> 8))
		append(&out, ..payload[offset:][:chunk])
		offset += chunk
	}
	adler := hash.adler32(payload)
	append(&out, u8(adler >> 24), u8(adler >> 16), u8(adler >> 8), u8(adler))
	return out[:]
}

@test
zlib_grow_buffer_test :: proc(t: ^testing.T) {
	buf: [dynamic]u8
	defer delete(buf)

	err := zlib.grow_buffer(&buf, 300)
	testing.expect(t, err == nil, "grow_buffer failed to grow an empty buffer")
	testing.expect(t, len(buf) >= 300, "grow_buffer did not cover `needed` from an empty buffer")

	_ = resize(&buf, 1)
	err = zlib.grow_buffer(&buf, 300)
	testing.expect(t, err == nil, "grow_buffer failed to grow a tiny buffer")
	testing.expect(t, len(buf) >= 300, "grow_buffer did not cover `needed` from a tiny buffer")

	before := len(buf)
	err = zlib.grow_buffer(&buf, compress.COMPRESS_OUTPUT_ALLOCATE_MAX + 1)
	testing.expect(t, err != nil, "grow_buffer should fail when `needed` exceeds COMPRESS_OUTPUT_ALLOCATE_MAX")
	testing.expect(t, len(buf) == before, "failed grow_buffer must not resize the buffer")
}

@test
zlib_tiny_buffer_backreference_test :: proc(t: ^testing.T) {
	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)

	z := compress.Context_Memory_Input{output = &buf}

	testing.expect(t, zlib.write_byte(&z, 'A') == .None, "write_byte failed on an empty buffer")
	testing.expect(t, zlib.write_byte(&z, 'B') == .None, "write_byte failed on a tiny buffer")
	testing.expect(t, zlib.repl_bytes(&z, 6, 2) == .None, "repl_bytes failed on a tiny buffer")
	testing.expect(t, string(bytes.buffer_to_bytes(&buf)) == "ABABABAB", "backreference copy produced wrong bytes")

	// One call must grow enough for the whole run, not just one doubling.
	testing.expect(t, zlib.repl_byte(&z, 200, 'X') == .None, "repl_byte failed to grow a tiny buffer for the full count")
	testing.expect(t, z.bytes_written == 208, "tiny buffer writes tracked the wrong length")
	testing.expect(t, len(buf.buf) >= 208, "tiny buffer growth did not cover all writes")
	got := bytes.buffer_to_bytes(&buf)
	testing.expect(t, string(got[:8]) == "ABABABAB", "growth clobbered the backreference bytes")
	for b in got[8:] {
		testing.expect(t, b == 'X', "repl_byte wrote wrong bytes after growth")
	}
}

@test
zlib_stored_output_exact_limit_test :: proc(t: ^testing.T) {
	if compress.COMPRESS_OUTPUT_ALLOCATE_MAX > ZLIB_LIMIT_TEST_THRESHOLD {
		return
	}
	payload := make([]u8, compress.COMPRESS_OUTPUT_ALLOCATE_MAX)
	defer delete(payload)
	for _, i in payload {
		payload[i] = u8(i & 0xff)
	}
	stream := make_stored_zlib_stream(payload)
	defer delete(stream)

	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	err := zlib.inflate(stream, &buf)
	testing.expect(t, err == nil, "inflate failed at exactly COMPRESS_OUTPUT_ALLOCATE_MAX bytes")
	testing.expect(t, bytes.buffer_length(&buf) == len(payload), "exact-limit output has the wrong length")
	got := bytes.buffer_to_bytes(&buf)
	testing.expect(t, len(got) == len(payload), "exact-limit output slice has the wrong length")
	for _, i in payload {
		if got[i] != payload[i] {
			testing.expectf(t, false, "exact-limit output differs at byte %v", i)
			break
		}
	}
}

@test
zlib_stored_output_over_limit_test :: proc(t: ^testing.T) {
	if compress.COMPRESS_OUTPUT_ALLOCATE_MAX > ZLIB_LIMIT_TEST_THRESHOLD {
		return
	}
	payload := make([]u8, compress.COMPRESS_OUTPUT_ALLOCATE_MAX + 1)
	defer delete(payload)
	for _, i in payload {
		payload[i] = u8(i & 0xff)
	}
	stream := make_stored_zlib_stream(payload)
	defer delete(stream)

	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	err := zlib.inflate(stream, &buf)
	testing.expect(t, err != nil, "inflate should fail when output exceeds COMPRESS_OUTPUT_ALLOCATE_MAX")
	testing.expect(t, err == compress.General_Error.Output_Too_Short, "over-limit inflate returned the wrong error")
	testing.expect(t, bytes.buffer_length(&buf) <= compress.COMPRESS_OUTPUT_ALLOCATE_MAX, "over-limit inflate grew past the maximum")
	testing.expect(t, len(buf.buf) <= compress.COMPRESS_OUTPUT_ALLOCATE_MAX, "over-limit inflate allocated past the maximum")
}

@test
zlib_writers_refuse_past_limit_test :: proc(t: ^testing.T) {
	if compress.COMPRESS_OUTPUT_ALLOCATE_MAX > ZLIB_LIMIT_TEST_THRESHOLD {
		return
	}
	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	z := compress.Context_Memory_Input{output = &buf}
	_ = resize(&z.output.buf, compress.COMPRESS_OUTPUT_ALLOCATE_MAX)
	z.output.buf[0] = 'A'
	z.output.buf[1] = 'B'
	z.bytes_written = i64(compress.COMPRESS_OUTPUT_ALLOCATE_MAX)

	testing.expect(t, zlib.write_byte(&z, 'C') != .None, "write_byte must fail at the limit")
	testing.expect(t, zlib.repl_byte(&z, 1, 'C') != .None, "repl_byte must fail at the limit")
	testing.expect(t, zlib.repl_bytes(&z, 1, 1) != .None, "repl_bytes must fail at the limit")
	testing.expect(t, z.bytes_written == i64(compress.COMPRESS_OUTPUT_ALLOCATE_MAX), "failed writes must not advance")
	testing.expect(t, len(z.output.buf) == compress.COMPRESS_OUTPUT_ALLOCATE_MAX, "failed writes must not grow past the limit")
}

@test
zlib_initial_allocation_clamp_test :: proc(t: ^testing.T) {
	// Runs against every limit configuration, including the default
	// COMPRESS_OUTPUT_ALLOCATE_MIN (1 MiB) greater than a reduced
	// COMPRESS_OUTPUT_ALLOCATE_MAX (e.g. 65536). A valid short stream must
	// inflate without an explicit expectation, while an explicitly oversized
	// expectation is rejected.
	payload := transmute([]u8)string("clamp-regression-payload")
	stream := make_stored_zlib_stream(payload)
	defer delete(stream)

	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	err := zlib.inflate(stream, &buf)
	testing.expect(t, err == nil, "inflate failed on a valid short stream")
	testing.expect(t, string(bytes.buffer_to_bytes(&buf)) == string(payload), "short stream inflated to the wrong bytes")

	oversized: bytes.Buffer
	defer bytes.buffer_destroy(&oversized)
	err = zlib.inflate(stream, &oversized, expected_output_size = compress.COMPRESS_OUTPUT_ALLOCATE_MAX + 1)
	testing.expect(t, err == compress.General_Error.Output_Too_Short, "oversized expected_output_size returned the wrong error")
}
