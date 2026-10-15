// Automatic owned-track selection for native-only Linux amd64 programs.
//
// The default build checks with the owned profile first (provisional
// no_crt=true) on a narrow envelope, then classifies the reachable foreign
// graph. Programs whose reachable references all resolve without libc keep
// the owned track with a truthful ODIN_NO_CRT; anything genuinely
// libc-linked falls back to a full managed recheck. Explicit -no-crt keeps
// its strict single-pass behavior and never enters this flow.
//
// Classification is provenance-based, never name-based:
// Every reachable reference resolves only through checkable per-build
// proof, never file membership, prefixes, or text scans:
//   - an actual emitted Odin definition with identical link name and
//     type (emission-guaranteed @(require) definitions count for
//     assembler-declared externs, which carry no Odin type);
//   - an LLVM-recognized scalar intrinsic with an instruction-only
//     lowering, or an actual emitted provider for its possible libcall;
//   - a backend-synthesized runtime stub matching the producer
//     constant and exact stub signature;
//   - a linker-synthesized section bound under the verified owned
//     link plan (known linker, static non-PIE executable);
//   - an assembler input whose authoritative object symbols cover
//     every reachable binding with an owned undefined closure.
// Anything else is an honest candidate gap (owned-pipeline proof
// missing) or opaque external input (e.g. a bare getpid-style
// declaration or an uninspected object); all three non-owned classes
// stay managed with distinct labels, exactly as the ordinary default
// links today.
//   - An explicit libm import (system:m, -lm, -l:libm*, or a libm
//     file) always stays managed: the owned math glue is value-only
//     and provides no errno/fenv contract.
//   - Other user object files stay managed as not-yet-proven; explicit
//     -no-crt remains available for freestanding archives.
// A library whose every reachable reference resolves owned is marked
// EntityFlag_OwnedSatisfied so the backend does not pass it to the linker;
// the linker's own undefined-symbol errors remain the backstop, never a
// silent success.

gb_internal bool auto_owned_envelope_eligible() {
	if (build_context.explicit_no_crt) {
		return false;
	}
	// Only real program builds enter the flow: documentation, semicolon
	// stripping, and other tooling are not generated Linux executables
	// even when their build mode defaults to Executable.
	if ((build_context.command_kind & (Command_build|Command_run|Command_test|Command_check)) == 0) {
		return false;
	}
	// NOTE: build_context.metrics is not derived until init_build_context,
	// which runs after this gate, so read the selected target (or the
	// compiler host when targeting it) instead. The finalize step
	// re-verifies against the derived metrics before committing.
	if (selected_target_metrics != nullptr) {
		if (selected_target_metrics->metrics->os != TargetOs_linux ||
		    selected_target_metrics->metrics->arch != TargetArch_amd64) {
			return false;
		}
	} else {
#if defined(GB_SYSTEM_LINUX) && defined(__x86_64__)
		// Targeting the host compiler's own platform.
#else
		return false;
#endif
	}
	if (selected_subtarget == Subtarget_Android) {
		return false;
	}
	if (build_context.build_mode != BuildMode_Executable) {
		return false;
	}
	if (build_context.no_entry_point) {
		return false;
	}
	if (build_context.sanitizer_flags != 0) {
		return false;
	}
	if (build_context.reloc_mode != RelocMode_Default) {
		return false;
	}
	// Mirror the strict envelope checks (build_settings no_crt section) as
	// silent gates: default-heap without thread-local storage is rejected
	// there even on Linux, so it stays single-run managed rather than
	// erroring before any fallback could run. Nil/panic allocators and all
	// thread-local modes keep their existing capabilities.
	if (!build_context.ODIN_DEFAULT_TO_NIL_ALLOCATOR &&
	    !build_context.ODIN_DEFAULT_TO_PANIC_ALLOCATOR &&
	    build_context.no_thread_local) {
		return false;
	}
	return true;
}

// Owned-tree provenance: declarations from files Odin itself ships under
// base/ or core/ (never vendor/ or user collections). Scope only, never
// a verdict: it labels where an unproven reference comes from
// (candidate gap for shipped files, opaque input otherwise) and bounds
// the linker-synthesis contract to the shipped lifecycle that documents
// it. Nothing is owned by membership.
struct OwnedTree {
	String base_prefix;
	String core_prefix;
};

gb_internal OwnedTree owned_tree_prefixes() {
	OwnedTree t = {};
	if (build_context.ODIN_ROOT.len == 0) {
		return t;
	}
	String root = build_context.ODIN_ROOT;
	while (root.len > 0 && root[root.len-1] == '/') {
		root = substring(root, 0, root.len-1);
	}
	t.base_prefix = concatenate3_strings(permanent_allocator(), root, str_lit("/base/"), str_lit(""));
	t.core_prefix = concatenate3_strings(permanent_allocator(), root, str_lit("/core/"), str_lit(""));
	return t;
}

gb_internal bool file_in_owned_tree(OwnedTree const &tree, String fullpath) {
	if (fullpath.len == 0) {
		return false;
	}
	return (tree.base_prefix.len != 0 && string_starts_with(fullpath, tree.base_prefix)) ||
	       (tree.core_prefix.len != 0 && string_starts_with(fullpath, tree.core_prefix));
}

gb_internal bool entity_in_owned_tree(OwnedTree const &tree, Entity *e) {
	return e != nullptr && e->file != nullptr && file_in_owned_tree(tree, e->file->fullpath);
}

gb_internal bool filepath_denotes_system_c_lib(String path) {
	String base = filename_without_directory(path);
	// An explicit C runtime library file stays managed for its
	// errno/fenv/threading contract even when the owned link would
	// close identically without it.
	if (base == str_lit("libm") || base == str_lit("libc") ||
	    base == str_lit("libpthread") || base == str_lit("libpthreads") ||
	    base == str_lit("libdl") || base == str_lit("librt")) {
		return true;
	}
	return string_starts_with(base, str_lit("libm.")) || string_starts_with(base, str_lit("libc.")) ||
	       string_starts_with(base, str_lit("libpthread.")) || string_starts_with(base, str_lit("libpthreads.")) ||
	       string_starts_with(base, str_lit("libdl.")) || string_starts_with(base, str_lit("librt."));
}

// Three attribution classes, all reported through the verbose channel.
// Four attribution classes, all reported per reference through the
// verbose channel. Owned keeps the owned track; VerifiedC, OpaqueInput,
// and CandidateGap all fall back to managed with distinct labels, so a
// gap in our own proof is never misreported as established libc or as
// untrusted external input, and a link failure is never completion.
enum AutoEdgeClass {
	AutoEdge_Owned,
	AutoEdge_Real,
	AutoEdge_Opaque,
	AutoEdge_Gap,
};

struct SelAsmSyms {
	Array<String> supplies;        // global/weak defined names (any type/visibility, incl ABS/COMMON)
	Array<u8>     supply_strong;   // parallel: 1 when STB_GLOBAL (strong), 0 when STB_WEAK
	Array<String> needs;           // STB_GLOBAL undefined names requiring closure (weak-undef stays satisfiable-absent)
};

struct SelStrongSupply {
	String name;
	String input;
};

struct SelProvenAsm {
	String input;
	SelAsmSyms syms;
	String obj_path;
};

struct AutoCtx {
	Checker *c;
	OwnedTree tree;
	int owned_edges;
	int real_edges;
	int opaque_edges;
	int gap_edges;
	// Assembler proofs completed in this classification, keyed by
	// canonical input (same input twice reuses one proof), plus every
	// strong supply seen with its input for duplicate detection.
	Array<SelProvenAsm> asm_proven;
	Array<SelStrongSupply> asm_strong;
};

struct BoundRef {
	Entity *entity;
	Entity *lib;
};

gb_internal void auto_count_edge(AutoCtx *ctx, AutoEdgeClass cls) {
	switch (cls) {
	case AutoEdge_Owned:  ctx->owned_edges  += 1; break;
	case AutoEdge_Real:   ctx->real_edges   += 1; break;
	case AutoEdge_Opaque: ctx->opaque_edges += 1; break;
	case AutoEdge_Gap:    ctx->gap_edges    += 1; break;
	}
}

// Determinism ledger: every classified reference is reported with its
// link name, origin, and verdict, so a flapping verdict across
// identical builds is attributable to an exact reference.
gb_internal void auto_ledger(AutoCtx *ctx, AutoEdgeClass cls, char const *kind, String name, String origin) {
	char const *label = "owned";
	if (cls == AutoEdge_Real) {
		label = "verified-c";
	} else if (cls == AutoEdge_Opaque) {
		label = "opaque-input";
	} else if (cls == AutoEdge_Gap) {
		label = "candidate-gap";
	}
	debugf("owned-first selection: %s %s %.*s via %.*s\n", label, kind, LIT(name), LIT(origin));
}

