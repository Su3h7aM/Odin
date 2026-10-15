#!/usr/bin/env bash
set -eu

if [ "$(uname -s)" != Linux ] || [ "$(uname -m)" != x86_64 ]; then
	echo 'Linux x64 native regressions require a Linux x86_64 host'
	exit 0
fi

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
export ODIN_ROOT="$root"
odin=${ODIN:-$root/odin}
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
mkdir "$out/tmp"
export TMPDIR="$out/tmp"

assert_no_proofs() {
	local remaining
	remaining=$(find "$TMPDIR" -name 'selprove-*' -print)
	if [ -n "$remaining" ]; then
		echo "assembler proofs leaked: $remaining" >&2
		exit 1
	fi
}

assert_native() {
	if readelf -l "$1" | grep -q INTERP || readelf -d "$1" 2>/dev/null | grep -q NEEDED; then
		echo "native executable unexpectedly depends on a loader or shared library: $1" >&2
		exit 1
	fi
}

for optimization in none speed; do
	"$odin" build "$here/fma.odin" -file -out:"$out/fma" -o:"$optimization" -microarch:generic
	assert_native "$out/fma"
	"$out/fma"
	assert_no_proofs
done

"$odin" build "$here/intrinsic_fallback.odin" -file -out:"$out/intrinsic-fallback"
"$out/intrinsic-fallback"
assert_no_proofs

# Managed rechecking must reuse its proof object and remove its directory.
"$odin" build "$here/proof_cleanup.odin" -file -out:"$out/proof-cleanup" -show-system-calls >"$out/build.log" 2>&1
"$out/proof-cleanup"
if [ "$(grep -c 'proof_input.asm" -f' "$out/build.log")" -ne 1 ]; then
	cat "$out/build.log" >&2
	echo 'the managed recheck did not reuse its proof object' >&2
	exit 1
fi
assert_no_proofs

# Check mode also assembles proofs.
"$odin" check "$here/proof_cleanup.odin" -file
assert_no_proofs

echo 'Linux x64 native compiler regressions passed'
