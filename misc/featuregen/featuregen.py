import subprocess
import os
import re
import shutil
import sys

# NOTE: the CPU and feature lists are queried from `llc` rather than from
# `odin build -target-features:help`. Both print the same information, but
# `llc` does not depend on the compiler itself starting up, which it cannot
# do when the microarch table in src/build_settings_microarch.cpp is out of
# date for the LLVM version being targeted (it panics with
# "unknown microarch" on the first CPU the old table does not know about).
#
# The default feature set of an individual CPU is still dumped through the
# small C++ helper built by `build_featuregen.sh`, because LLVM offers no C
# or textual API for that.

# (odin arch name, LLVM target triple, llc -march name)
archs = [
	("amd64",     "x86_64-pc-linux-gnu",  "x86",     [], []),
	("i386",      "i386-pc-linux-gnu",    "x86",     [], []),
	("arm32",     "arm-linux-gnu",        "arm",     [], []),
	("arm64",     "aarch64-linux-elf",    "aarch64", [], []),
	("wasm32",    "wasm32-js-js",         "wasm32",  [], []),
	("wasm64p32", "wasm32-js-js",         "wasm32",  [], []),
	("riscv64",   "riscv64-linux-gnu",    "riscv64", [], []),
];

SEEKING_CPUS     = 0
PARSING_CPUS     = 1
PARSING_FEATURES = 2

def llc():
	if os.environ.get("LLC"):
		return os.environ["LLC"]
	llvm_config = shutil.which("llvm-config")
	if llvm_config:
		bindir = subprocess.run([llvm_config, "--bindir"], capture_output=True, text=True)
		if bindir.returncode == 0:
			candidate = os.path.join(bindir.stdout.strip(), "llc")
			if os.path.exists(candidate):
				return candidate
	return "llc"

LLC = llc()
version = subprocess.run([LLC, "--version"], capture_output=True, text=True)
match = re.search(r"LLVM version (\d+)", version.stdout + version.stderr)
if version.returncode != 0 or not match:
	print(f"could not determine LLVM major version from {LLC} --version")
	sys.exit(1)
LLVM_VERSION_MAJOR = int(match.group(1))

for arch, triple, march, cpus, features in archs:
	process = subprocess.Popen([LLC, f"-march={march}", "-mcpu=help"],
	                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

	state = SEEKING_CPUS
	for line in process.stdout:
		if state == SEEKING_CPUS:
			if line.strip() == "Available CPUs for this target:":
				state = PARSING_CPUS

		elif state == PARSING_CPUS:
			if line.strip() == "Available features for this target:":
				state = PARSING_FEATURES
				continue

			parts = line.split(" -", maxsplit=1)
			if len(parts) < 2:
				continue

			cpu = parts[0].strip()
			if cpu:
				cpus.append(cpu)

		elif state == PARSING_FEATURES:
			if line.strip() == "" and len(features) > 0:
				break

			parts = line.split(" -", maxsplit=1)
			if len(parts) < 2:
				continue

			feature = parts[0].strip().lstrip("+")
			if feature:
				features.append(feature)

	process.wait()
	if process.returncode != 0:
		print(f"llc -march={march} -mcpu=help returned with non-zero exit code {process.returncode}")
		sys.exit(1)

def print_default_features(triple, microarch):
	cmd = ["./featuregen", triple, microarch]
	process = subprocess.Popen(cmd, stdout=subprocess.PIPE, text=True)
	first = True
	for line in process.stdout:
		print("" if first else ",", line.strip(), sep="", end="")
		first = False
	process.wait()
	if process.returncode != 0:
		print(f"featuregen returned with non-zero exit code {process.returncode}")
		sys.exit(1)

print(f"// LLVM {LLVM_VERSION_MAJOR}")
print("// Generated with the featuregen script in `misc/featuregen`")
print("gb_global String target_microarch_list[TargetArch_COUNT] = {")
print("\t// TargetArch_Invalid:")
print('\tstr_lit(""),')
for arch, triple, march, cpus, features in archs:
	print(f"\t// TargetArch_{arch}:")
	cpus_str = ','.join(cpus)
	print(f'\tstr_lit("{cpus_str}"),')
print("};")

print("")

print("// Generated with the featuregen script in `misc/featuregen`")
print("gb_global String target_features_list[TargetArch_COUNT] = {")
print("\t// TargetArch_Invalid:")
print('\tstr_lit(""),')
for arch, triple, march, cpus, features in archs:
	print(f"\t// TargetArch_{arch}:")
	features_str = ','.join(features)
	print(f'\tstr_lit("{features_str}"),')
print("};")

print("")

print("// Generated with the featuregen script in `misc/featuregen`")
print("gb_global int target_microarch_counts[TargetArch_COUNT] = {")
print("\t// TargetArch_Invalid:")
print("\t0,")
for arch, triple, march, cpus, feature in archs:
	print(f"\t// TargetArch_{arch}:")
	print(f"\t{len(cpus)},")
print("};")

print("")

print("// Generated with the featuregen script in `misc/featuregen`")
print("gb_global MicroarchFeatureList microarch_features_list[] = {")
for arch, triple, march, cpus, features in archs:
	print(f"\t// TargetArch_{arch}:")
	for cpu in cpus:
		print(f'\t{{ str_lit("{cpu}"), str_lit("', end="")
		print_default_features(triple, cpu)
		print('") },')
print("};")