// Classifies one linker token from user-supplied flags. Policy flags
// (-static, -L, -rpath, ...) are never C requirements; an explicit
// system library request (-lc/-lm/-lpthread/-ldl, -pthread, -l:libm*,
// -Wl,-lc, ...) is verified C even when the owned link would close
// identically, because libm carries errno/fenv semantics the owned
// provider does not; object and archive inputs are opaque-conservative
// (they may be freestanding, so they are never mislabeled verified C).
// Anything unrecognized is policy-neutral: it behaves identically in
// both tracks or fails loudly in both, so it cannot change the decision.
gb_internal bool linker_token_names_system_c_lib(String name) {
	// Exact -lX names (-lc, -lm, -lpthread, -lpthreads, -ldl, -lrt).
	if (name == str_lit("c") || name == str_lit("m") ||
	    name == str_lit("pthread") || name == str_lit("pthreads") ||
	    name == str_lit("dl") || name == str_lit("rt")) {
		return true;
	}
	// Exact -l:filename forms (-l:libm.a, -l:libc, ...).
	if (name == str_lit("libc") || name == str_lit("libm") ||
	    name == str_lit("libpthread") || name == str_lit("libpthreads") ||
	    name == str_lit("libdl") || name == str_lit("librt")) {
		return true;
	}
	// Suffixed -l:filename forms (-l:libm.so.6, -l:libpthread.a, ...).
	if (string_starts_with(name, str_lit("libc.")) || string_starts_with(name, str_lit("libm.")) ||
	    string_starts_with(name, str_lit("libpthread.")) || string_starts_with(name, str_lit("libpthreads.")) ||
	    string_starts_with(name, str_lit("libdl.")) || string_starts_with(name, str_lit("librt."))) {
		return true;
	}
	return false;
}

gb_internal bool linker_token_is_policy(String tok) {
	// NOTE: output-mode changers (-static, -shared, -pie, -no-pie, -r,
	// --relocatable) are deliberately NOT listed here. They go opaque in
	// classify_linker_token before this policy check runs: they change
	// the output mode the init-bounds contract was gated on.
	if (tok == str_lit("-s") || tok == str_lit("-o") ||
	    tok == str_lit("--gc-sections") || tok == str_lit("--no-gc-sections") ||
	    tok == str_lit("--as-needed") || tok == str_lit("--no-as-needed") ||
	    tok == str_lit("--eh-frame-hdr") || tok == str_lit("--export-dynamic") ||
	    tok == str_lit("--fatal-warnings") || tok == str_lit("--no-fatal-warnings") ||
	    tok == str_lit("--discard-all") || tok == str_lit("--discard-locals") ||
	    tok == str_lit("--strip-debug") || tok == str_lit("--strip-all") ||
	    tok == str_lit("--emit-relocs") ||
	    tok == str_lit("--nmagic") || tok == str_lit("--omagic") ||
	    tok == str_lit("--start-group") || tok == str_lit("--end-group") ||
	    tok == str_lit("--whole-archive") || tok == str_lit("--no-whole-archive") ||
	    tok == str_lit("-e") || tok == str_lit("--entry") ||
	    tok == str_lit("-u") || tok == str_lit("--undefined") ||
	    tok == str_lit("-t") || tok == str_lit("--trace") ||
	    tok == str_lit("-v") || tok == str_lit("--verbose")) {
		return true;
	}
	// NOTE: only explicit proven forms here. The old broad -B and -m
	// prefixes are gone: -B reselects toolchain binaries or toggles
	// link mode (-Bstatic/-Bdynamic/-Bsymbolic), and -m selects
	// architecture multilibs (-m32/-m64); none of them is harmless by
	// prefix. The proven survivors are -mllvm (same-backend option
	// passthrough, no inputs, no mode change) and -M (output-only map
	// forms, covering -Map). Search path, output, and map operands
	// (-L, -o, -Map, -rpath, -soname, -z) are consumed whole before
	// classification and remain normal.
	if (string_starts_with(tok, str_lit("-O")) || string_starts_with(tok, str_lit("-L")) ||
	    string_starts_with(tok, str_lit("-rpath")) || string_starts_with(tok, str_lit("-soname")) ||
	    string_starts_with(tok, str_lit("-z")) || string_starts_with(tok, str_lit("-mllvm")) ||
	    string_starts_with(tok, str_lit("-M")) ||
	    string_starts_with(tok, str_lit("--version-script")) || string_starts_with(tok, str_lit("--trace-symbol")) ||
	    string_starts_with(tok, str_lit("--no-relax")) ||
	    string_starts_with(tok, str_lit("--relax"))) {
		return true;
	}
	return false;
}

gb_internal bool linker_token_takes_separate_arg(String tok) {
	// Options that certainly consume the next token as their argument
	// at driver level (library name, search directory, script file,
	// entry symbol, pulled symbol, output file, map file, LLVM option).
	// Runpath/soname take harmless string operands and -z takes a
	// harmless keyword operand, so they consume too; their flag token
	// itself still classifies through the policy check below.
	// Only certain cases:
	// anything uncertain classifies its neighbor on the merits, which
	// can only over-approximate toward managed, never toward owned.
	return tok == str_lit("-l") || tok == str_lit("--library") ||
	       tok == str_lit("-L") || tok == str_lit("-T") || tok == str_lit("-e") ||
	       tok == str_lit("-u") || tok == str_lit("-o") ||
	       tok == str_lit("-Map") || tok == str_lit("-mllvm") ||
	       tok == str_lit("-rpath") || tok == str_lit("-soname") || tok == str_lit("-z");
}

gb_internal AutoEdgeClass classify_linker_token(String tok) {
	if (tok.len == 0) {
		return AutoEdge_Owned;
	}
	// Thread flags request the C threading library however spelled.
	if (tok == str_lit("-pthread") || tok == str_lit("-pthreads") || tok == str_lit("--pthread")) {
		return AutoEdge_Real;
	}
	if (tok[0] == '-') {
		if (tok.len > 2 && tok[1] == 'l') {
			String name = substring(tok, 2, tok.len);
			if (name.len > 0 && name[0] == ':') {
				name = substring(name, 1, name.len);
			}
			if (linker_token_names_system_c_lib(name)) {
				return AutoEdge_Real;
			}
			return AutoEdge_Opaque;
		}
		if (string_starts_with(tok, str_lit("--library="))) {
			// Forwarded or direct long library form; same bounds
			// discipline as the driver-level split (see above).
			String name = {};
			if (tok.len > 10) {
				name = substring(tok, 10, tok.len);
			}
			if (name.len > 0 && linker_token_names_system_c_lib(name)) {
				return AutoEdge_Real;
			}
			return AutoEdge_Opaque;
		}
		// Mode, tool, and provider changes void the producer contract
		// the owned verdicts assume (default driver, default output
		// mode, init bounds synthesized for the selected linker). They
		// go opaque here, before any harmless-policy carve-out, even
		// when spelled without a file operand: -fuse-ld= and -B/prefix
		// reselect the toolchain binaries, --plugin= loads uninspected
		// code into the link, and -shared/-pie/-static/-r/--relocatable
		// change the output mode the init-bounds contract was gated on
		// (--relocatable voids the ET_EXEC bounds outright). A -fuse-ld
		// name is only harmless when it names the already-selected
		// producer, read from the actual build context; paths,
		// unrecognized names, and the toolchain-default linker's real
		// name (unprovable here) stay opaque. Separate-form operands of
		// these flags classify as bare positionals, which are opaque.
		if (tok == str_lit("-shared") || tok == str_lit("-pie") || tok == str_lit("-no-pie") ||
		    tok == str_lit("-nopie") || tok == str_lit("-static") || tok == str_lit("-static-pie") ||
		    tok == str_lit("-r") || tok == str_lit("--relocatable") ||
		    tok == str_lit("--plugin") || string_starts_with(tok, str_lit("--plugin=")) ||
		    tok == str_lit("-fuse-ld") ||
		    tok == str_lit("--ld-path") || string_starts_with(tok, str_lit("--ld-path=")) ||
		    string_starts_with(tok, str_lit("-B"))) {
			return AutoEdge_Opaque;
		}
		if (string_starts_with(tok, str_lit("-fuse-ld="))) {
			// "-fuse-ld=" is 9 characters; an empty name is opaque,
			// never a crash.
			String name = {};
			if (tok.len > 9) {
				name = substring(tok, 9, tok.len);
			}
			if (name.len > 0 && ((build_context.linker_choice == Linker_lld && name == str_lit("lld")) ||
			                    (build_context.linker_choice == Linker_mold && name == str_lit("mold")))) {
				return AutoEdge_Owned;
			}
			return AutoEdge_Opaque;
		}
		// Link-plan overrides void the toolchain contracts the owned
		// verdicts rely on (script replaces synthesis, entry/defsym
		// rewire or inject definitions). They are uninspected external
		// inputs: honest opaque, never neutral, never verified C.
		// Joined, split, and equal spellings count alike: no arbitrary
		// prefix is trusted, but every plan-altering spelling is
		// caught, single-dash and double-dash alike (-defsym= as well
		// as --defsym=, joined -Rfile/-dTfile as well as split).
		// Only exact known-harmless options escape the -e* branch
		// (-export-dynamic, -eh-frame-hdr, -end-group); any other -e
		// prefix is an entry name or unknown plan input, never proof.
		// Capital -E never reaches the -e branch ('E' != 'e').
		// The MRI -c flag reads a command file, so the flag itself is
		// opaque without depending on what its filename argument does;
		// joined -cfile counts like split, and -config counts too (a
		// config file can inject plan-altering flags, so opaque is its
		// sound side). Double-dash --c* long options never reach the
		// single-dash -c branch.
		bool joined_T = tok.len > 2 && tok[0] == '-' && tok[1] == 'T';
		bool joined_e = tok.len > 2 && tok[0] == '-' && tok[1] == 'e' &&
			tok != str_lit("-export-dynamic") && tok != str_lit("-eh-frame-hdr") && tok != str_lit("-end-group");
		bool joined_R = tok.len > 2 && tok[0] == '-' && tok[1] == 'R';
		bool joined_dT = tok.len > 3 && tok[0] == '-' && tok[1] == 'd' && tok[2] == 'T';
		bool joined_c = tok.len > 2 && tok[0] == '-' && tok[1] == 'c';
		if (tok == str_lit("-T") || joined_T ||
		    tok == str_lit("--script") || string_starts_with(tok, str_lit("--script=")) ||
		    tok == str_lit("-e") || joined_e ||
		    tok == str_lit("--entry") || string_starts_with(tok, str_lit("--entry=")) ||
		    tok == str_lit("--defsym") || tok == str_lit("-defsym") ||
		    string_starts_with(tok, str_lit("--defsym=")) || string_starts_with(tok, str_lit("-defsym=")) ||
		    tok == str_lit("--dynamic-linker") || string_starts_with(tok, str_lit("--dynamic-linker=")) ||
		    tok == str_lit("--default-script") || string_starts_with(tok, str_lit("--default-script=")) || tok == str_lit("-dT") || joined_dT ||
		    tok == str_lit("--mri-script") || string_starts_with(tok, str_lit("--mri-script=")) ||
		    tok == str_lit("-c") || joined_c ||
		    tok == str_lit("-R") || joined_R || tok == str_lit("--just-symbols") || string_starts_with(tok, str_lit("--just-symbols=")) ||
		    tok == str_lit("--section-start") || string_starts_with(tok, str_lit("--section-start="))) {
			return AutoEdge_Opaque;
		}
		if (string_starts_with(tok, str_lit("-Wl,"))) {
			// Recursively classify each forwarded element: C libraries
			// (-lc), thread flags (-pthread), and object inputs hide
			// in comma-joined lists. The worst element decides.
			AutoEdgeClass worst = AutoEdge_Owned;
			String rest = substring(tok, 4, tok.len);
			isize start = 0;
			for (isize i = 0; i <= rest.len; i++) {
				if (i == rest.len || rest[i] == ',') {
					String elem = substring(rest, start, i);
					start = i+1;
					AutoEdgeClass cls = classify_linker_token(elem);
					if (cls > worst) {
						worst = cls;
					}
				}
			}
			return worst;
		}
		if (linker_token_is_policy(tok)) {
			return AutoEdge_Owned;
		}
		// Total classification: owned only by positive known contract
		// above (thread flags, C libraries, proven policy). Any unrecognized option
		// is opaque, never owned by default: arbitrary trust is not
		// producer proof. No bans and no backend translation happen
		// here; opaque simply selects the managed track.
		return AutoEdge_Opaque;
	}
	// Response files carry uninspected inputs and overrides.
	if (tok.len > 0 && tok[0] == '@') {
		return AutoEdge_Opaque;
	}
	// Explicit C runtime library files stay managed for their contract
	// even when named by absolute path; the extension block below must
	// not claim them as opaque objects first.
	if (filepath_denotes_system_c_lib(tok)) {
		return AutoEdge_Real;
	}
	if (has_asm_extension(tok) || string_ends_with(tok, str_lit(".o")) ||
	    string_ends_with(tok, str_lit(".obj")) || string_ends_with(tok, str_lit(".a")) ||
	    string_ends_with(tok, str_lit(".lib")) || string_ends_with(tok, str_lit(".so")) ||
	    string_ends_with(tok, str_lit(".dylib")) || string_ends_with(tok, str_lit(".dll")) ||
	    string_contains_string(tok, str_lit(".so."))) {
		return AutoEdge_Opaque;
	}
	// A bare token naming an existing file is a positional linker
	// input: it may be a script or object without a telling suffix,
	// so it is uninspected external input. A bare token is a
	// positional linker input whether or not it names a file that
	// exists in the build directory right now: the real linker also
	// searches -L directories, and the filesystem can change between
	// classification and link. Missing here proves nothing about
	// whether the link will fail. Known option operands are consumed
	// before this point, so whatever arrives here unclaimed is
	// external to the inspected program: honestly opaque, never
	// neutral.
	return AutoEdge_Opaque;
}

