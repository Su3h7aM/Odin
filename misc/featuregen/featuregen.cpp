#include <llvm/MC/MCSubtargetInfo.h>
#include <llvm/MC/TargetRegistry.h>
#include <llvm/TargetParser/Triple.h>
#include <llvm/Support/raw_ostream.h>
#include <llvm/ADT/ArrayRef.h>
#include <llvm/Support/InitLLVM.h>
#include <llvm/Support/TargetSelect.h>

// NOTE: LLVM_VERSION_MAJOR reaches this file through Support/TargetSelect.h,
// which includes llvm/Config/llvm-config.h.
#ifndef LLVM_VERSION_MAJOR
	#error "LLVM_VERSION_MAJOR is not defined!"
#endif

// The API this tool needs changed shape twice:
//
//   LLVM 17-20: TargetRegistry::lookupTarget takes a StringRef, there is no
//               Triple overload of createMCSubtargetInfo, and
//               SubtargetFeatureKV exposes its key as the `Key` field.
//   LLVM 21:    lookupTarget gains the Triple overload, the StringRef one
//               remains.
//   LLVM 22:    createMCSubtargetInfo gains the Triple overload, the StringRef
//               one remains.
//   LLVM 23:    the StringRef overloads are gone and SubtargetFeatureKV stores
//               a string-table offset instead of a pointer, so the key is read
//               through the key() accessor.
//
// Pick whichever spelling the LLVM being built against actually offers.

// Dumps the default set of supported features for the given microarch.
int main(int argc, char **argv) {
	if (argc < 3) {
		llvm::errs() << "Error: first arg should be triple, second should be microarch\n";
		return 1;
	}

	llvm::InitializeAllTargets();
	llvm::InitializeAllTargetMCs();

	std::string error;
	llvm::Triple triple(argv[1]);

#if LLVM_VERSION_MAJOR >= 22
	const llvm::Target* target = llvm::TargetRegistry::lookupTarget(triple, error);
#else
	const llvm::Target* target = llvm::TargetRegistry::lookupTarget(argv[1], error);
#endif

	if (!target) {
		llvm::errs() << "Error: " << error << "\n";
		return 1;
	}

#if LLVM_VERSION_MAJOR >= 22
	auto STI = target->createMCSubtargetInfo(triple, argv[2], "");
#else
	auto STI = target->createMCSubtargetInfo(argv[1], argv[2], "");
#endif

	std::string plus = "+";
	llvm::ArrayRef<llvm::SubtargetFeatureKV> features = STI->getAllProcessorFeatures();
	for (const auto& feature : features) {
#if LLVM_VERSION_MAJOR >= 23
		if (STI->checkFeatures(plus + feature.key())) {
			llvm::outs() << feature.key() << "\n";
		}
#else
		if (STI->checkFeatures(plus + feature.Key)) {
			llvm::outs() << feature.Key << "\n";
		}
#endif
	}

	return 0;
}