// Scans user-supplied extra linker flags with the platform's actual
// argument decoding, so the classifier observes exactly the argv the
// spawned linker driver will observe. Unix reuses the spawner's own
// decoder by construction (no shell single quotes or escapes exist at
// that layer); Windows splits conservatively and treats any
// quote-bearing token as opaque input rather than decoding
// CreateProcess quoting here. Split `-l name` / `--library name`
// forms are rejoined before classification. Returns the worst class.
gb_internal AutoEdgeClass classify_linker_flags(String flags) {
	AutoEdgeClass worst = AutoEdge_Owned;
	// Two-level consumption mirroring the clang driver. Driver level:
	// -Wl, tokens forward their comma elements to the linker, while
	// options taking separate arguments consume the next token whole,
	// even when it looks like -Wl,... (raw `-l -Wl,c` feeds the name
	// "-Wl,c" to -l; splicing it would invent a fake `-l c`). Linker
	// level: one pending state consumes the resulting stream, so split
	// forms match whether they arrive bare, after a comma, or across
	// tokens. Anything dangling, short, or empty fails to opaque, never
	// crashes and never silently owned. Unknown or ambiguous driver
	// consumption is honestly opaque.
	Array<String> argv = array_make<String>(temporary_allocator(), 0, 16);
#if defined(GB_SYSTEM_OSX) || defined(GB_SYSTEM_UNIX)
	// The spawner's own decoder: quote and separator semantics match
	// the spawned linker driver by construction.
	char *c_flags = alloc_cstring(temporary_allocator(), flags);
	int argc = 0;
	char **c_argv = command_line_to_spawn_argv(c_flags, &argc);
	for (int a = 0; a < argc; a++) {
		array_add(&argv, make_string_c(c_argv[a]));
	}
#else
	// Windows: the child CRT decodes raw CreateProcess quoting, which
	// this layer does not reimplement. Split conservatively on
	// whitespace; any quote-bearing element is uninspected external
	// input rather than a decoded token. Unquoted elements consume
	// normally, so ordinary verdicts are unchanged.
	isize i = 0;
	while (i < flags.len) {
		while (i < flags.len && (flags[i] == ' ' || flags[i] == '\t' || flags[i] == '\r' || flags[i] == '\n')) {
			i += 1;
		}
		if (i >= flags.len) {
			break;
		}
		isize start = i;
		while (i < flags.len && flags[i] != ' ' && flags[i] != '\t' && flags[i] != '\r' && flags[i] != '\n') {
			i += 1;
		}
		String tok = substring(flags, start, i);
		bool quoted = false;
		for (isize k = 0; k < tok.len; k++) {
			if (tok[k] == '"') {
				quoted = true;
				break;
			}
		}
		if (quoted) {
			// Cannot decode faithfully; keep it whole so the token
			// layer below labels it opaque by its quote mark.
			array_add(&argv, tok);
			continue;
		}
		array_add(&argv, tok);
	}
#endif
	auto feed_linker_elem = [&](String tok) {
		AutoEdgeClass cls = classify_linker_token(tok);
		if (cls > worst) {
			worst = cls;
		}
	};
	bool skip_next = false;
	// Pending provenance: a driver-level -l consumes the next token
	// whole as its argument (raw `-l -Wl,c` names the library "-Wl,c";
	// splicing it would invent a fake `-l c`). A linker-level -l from
	// inside a genuine -Wl, group instead continues through the next
	// forwarded group (`-Wl,-l -Wl,c` is really `-l c`). Either pending
	// consumes a following name identically; they differ only in what
	// a following -Wl, token means.
	bool pending_driver_l = false;
	bool pending_linker_l = false;
	auto feed_driver_tok = [&](String tok, bool *skip) {
		// A surviving double quote means the platform decoder left it
		// literal (Windows conservative split): uninspected input.
		for (isize q = 0; q < tok.len; q++) {
			if (tok[q] == '"') {
				if (AutoEdge_Opaque > worst) {
					worst = AutoEdge_Opaque;
				}
				pending_driver_l = false;
				pending_linker_l = false;
				return;
			}
		}
		if (pending_driver_l || pending_linker_l) {
			pending_driver_l = false;
			pending_linker_l = false;
			if (linker_token_names_system_c_lib(tok)) {
				if (AutoEdge_Real > worst) {
					worst = AutoEdge_Real;
				}
			} else if (AutoEdge_Opaque > worst) {
				worst = AutoEdge_Opaque;
			}
			return;
		}
		if (tok == str_lit("-l") || tok == str_lit("--library")) {
			pending_driver_l = true;
			return;
		}
		if (string_starts_with(tok, str_lit("--library="))) {
			// "--library=" is 10 characters; anything shorter cannot
			// reach here, and an empty name is opaque, never a crash.
			String name = {};
			if (tok.len > 10) {
				name = substring(tok, 10, tok.len);
			}
			if (name.len > 0 && linker_token_names_system_c_lib(name)) {
				if (AutoEdge_Real > worst) {
					worst = AutoEdge_Real;
				}
			} else if (AutoEdge_Opaque > worst) {
				worst = AutoEdge_Opaque;
			}
			return;
		}
		// Options taking separate arguments consume the next token
		// whole at driver level; it never splices or classifies.
		if (linker_token_takes_separate_arg(tok)) {
			// The flag itself classifies below (plan overrides go
			// opaque there); its argument is consumed whole. A
			// missing argument is a loud driver error in both tracks.
			feed_linker_elem(tok);
			*skip = true;
			return;
		}
		feed_linker_elem(tok);
	};
	for (isize a = 0; a < argv.count; a++) {
		String tok = argv[a];
		if (skip_next) {
			skip_next = false;
			continue;
		}
		// Forwarding options splice their comma elements into the
		// linker stream, unless driver-level -l claimed this token as
		// its whole argument first.
		if (!pending_driver_l && string_starts_with(tok, str_lit("-Wl,"))) {
			String rest = substring(tok, 4, tok.len);
			isize start = 0;
			for (isize k = 0; k <= rest.len; k++) {
				if (k == rest.len || rest[k] == ',') {
					String elem = substring(rest, start, k);
					start = k+1;
					// Linker-level elements share the pending state
					// with the surrounding stream.
					if (pending_linker_l) {
						pending_linker_l = false;
						if (linker_token_names_system_c_lib(elem)) {
							if (AutoEdge_Real > worst) {
								worst = AutoEdge_Real;
							}
						} else if (AutoEdge_Opaque > worst) {
							worst = AutoEdge_Opaque;
						}
					} else if (elem == str_lit("-l") || elem == str_lit("--library")) {
						pending_linker_l = true;
					} else {
						feed_linker_elem(elem);
					}
				}
			}
			continue;
		}
		feed_driver_tok(tok, &skip_next);
	}
	if ((pending_driver_l || pending_linker_l) && AutoEdge_Opaque > worst) {
		worst = AutoEdge_Opaque;
	}
	return worst;
}

// An actual emitted Odin definition with identical link name and type
// satisfies a blank foreign reference in-owned. The definition must
// already be emission-guaranteed (min_dep rooted); rooting on demand is
// future work, so an otherwise matching but unemitted definition stays
// managed, exactly as today.
gb_internal bool emitted_def_matches_foreign(Checker *c, EntityKind kind, String link_name, Type *type) {
	if (link_name.len == 0 || type == nullptr) {
		return false;
	}
	for (Entity *d : c->info.entities) {
		if (d->kind != kind) {
			continue;
		}
		bool d_foreign = false;
		String dl = {};
		if (kind == Entity_Procedure) {
			d_foreign = d->Procedure.is_foreign;
			dl = d->Procedure.link_name;
		} else if (kind == Entity_Variable) {
			d_foreign = d->Variable.is_foreign;
			dl = d->Variable.link_name;
		} else {
			continue;
		}
		if (d_foreign || dl != link_name) {
			continue;
		}
		if (!are_types_identical(d->type, type)) {
			continue;
		}
		if (d->min_dep_count.load(std::memory_order_relaxed) <= 0) {
			continue;
		}
		return true;
	}
	return false;
}

// Intrinsic recognition does not prove a libc-free lowering (e.g. exp2).
gb_internal AutoEdgeClass classify_llvm_intrinsic(AutoCtx *ctx, String name) {
	char const *c_name = alloc_cstring(temporary_allocator(), name);
	if (LLVMLookupIntrinsicID(c_name, cast(size_t)name.len) == 0) {
		return AutoEdge_Gap;
	}
	if (string_starts_with(name, str_lit("llvm.x86."))) {
		// ISA intrinsics select instructions or fail codegen, not C providers.
		return AutoEdge_Owned;
	}
	if (name == str_lit("llvm.trap") || name == str_lit("llvm.debugtrap") ||
	    name == str_lit("llvm.readcyclecounter") || name == str_lit("llvm.readsteadycounter") ||
	    name == str_lit("llvm.assume") || name == str_lit("llvm.prefetch.p0") ||
	    name == str_lit("llvm.lifetime.start.p0") || name == str_lit("llvm.lifetime.end.p0")) {
		return AutoEdge_Owned;
	}
	if (name == str_lit("llvm.sqrt.f32") || name == str_lit("llvm.sqrt.f64") ||
	    name == str_lit("llvm.fabs.f32") || name == str_lit("llvm.fabs.f64") ||
	    name == str_lit("llvm.copysign.f32") || name == str_lit("llvm.copysign.f64")) {
		// SSE2 square root and bit operations on the native amd64 baseline.
		return AutoEdge_Owned;
	}
	struct MathLowering {
		String intrinsic;
		String libcall;
		isize arity;
	};
	MathLowering const lowerings[] = {
		{str_lit("llvm.sin"),     str_lit("sin"), 1},
		{str_lit("llvm.cos"),     str_lit("cos"), 1},
		{str_lit("llvm.exp"),     str_lit("exp"), 1},
		{str_lit("llvm.pow"),     str_lit("pow"), 2},
		{str_lit("llvm.fma"),     str_lit("fma"), 3},
		{str_lit("llvm.fmuladd"), str_lit("fma"), 3},
		{str_lit("llvm.ceil"),    str_lit("ceil"), 1},
		{str_lit("llvm.floor"),   str_lit("floor"), 1},
		{str_lit("llvm.trunc"),   str_lit("trunc"), 1},
		{str_lit("llvm.nearbyint"), str_lit("nearbyint"), 1},
	};
	Type *const float_types[] = {t_f32, t_f64};
	for (MathLowering const &lowering : lowerings) {
		for (Type *float_type : float_types) {
			bool is_f32 = float_type == t_f32;
			String intrinsic = concatenate_strings(temporary_allocator(), lowering.intrinsic,
			                                       is_f32 ? str_lit(".f32") : str_lit(".f64"));
			if (name != intrinsic) {
				continue;
			}
			String libcall = is_f32 ? concatenate_strings(temporary_allocator(), lowering.libcall, str_lit("f")) : lowering.libcall;
			Type *params = alloc_type_tuple();
			slice_init(&params->Tuple.variables, permanent_allocator(), lowering.arity);
			for (isize i = 0; i < lowering.arity; i++) {
				params->Tuple.variables[i] = alloc_entity_param(nullptr, blank_token, float_type, false, true);
			}
			Type *results = alloc_type_tuple();
			slice_init(&results->Tuple.variables, permanent_allocator(), 1);
			results->Tuple.variables[0] = alloc_entity_param(nullptr, blank_token, float_type, false, true);
			Type *type = alloc_type_proc(nullptr, params, lowering.arity, results, 1, false, ProcCC_CDecl);
			return emitted_def_matches_foreign(ctx->c, Entity_Procedure, libcall, type) ? AutoEdge_Owned : AutoEdge_Gap;
		}
	}
	return AutoEdge_Gap;
}

// Classifies one reachable blank foreign reference (no library).
gb_internal AutoEdgeClass classify_blank_edge(AutoCtx *ctx, Entity *e, String link_name, Type *type) {
	if (link_name.len != 0 && string_starts_with(link_name, str_lit("llvm."))) {
		return classify_llvm_intrinsic(ctx, link_name);
	}
	// Backend-synthesized runtime stubs have no checked entity to match:
	// the backend unconditionally generates them in every codegen run.
	// The contract is anchored to the producer constants and the exact
	// stub signature they generate, independent of which file declares
	// the reference. Origin only labels an unproven use below: a
	// mismatched producer name in shipped files is a gap in our case,
	// anywhere else it is opaque external input. This is a backend
	// contract, not a prefix or a symbol list.
	if (link_name.len != 0 &&
	    (link_name == str_lit(LB_STARTUP_RUNTIME_PROC_NAME) ||
	     link_name == str_lit(LB_CLEANUP_RUNTIME_PROC_NAME))) {
		if (e->kind == Entity_Procedure && type != nullptr) {
			Type *stub_type = alloc_type_proc(nullptr, nullptr, 0, nullptr, 0, false, ProcCC_Odin);
			if (are_types_identical(type, stub_type)) {
				return AutoEdge_Owned;
			}
		}
		if (entity_in_owned_tree(ctx->tree, e)) {
			return AutoEdge_Gap;
		}
		return AutoEdge_Opaque;
	}
	if (link_name.len != 0 && entity_in_owned_tree(ctx->tree, e)) {
		// Linker-synthesized section bounds under the owned link plan
		// (clang driver, -nostdlib, static non-PIE): the toolchain
		// materializes these addresses on reference, as the shipped
		// lifecycle documents. The predicate lives with the link plan;
		// shipped scope keeps user declarations from claiming it.
		if (e->kind == Entity_Variable && owned_link_synthesizes_init_array_bounds(link_name)) {
			return AutoEdge_Owned;
		}
		// Anything else declared in shipped files without proof is a
		// gap in our case, not established libc and not user input.
		if (emitted_def_matches_foreign(ctx->c, e->kind, link_name, type)) {
			return AutoEdge_Owned;
		}
		return AutoEdge_Gap;
	}
	if (emitted_def_matches_foreign(ctx->c, e->kind, link_name, type)) {
		// A bare reference matched to an actual emitted Odin
		// implementation with identical link name and type, e.g. a
		// libc-declared atexit bound to the owned registry. A mismatch,
		// or a match without emission, stays conservative below.
		return AutoEdge_Owned;
	}
	return AutoEdge_Opaque;
}

// Bounded validated ELF64 little-endian relocatable reader for assembler
// proof. It is the portable primary: the compiler builds on hosts
// without ELF headers or LLVM C++ object APIs, so the few structures
// below are decoded explicitly and every offset, size, and count is
// bounds-checked against the file size with overflow guards. Anything
// malformed, non-ELF64LE, non-relocatable, or non-x86-64 fails closed
// to a proof gap, never to owned.
gb_internal u16 sel_rd16(u8 const *p) { return cast(u16)(cast(u16)p[0] | (cast(u16)p[1] << 8)); }
gb_internal u32 sel_rd32(u8 const *p) { return cast(u32)p[0] | (cast(u32)p[1] << 8) | (cast(u32)p[2] << 16) | (cast(u32)p[3] << 24); }
gb_internal u64 sel_rd64(u8 const *p) { return cast(u64)sel_rd32(p) | (cast(u64)sel_rd32(p+4) << 32); }

gb_internal bool sel_add_u64(u64 a, u64 b, u64 *out) {
	*out = a + b;
	return *out >= a;
}

// Reads the defined/needed global symbols of an ELF64LE ET_REL x86-64
// object. Returns false (gap) on any malformed input. Name storage is
// process-lifetime and bounded by the input symbol count.
gb_internal bool sel_read_elf64_rel_syms(String obj_path, SelAsmSyms *syms) {
	char *c_path = alloc_cstring(temporary_allocator(), obj_path);
	gbFile f = {};
	if (gb_file_open_mode(&f, gbFileMode_Read, c_path) != gbFileError_None) {
		return false;
	}
	defer (gb_file_close(&f));
	i64 fsize = gb_file_size(&f);
	if (fsize < 64 || fsize > (cast(i64)1 << 31)) {
		return false;
	}
	u64 size = cast(u64)fsize;
	u8 *data = cast(u8 *)gb_alloc(heap_allocator(), size);
	defer (gb_free(heap_allocator(), data));
	isize got = 0;
	if (!gb_file_read_at_check(&f, data, cast(isize)size, 0, &got) || cast(u64)got != size) {
		return false;
	}
	// ELF header.
	if (!(data[0] == 0x7f && data[1] == 'E' && data[2] == 'L' && data[3] == 'F')) {
		return false;
	}
	if (data[4] != 2 || data[5] != 1 || data[6] != 1) { // 64-bit, little-endian, version 1
		return false;
	}
	if (sel_rd16(data+16) != 1 || sel_rd16(data+18) != 62 || sel_rd32(data+20) != 1) { // ET_REL, EM_X86_64, version
		return false;
	}
	u64 shoff = sel_rd64(data+40);
	u16 shentsize = sel_rd16(data+58);
	u16 shnum = sel_rd16(data+60);
	if (shentsize < 64 || shnum == 0 || shnum > 4096 || shoff == 0) {
		return false;
	}
	u64 sh_table_end = 0;
	if (!sel_add_u64(shoff, cast(u64)shnum * cast(u64)shentsize, &sh_table_end) || sh_table_end > size) {
		return false;
	}
	// Locate the symbol table and its string table.
	u64 sym_off = 0, sym_size = 0, sym_entsize = 0;
	u32 sym_link = 0;
	for (u16 i = 0; i < shnum; i++) {
		u8 const *h = data + shoff + cast(u64)i * cast(u64)shentsize;
		if (sel_rd32(h+4) == 2) { // SHT_SYMTAB
			sym_off = sel_rd64(h+24);
			sym_size = sel_rd64(h+32);
			sym_link = sel_rd32(h+40);
			sym_entsize = sel_rd64(h+56);
			break;
		}
	}
	if (sym_entsize < 24 || sym_size == 0 || sym_size > (cast(u64)1 << 28) || sym_size % sym_entsize != 0) {
		return false;
	}
	u64 sym_end = 0;
	if (!sel_add_u64(sym_off, sym_size, &sym_end) || sym_end > size) {
		return false;
	}
	if (sym_link >= shnum) {
		return false;
	}
	u8 const *strh = data + shoff + cast(u64)sym_link * cast(u64)shentsize;
	if (sel_rd32(strh+4) != 3) { // linked section must be SHT_STRTAB
		return false;
	}
	u64 str_off = sel_rd64(strh+24);
	u64 str_size = sel_rd64(strh+32);
	u64 str_end = 0;
	if (!sel_add_u64(str_off, str_size, &str_end) || str_end > size || str_size == 0) {
		return false;
	}
	u64 count = sym_size / sym_entsize;
	if (count > (cast(u64)1 << 24)) {
		return false;
	}
	for (u64 i = 0; i < count; i++) {
		u8 const *s = data + sym_off + i * sym_entsize;
		u32 st_name = sel_rd32(s);
		u8 st_info = s[4];
		u16 st_shndx = sel_rd16(s+6);
		u8 bind = st_info >> 4;
		if (bind != 1 && bind != 2) { // only STB_GLOBAL / STB_WEAK are link-visible
			continue;
		}
		if (cast(u64)st_name >= str_size) {
			return false;
		}
		u8 const *nbeg = data + str_off + st_name;
		u64 maxlen = str_size - st_name;
		u64 len = 0;
		while (len < maxlen && nbeg[len] != 0) {
			len += 1;
		}
		if (len == maxlen) {
			return false;
		}
		if (st_shndx == 0) { // SHN_UNDEF
			if (bind == 2) { // weak undefined may remain absent; never a requirement
				continue;
			}
			String nm = copy_string(permanent_allocator(), make_string(nbeg, cast(isize)len));
			array_add(&syms->needs, nm);
			continue;
		}
		// Section indices: ABS and COMMON supply the link; regular
		// indices must address a real section header; extended numbering
		// and every other reserved value fail closed (no writer in this
		// pipeline emits them, and blind acceptance would alias metadata).
		if (st_shndx == 0xfff1 || st_shndx == 0xfff2) { // SHN_ABS, SHN_COMMON
			// supply below
		} else if (st_shndx < shnum && st_shndx != 0) {
			// regular defined section
		} else {
			return false;
		}
		// Defined: regular sections, ABS, and COMMON all supply the
		// link. Any type (including STT_NOTYPE labels) and any
		// visibility (including HIDDEN, satisfiable in-executable).
		if (len == 0) {
			continue;
		}
		String nm = copy_string(permanent_allocator(), make_string(nbeg, cast(isize)len));
		array_add(&syms->supplies, nm);
		u8 strong = (bind == 1) ? 1 : 0;
		array_add(&syms->supply_strong, strong);
	}
	return true;
}

// Matches an assembler-reported undefined symbol against the owned
// closure. Accepts emission-guaranteed @(require) definitions alongside
// min-dep-rooted ones (the backend emits require-marked symbols
// unconditionally even though nothing in Odin calls them), the
// backend-synthesized runtime stubs, and the linker-synthesized
// section bounds. Assembler externs carry no Odin type, so matching is
// by exact link name; any type mismatch inside shipped assembler would
// already break the explicit -no-crt link identically.
gb_internal bool asm_undef_resolves(Checker *c, String sym) {
	if (sym.len == 0) {
		return false;
	}
	if (sym == str_lit(LB_STARTUP_RUNTIME_PROC_NAME) || sym == str_lit(LB_CLEANUP_RUNTIME_PROC_NAME)) {
		return true;
	}
	if (owned_link_synthesizes_init_array_bounds(sym)) {
		return true;
	}
	for (Entity *d : c->info.entities) {
		if (d->kind != Entity_Procedure && d->kind != Entity_Variable) {
			continue;
		}
		bool d_foreign = false;
		String dl = {};
		if (d->kind == Entity_Procedure) {
			d_foreign = d->Procedure.is_foreign;
			dl = d->Procedure.link_name;
		} else {
			d_foreign = d->Variable.is_foreign;
			dl = d->Variable.link_name;
		}
		if (d_foreign || dl != sym) {
			continue;
		}
		if (d->min_dep_count.load(std::memory_order_relaxed) > 0) {
			return true;
		}
		if (d->flags & EntityFlag_Require) {
			return true;
		}
	}
	return false;
}

// Invocation-private proof staging: shared temp directories are
// cross-process, so each compiler invocation creates its own exclusive
// directory once and places every proof object inside. POSIX uses
// mkdtemp (0700, exclusive); Windows retries an exclusive directory
// creation with a per-process counter. Predictable shared names are
// never used: a pre-existing path is not trusted.
gb_internal String sel_proof_dir(void) {
	gb_local_persist bool done = false;
	if (done) {
		return *linker_verified_asm_dir_slot();
	}
	done = true;
	String temp_dir = temporary_directory(temporary_allocator());
	if (temp_dir.len == 0) {
		return {};
	}
#if defined(GB_SYSTEM_WINDOWS)
	gb_local_persist u64 counter = 0;
	for (int attempt = 0; attempt < 100; attempt++) {
		counter += 1;
		gbString s = gb_string_make(heap_allocator(), "");
		s = gb_string_append_length(s, temp_dir.text, temp_dir.len);
		s = gb_string_append_fmt(s, "/selprove-%u-%llu", sel_process_id(), cast(unsigned long long)counter);
		char *c_path = alloc_cstring(heap_allocator(), make_string_c(s));
		gb_string_free(s);
		BOOL ok = CreateDirectoryA(c_path, nullptr);
		if (ok) {
			linker_verified_asm_set_dir(make_string_c(c_path));
			gb_free(heap_allocator(), c_path);
			return *linker_verified_asm_dir_slot();
		}
		DWORD err = GetLastError();
		gb_free(heap_allocator(), c_path);
		if (err != ERROR_ALREADY_EXISTS) {
			return {};
		}
	}
	return {};
#else
	gbString s = gb_string_make(heap_allocator(), "");
	s = gb_string_append_length(s, temp_dir.text, temp_dir.len);
	s = gb_string_appendc(s, "/");
	s = gb_string_appendc(s, "selprove-XXXXXX");
	if (mkdtemp(s) == nullptr) {
		gb_string_free(s);
		return {};
	}
	// Registry strings must survive a managed fallback's arena rewind.
	linker_verified_asm_set_dir(make_string_c(s));
	gb_string_free(s);
	return *linker_verified_asm_dir_slot();
#endif
}

gb_internal u32 sel_process_id(void) {
#if defined(GB_SYSTEM_WINDOWS)
	return cast(u32)GetCurrentProcessId();
#else
	return cast(u32)getpid();
#endif
}

gb_internal String sel_proof_obj_path(String asm_path) {
	String dir = sel_proof_dir();
	if (dir.len == 0) {
		return {};
	}
	gb_local_persist u64 counter = 0;
	counter += 1;
	String base = filename_without_directory(asm_path);
	gbString s = gb_string_make(heap_allocator(), "");
	s = gb_string_append_length(s, dir.text, dir.len);
	s = gb_string_appendc(s, "/");
	s = gb_string_append_fmt(s, "%llu-", cast(unsigned long long)counter);
	s = gb_string_append_length(s, base.text, base.len);
	s = gb_string_appendc(s, ".o");
	return make_string_c(s);
}

// Ensures one selected assembler input is assembled, parsed, and
// recorded, independent of verdicts. Runs as a pre-pass over every
// distinct library so later checks see the full cross-input supply
// universe. Returns nil when no authoritative symbols exist.
gb_internal SelAsmSyms *sel_ensure_asm_proven(AutoCtx *ctx, Entity *lib, String asm_path) {
	for (SelProvenAsm &p : ctx->asm_proven) {
		if (p.input == asm_path) {
			return &p.syms;
		}
	}
	// Already attempted (assembled, perhaps unparsable): never
	// reassemble within one process. Parse results are cached above;
	// anything else failed and stays failed without new evidence.
	if (linker_verified_asm_has(asm_path)) {
		return nullptr;
	}
	String obj_path = sel_proof_obj_path(asm_path);
	if (obj_path.len == 0) {
		auto_ledger(ctx, AutoEdge_Gap, "asm-no-temp", lib->LibraryName.name, asm_path);
		return nullptr;
	}
	// Track the output before assembling so assembler, parser, and
	// later link failures all clean it up; the link reuses it only
	// once parsing marks it proven below.
	{
		String dir = sel_proof_dir();
		if (dir.len != 0) {
			linker_verified_asm_set_dir(dir);
		}
		linker_verified_asm_record(asm_path, obj_path, false);
	}
	if (linker_assemble_asm_input(asm_path, obj_path) != 0) {
		auto_ledger(ctx, AutoEdge_Gap, "asm-assemble-fail", lib->LibraryName.name, asm_path);
		return nullptr;
	}
	SelAsmSyms syms = {};
	array_init(&syms.supplies, heap_allocator(), 0, 16);
	array_init(&syms.supply_strong, heap_allocator(), 0, 16);
	array_init(&syms.needs, heap_allocator(), 0, 8);
	if (!sel_read_elf64_rel_syms(obj_path, &syms)) {
		auto_ledger(ctx, AutoEdge_Gap, "asm-unreadable", lib->LibraryName.name, asm_path);
		return nullptr;
	}
	// The exact verified object is handed to the final link, so proof
	// and link never observe different bytes.
	linker_verified_asm_record(asm_path, obj_path, true);
	SelProvenAsm proven = {asm_path, syms, obj_path};
	array_add(&ctx->asm_proven, proven);
	for (SelProvenAsm &p : ctx->asm_proven) {
		if (p.input == asm_path) {
			return &p.syms;
		}
	}
	return nullptr;
}

// Checks one assembler's authoritative symbols: every reachable Odin
// binding to the importing library must name a supplied definition.
// Undefined closure is checked separately once every input is proven,
// since one input may supply another's need.
gb_internal AutoEdgeClass sel_check_asm_bindings(AutoCtx *ctx, Entity *lib, Array<BoundRef> *refs, String input, SelAsmSyms *syms) {
	AutoEdgeClass worst = AutoEdge_Owned;
	for (BoundRef const &q : *refs) {
		if (q.lib != lib) {
			continue;
		}
		String bn = {};
		if (q.entity->kind == Entity_Procedure) {
			bn = q.entity->Procedure.link_name;
		} else if (q.entity->kind == Entity_Variable) {
			bn = q.entity->Variable.link_name;
		}
		if (bn.len == 0) {
			continue;
		}
		bool found = false;
		for (String s : syms->supplies) {
			if (s == bn) {
				found = true;
				break;
			}
		}
		auto_ledger(ctx, found ? AutoEdge_Owned : AutoEdge_Gap, "asm-binding", bn, input);
		if (!found) {
			worst = AutoEdge_Gap;
		}
	}
	return worst;
}

// Checks undefined closure over the full proven supply universe: a
// strong need resolves through the owned ladder or through any proven
// assembler input's supplies (one freestanding input may serve
// another's extern). Duplicate strong supplies across distinct inputs
// fail honestly; the link would reject them.
gb_internal AutoEdgeClass sel_check_asm_needs(AutoCtx *ctx, String input, SelAsmSyms *syms) {
	AutoEdgeClass worst = AutoEdge_Owned;
	for (String n : syms->needs) {
		bool ok = asm_undef_resolves(ctx->c, n);
		if (!ok) {
			for (SelProvenAsm &p : ctx->asm_proven) {
				for (String s : p.syms.supplies) {
					if (s == n) {
						ok = true;
						break;
					}
				}
				if (ok) {
					break;
				}
			}
		}
		auto_ledger(ctx, ok ? AutoEdge_Owned : AutoEdge_Gap, "asm-need", n, input);
		if (!ok) {
			worst = AutoEdge_Gap;
		}
	}
	for (isize i = 0; i < syms->supplies.count; i++) {
		if (syms->supply_strong[i] == 0) {
			continue;
		}
		String nm = syms->supplies[i];
		for (SelStrongSupply const &prev : ctx->asm_strong) {
			if (prev.name == nm && prev.input != input) {
				auto_ledger(ctx, AutoEdge_Gap, "asm-dup-strong", nm, input);
				worst = AutoEdge_Gap;
			}
		}
		SelStrongSupply rec = {nm, input};
		array_add(&ctx->asm_strong, rec);
	}
	return worst;
}

// Reads one named foreign import's file list. User assembly without owned
// provenance is opaque (it may call libc); owned-tree assembly is proven
// by the provider suites like every other shipped file.
// Assembler inputs are proven from authoritative object metadata: each
// selected .asm file is assembled with the linker's exact configuration
// and its defined globals must cover every reachable Odin binding while
// its strong undefined symbols resolve through the owned closure. No
// origin, prefix, or text scan is proof; anything unproven is an honest
// gap, never established C.
gb_internal AutoEdgeClass classify_import_files(AutoCtx *ctx, Entity *lib, bool *saw_system, Array<BoundRef> *refs) {
	GB_ASSERT(lib->kind == Entity_LibraryName);
	if (lib->LibraryName.decl == nullptr) {
		// Backend-synthesized libraries (e.g. sanitizer runtimes, which
		// the envelope already excludes) carry no import declaration;
		// without provenance they stay conservative.
		return AutoEdge_Opaque;
	}
	ast_node(imp, ForeignImportDecl, lib->LibraryName.decl);

	AutoEdgeClass worst = AutoEdge_Owned;
	bool content = false;
	for (isize i = 0; i < imp->filepaths.count; i++) {
		Ast *file_path = imp->filepaths[i];
		GB_ASSERT(file_path->tav.mode == Addressing_Constant && file_path->tav.value().kind == ExactValue_String);
		String s = string_trim_whitespace(file_path->tav.value().value_string);
		if (s.len == 0) {
			continue;
		}
		content = true;
		if (string_starts_with(s, str_lit("system:"))) {
			*saw_system = true;
			if (s == str_lit("system:m")) {
				return AutoEdge_Real;
			}
			continue;
		}
		if (has_asm_extension(s)) {
			// Proven below from the resolved input's object metadata.
			continue;
		}
		if (filepath_denotes_system_c_lib(s)) {
			return AutoEdge_Real;
		}
		if (worst < AutoEdge_Opaque) {
			worst = AutoEdge_Opaque;
		}
	}
	// Prove each selected assembler input. Resolved paths mirror the
	// linker's inputs exactly; source spellings are never assembled.
	for (String p : lib->LibraryName.paths) {
		String asm_path = string_trim_whitespace(p);
		if (asm_path.len == 0 || !has_asm_extension(asm_path)) {
			continue;
		}
		content = true;
		// Inputs are ensured by the pre-pass; this call hits the cache
		// except for forced libraries first seen here, which it proves
		// on demand against the same universe.
		SelAsmSyms *syms = sel_ensure_asm_proven(ctx, lib, asm_path);
		AutoEdgeClass proof = AutoEdge_Gap;
		if (syms != nullptr) {
			proof = sel_check_asm_bindings(ctx, lib, refs, asm_path, syms);
			AutoEdgeClass needs = sel_check_asm_needs(ctx, asm_path, syms);
			if (needs > proof) {
				proof = needs;
			}
			auto_ledger(ctx, proof, "asm-proof", lib->LibraryName.name, asm_path);
		} else {
			auto_ledger(ctx, proof, "asm-unproven", lib->LibraryName.name, asm_path);
		}
		if (proof > worst) {
			worst = proof;
		}
	}
	if (!content) {
		return AutoEdge_Owned; // links nothing
	}
	return worst;
}

struct AutoSelection {
	int real_count;
	int opaque_count;
	int gap_count;
};

gb_internal String auto_entity_origin(Entity *e) {
	if (e != nullptr && e->file != nullptr) {
		return e->file->fullpath;
	}
	return str_lit("<nofile>");
}

gb_internal String auto_lib_origin(Entity *lib) {
	return auto_entity_origin(lib);
}

// Tallies one verdict into the edge counters and the fallback counts.
// Every non-owned class falls back to managed; the counts keep the
// reasons distinct.
gb_internal void auto_tally(AutoCtx *ctx, AutoSelection *sel, AutoEdgeClass cls) {
	auto_count_edge(ctx, cls);
	if (cls == AutoEdge_Real) {
		sel->real_count += 1;
	} else if (cls == AutoEdge_Opaque) {
		sel->opaque_count += 1;
	} else if (cls == AutoEdge_Gap) {
		sel->gap_count += 1;
	}
}

// Classifies one entity bound to a system (non-libm) import: owned when an
// actual emitted definition matches, verified C otherwise.
gb_internal AutoEdgeClass classify_system_bound_edge(AutoCtx *ctx, Entity *e) {
	String link_name = {};
	if (e->kind == Entity_Procedure) {
		link_name = e->Procedure.link_name;
	} else if (e->kind == Entity_Variable) {
		link_name = e->Variable.link_name;
	} else {
		return AutoEdge_Owned;
	}
	if (emitted_def_matches_foreign(ctx->c, e->kind, link_name, e->type)) {
		return AutoEdge_Owned;
	}
	return AutoEdge_Real;
}

// Walks the reachable foreign graph after checking: min_dep-rooted foreign
// entities plus forced imports. Marks owned-satisfied system libraries so
// the backend drops them from link inputs. Runs only on error-free graphs;
// user errors are never labeled C requirements. Reports owned,
// verified-C, opaque-input, and candidate-gap tallies plus a per-reference
// ledger to the verbose channel; all three non-owned classes fall back
// to managed with distinct labels.
gb_internal AutoSelection classify_reachable_requirements(Checker *c) {
	AutoSelection sel = {};
	AutoCtx ctx = {};
	ctx.c = c;
	ctx.tree = owned_tree_prefixes();
	array_init(&ctx.asm_proven, heap_allocator(), 0, 8);
	array_init(&ctx.asm_strong, heap_allocator(), 0, 32);

	Array<BoundRef> refs = array_make<BoundRef>(heap_allocator(), 0, 64);
	defer (array_free(&refs));

	auto visit_foreign_entity = [&](Entity *e) {
		if (e == nullptr) {
			return;
		}
		bool is_foreign = false;
		Entity *lib = nullptr;
		if (e->kind == Entity_Procedure) {
			is_foreign = e->Procedure.is_foreign;
			lib = e->Procedure.foreign_library;
		} else if (e->kind == Entity_Variable) {
			is_foreign = e->Variable.is_foreign;
			lib = e->Variable.foreign_library;
		} else {
			return;
		}
		if (!is_foreign) {
			return;
		}
		if (lib == nullptr) {
			String link_name = (e->kind == Entity_Procedure) ? e->Procedure.link_name : e->Variable.link_name;
			AutoEdgeClass cls = classify_blank_edge(&ctx, e, link_name, e->type);
			BoundRef r = {e, nullptr};
			array_add(&refs, r);
			auto_ledger(&ctx, cls, "blank", link_name, auto_entity_origin(e));
			auto_tally(&ctx, &sel, cls);
			return;
		}
		BoundRef r = {e, lib};
		array_add(&refs, r);
	};

	for (Entity *e : c->info.entities) {
		if (e->kind != Entity_Procedure && e->kind != Entity_Variable) {
			continue;
		}
		if (e->min_dep_count.load(std::memory_order_relaxed) <= 0) {
			continue;
		}
		visit_foreign_entity(e);
	}
	for (Entity *e : c->info.required_foreign_imports_through_force) {
		visit_foreign_entity(e);
	}

	// Assembler pre-pass: prove every selected input before any verdict
	// so undefined closure sees the full cross-input supply universe
	// (one freestanding input may serve another's extern). Covers
	// bound libraries and forced-only libraries alike; ensured inputs
	// cache by canonical path.
	for (BoundRef const &r : refs) {
		if (r.lib == nullptr) {
			continue;
		}
		for (String p : r.lib->LibraryName.paths) {
			String asm_path = string_trim_whitespace(p);
			if (asm_path.len == 0 || !has_asm_extension(asm_path)) {
				continue;
			}
			sel_ensure_asm_proven(&ctx, r.lib, asm_path);
		}
	}
	for (Entity *e : c->info.required_foreign_imports_through_force) {
		if (e->kind != Entity_LibraryName) {
			continue;
		}
		for (String p : e->LibraryName.paths) {
			String asm_path = string_trim_whitespace(p);
			if (asm_path.len == 0 || !has_asm_extension(asm_path)) {
				continue;
			}
			sel_ensure_asm_proven(&ctx, e, asm_path);
		}
	}

	// Decide each distinct named library once.
	Array<Entity *> seen_libs = array_make<Entity *>(heap_allocator(), 0, 16);
	defer (array_free(&seen_libs));
	for (BoundRef const &r : refs) {
		if (r.lib == nullptr) {
			continue;
		}
		bool seen = false;
		for (Entity *s : seen_libs) {
			if (s == r.lib) {
				seen = true;
				break;
			}
		}
		if (seen) {
			continue;
		}
		array_add(&seen_libs, r.lib);

		bool saw_system = false;
		AutoEdgeClass files = classify_import_files(&ctx, r.lib, &saw_system, &refs);
		auto_ledger(&ctx, files, "lib-files", r.lib->LibraryName.name, auto_lib_origin(r.lib));
		auto_count_edge(&ctx, files);
		// A system import needs its bound references checked; a forced
		// import without users still links, so it still requires.
		bool bound_any = false;
		AutoEdgeClass worst_bound = AutoEdge_Owned;
		for (BoundRef const &q : refs) {
			if (q.lib != r.lib) {
				continue;
			}
			bound_any = true;
			if (saw_system) {
				AutoEdgeClass cls = classify_system_bound_edge(&ctx, q.entity);
				String qn = {};
				if (q.entity->kind == Entity_Procedure) {
					qn = q.entity->Procedure.link_name;
				} else if (q.entity->kind == Entity_Variable) {
					qn = q.entity->Variable.link_name;
				}
				auto_ledger(&ctx, cls, "system-bound", qn, auto_entity_origin(q.entity));
				auto_count_edge(&ctx, cls);
				if (cls > worst_bound) {
					worst_bound = cls;
				}
			}
		}
		AutoEdgeClass verdict = files;
		if (saw_system) {
			if (!bound_any) {
				verdict = AutoEdge_Real;
			} else if (worst_bound == AutoEdge_Real || files == AutoEdge_Real) {
				// Verified C anywhere in the import wins the label;
				// opaque company is still reported through its own edges.
				verdict = AutoEdge_Real;
			} else if (worst_bound == AutoEdge_Opaque || files == AutoEdge_Opaque) {
				verdict = AutoEdge_Opaque;
			} else if (worst_bound == AutoEdge_Gap || files == AutoEdge_Gap) {
				verdict = AutoEdge_Gap;
			}
		}
		auto_ledger(&ctx, verdict, "lib-verdict", r.lib->LibraryName.name, auto_lib_origin(r.lib));
		auto_tally(&ctx, &sel, verdict);
		// Every selected library's own extra flags participate without
		// overriding the file verdict: an independent Real there must
		// still fall back, reported through its own edge. System-owned,
		// owned-asm, and forced libraries are covered exactly alike.
		// Dropping a library must not drop a hidden -l requirement, so
		// the satisfied mark applies only when both are clean.
		AutoEdgeClass extra = classify_linker_flags(r.lib->LibraryName.extra_linker_flags);
		if (extra != AutoEdge_Owned) {
			auto_ledger(&ctx, extra, "lib-extra-flags", r.lib->LibraryName.name, auto_lib_origin(r.lib));
			auto_tally(&ctx, &sel, extra);
		}
		if (verdict == AutoEdge_Owned && saw_system && extra == AutoEdge_Owned) {
			// Every bound reference resolves owned: drop the system
			// library from link inputs. File and .asm imports never
			// take this path, so entry stubs and user objects flow on.
			r.lib->flags |= EntityFlag_OwnedSatisfied;
		}
	}

	// Forced LibraryName imports with no bound references at all never
	// entered the edge list above; a forced system/file import still links.
	for (Entity *e : c->info.required_foreign_imports_through_force) {
		if (e->kind != Entity_LibraryName) {
			continue;
		}
		bool seen = false;
		for (Entity *s : seen_libs) {
			if (s == e) {
				seen = true;
				break;
			}
		}
		if (seen) {
			continue;
		}
		bool saw_system = false;
		AutoEdgeClass verdict = classify_import_files(&ctx, e, &saw_system, &refs);
		if (saw_system && verdict == AutoEdge_Owned) {
			// Forced without users: the import still links, so the
			// final verdict is computed before the single tally below.
			verdict = AutoEdge_Real;
		}
		// Every selected library's own extra flags participate without
		// overriding the file verdict: an independent Real there must
		// still fall back, reported through its own edge.
		AutoEdgeClass extra = classify_linker_flags(e->LibraryName.extra_linker_flags);
		if (extra != AutoEdge_Owned) {
			auto_ledger(&ctx, extra, "forced-lib-extra-flags", e->LibraryName.name, auto_lib_origin(e));
			auto_tally(&ctx, &sel, extra);
		}
		auto_ledger(&ctx, verdict, "forced-lib", e->LibraryName.name, auto_lib_origin(e));
		auto_tally(&ctx, &sel, verdict);
	}

	// User-supplied extra linker flags can carry real C requirements
	// (-lc) or opaque inputs (a constructor object) outside the foreign
	// graph; a managed loader-constructor fixture must stay managed.
	// Native-safe policy flags never count. Flags come from argv, so the
	// cache manifests already key them.
	{
		AutoEdgeClass flag_cls = classify_linker_flags(build_context.extra_linker_flags);
		auto_ledger(&ctx, flag_cls, "argv-flags", str_lit("extra-linker-flags"), str_lit("argv"));
		auto_tally(&ctx, &sel, flag_cls);
	}

	debugf("owned-first selection: %d owned, %d verified C, %d opaque-input, %d candidate-gap references\n",
	       ctx.owned_edges, ctx.real_edges, ctx.opaque_edges, ctx.gap_edges);
	return sel;
}

// Trial-generation arena checkpoints for the owned-first automatic profile.
// Captured once in main after thread-pool init and before init_universal,
// so every pre-trial permanent allocation (CLI strings, build_context,
// init_filename, the thread array itself) sits at or below the marks and
// survives, while the whole trial graph sits above them. Consumed at most
// once, by the managed fallback below; every other path leaves the marks
// inert. Storage is a tiny heap array released at reclaim time. Slots
// (rather than resolved pointers) are recorded for pool thread arenas so
// an arena that appears only after capture rewinds to an empty
// pre-trial generation while keeping its heap Arena struct.
struct TrialArenaSlot {
	Arena **        slot;  // pool thread arena field; nullptr for the default arenas
	Arena *         arena; // resolved at capture; re-resolved through slot at reclaim
	ArenaCheckpoint mark;
};

gb_global Array<TrialArenaSlot> g_trial_arena_slots;
gb_global bool g_trial_arena_checkpoint_active = false;

gb_internal void trial_arena_checkpoint_all(void) {
	GB_ASSERT_MSG(!g_trial_arena_checkpoint_active, "trial arena checkpoint taken twice");
	array_init(&g_trial_arena_slots, heap_allocator());
	{
		TrialArenaSlot slot = {};
		slot.arena = &default_permanent_arena;
		slot.mark = arena_checkpoint(slot.arena);
		array_add(&g_trial_arena_slots, slot);
	}
	{
		TrialArenaSlot slot = {};
		slot.arena = &default_temporary_arena;
		slot.mark = arena_checkpoint(slot.arena);
		array_add(&g_trial_arena_slots, slot);
	}
	for (isize i = 0; i < global_thread_pool.threads.count; i++) {
		Thread *t = &global_thread_pool.threads[i];
		TrialArenaSlot perm = {};
		perm.slot = &t->permanent_arena;
		perm.arena = *perm.slot;
		perm.mark = arena_checkpoint(perm.arena);
		array_add(&g_trial_arena_slots, perm);
		TrialArenaSlot temp = {};
		temp.slot = &t->temporary_arena;
		temp.arena = *temp.slot;
		temp.mark = arena_checkpoint(temp.arena);
		array_add(&g_trial_arena_slots, temp);
	}
	g_trial_arena_checkpoint_active = true;
}

// Rewinds every checkpointed arena to its pre-trial mark, releasing the
// whole superseded graph at once. Reclaim is a pure optimization:
// correctness never depends on it, so any failed validation skips the
// rewind entirely and the build continues with retain behavior.
gb_internal void trial_arena_reclaim_all(void) {
	if (!g_trial_arena_checkpoint_active) {
		return;
	}
	bool valid = global_thread_pool.tasks_left.load(std::memory_order_acquire) == 0;
	if (valid) {
		for (TrialArenaSlot &s : g_trial_arena_slots) {
			Arena *arena = (s.slot != nullptr) ? *s.slot : s.arena;
			if (!arena_checkpoint_valid(arena, s.mark)) {
				valid = false;
				break;
			}
		}
	}
	if (valid) {
		for (TrialArenaSlot &s : g_trial_arena_slots) {
			Arena *arena = (s.slot != nullptr) ? *s.slot : s.arena;
			if (arena != nullptr) {
				arena_rewind_quiescent(arena, s.mark);
			}
		}
	}
	array_free(&g_trial_arena_slots);
	g_trial_arena_checkpoint_active = false;
}

// Re-parses and re-checks from scratch with the managed profile after an
// owned-first attempt found real requirements (or errors). Fresh Parser and
// Checker avoid every first-run residue: AST type values, dependency
// counts, and entity tables are rebuilt, while process-global state is
// reset explicitly below. Verified reuse inventory: string interner
// dedupes re-inserts idempotently; universal packages are rebuilt by
// init_universal so profile constants match the final profile; worker
// pools and task groups drain (thread_pool_wait) before selection runs;
// min_dep_basic_equal_procs is nulled and repopulated per run;
// entity-collection worker data is reallocated in init_checker;
// per-generation worker untyped maps are destroyed before the rewind;
// global_checker_ptr is re-stored by check_parsed_files. Diagnostics stay
// buffered: run-1 output never printed, and
// reset_error_collector_for_recheck clears the queues, counts, and held
// state (errors_already_printed stays false by construction). Remaining
// monotonic debug counters need no reset. Types cached across the process
// (reset_core_type_info_for_recheck) and one-way check-phase flags
// (reset_check_phase_globals_for_recheck) are dropped; lookup_selector's
// implicit field entities (dynamic-array/map .allocator, any data/id,
// quaternion w/x/y/z/xyz) are allocated fresh on every lookup so no
// function-static entity outlives a superseded run. The superseded run's
// pair is destroyed here; main's
// deferred destroys then cover exactly the replacement pair (defer
// evaluates at scope exit, verified). *failed_to_cache_parsing mirrors
// the normal cache-miss path so a later store still records this build.
gb_internal bool reparse_and_recheck_managed(Parser **parser_ptr, Checker **checker_ptr, String init_filename, bool *failed_to_cache_parsing, bool derived_reloc) {
	TIME_SECTION("owned-first selection: managed fallback recheck");

	build_context.no_crt = false;
	// init_build_context derived Static from Default under the owned
	// provisional; restore the managed default derivation. The envelope
	// gate guarantees reloc was Default, so this never overrides an
	// explicit user mode.
	if (derived_reloc) {
		build_context.reloc_mode = RelocMode_PIC;
	}
	*failed_to_cache_parsing = true;

	reset_error_collector_for_recheck();

	destroy_checker(*checker_ptr);
	destroy_parser(*parser_ptr);
	// Per-generation worker untyped maps hold heap entries tables that
	// the next generation's fresh worker arrays would orphan; destroy
	// them while the arena-owned structs are still mapped and the pool
	// is quiescent, before the rewind below releases the structs.
	destroy_trial_worker_untyped_maps();
	// Run-1 entity pointers cached in process globals must not survive:
	// min_dep_basic_equal_procs is repopulated per run during min-dep
	// generation, but early equality checks would otherwise dereference
	// freed run-1 entities. Other checker globals are reassigned per run
	// (worker data, checker pointer) or debug-only monotonic.
	for (isize i = 0; i < Basic_COUNT; i++) {
		min_dep_basic_equal_procs[i] = nullptr;
	}
	// Core named-type globals (t_context and friends) propagate into
	// checked state and codegen; the six init_core_* families early-out
	// on them, so drop every one for coherent re-resolution.
	reset_core_type_info_for_recheck();
	// One-way check-phase flags (procedure-body stages) never clear
	// themselves; the final run must start in the initial phase.
	reset_check_phase_globals_for_recheck();
	// File id tables map small ids to run-1 AstFiles; entity file links,
	// diagnostics, and package scopes would otherwise alias the old run.
	reset_global_file_tables_for_recheck();
	// Clone paths and package tail work key off parse completion.
	g_parsing_done.store(false, std::memory_order_relaxed);
	// The superseded run's heap shells are destroyed above while its arena
	// payloads are still mapped. Transient per-thread roots are empty here
	// by construction: every stack below is defer-balanced within its own
	// call and no task runs anywhere, so the main thread's instances are
	// checked directly. The checker pointer is re-stored by the final
	// check_parsed_files; null it now so the managed reparse sees the same
	// pointer state as the initial parse.
	GB_ASSERT_MSG(global_when_trial == nullptr, "global when-trial active across managed fallback");
	GB_ASSERT_MSG(is_type_polymorphic_named_stack.count == 0, "polymorphic type stack not empty across managed fallback");
	GB_ASSERT_MSG(in_progress_alias_expansions.count == 0, "alias expansion stack not empty across managed fallback");
	GB_ASSERT_MSG(global_error_context.mute_depth == 0, "error mute not balanced across managed fallback");
	GB_ASSERT_MSG(global_group_context.group == nullptr && global_group_context.entity == nullptr, "global group context not cleared across managed fallback");
	global_checker_ptr.store(nullptr, std::memory_order_relaxed);
	// Release the whole superseded graph at once by rewinding every arena
	// to its pre-trial mark; run-1 classification results are already
	// consumed and nothing below reads them.
	trial_arena_reclaim_all();
	// Universal packages and profile constants (ODIN_NO_CRT among them)
	// are created once and sealed read-only by a check run, so a second
	// run needs them rebuilt: fresh scopes accept insertion and every
	// constant reflects the final profile. The rewind above releases the
	// previous set when its validation passes, and otherwise the old set
	// is simply orphaned; string interning dedupes either way.
	init_universal();
	Parser *parser = permanent_alloc_item<Parser>();
	Checker *checker = permanent_alloc_item<Checker>();
	checker->parser = parser;
	init_checker(checker);
	if (!init_parser(parser)) {
		return false;
	}
	parser->package_parsed_proc = check_collect_package_entities_worker_proc;

	if (parse_packages(parser, init_filename) != ParseFile_None) {
		GB_ASSERT_MSG(any_errors(), "parse_packages failed but no error was reported.");
	}
	if (any_errors()) {
		*parser_ptr = parser;
		*checker_ptr = checker;
		return false;
	}
	release_held_errors();
	if (any_errors()) {
		*parser_ptr = parser;
		*checker_ptr = checker;
		return false;
	}

	check_parsed_files(checker);
	*parser_ptr = parser;
	*checker_ptr = checker;
	return true;
}
