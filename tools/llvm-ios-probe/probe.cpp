// SPDX-License-Identifier: GPL-3.0-or-later
//
// AYS3 Phase 1a — does LLVM's ORC JIT even build for arm64-apple-ios?
//
// RPCS3's PPU/SPU recompilers are built on LLVM's ExecutionEngine/ORC APIs
// (see external/rpcs3/3rdparty/llvm/CMakeLists.txt: Core, ExecutionEngine,
// MCJIT, Passes). Nobody has published cross-compiling LLVM itself to run
// AS a linked library inside an iOS app before (RPCS3's own arm64 support
// targets desktop arm64 — macOS/Linux/Windows — where LLVM runs as a normal
// host process; iOS is a different target triple and a sandboxed process).
// This is deliberately the smallest possible probe of that specific unknown,
// decoupled from all of RPCS3's other complexity (Qt, Vulkan, RSX, the
// actual PPU/SPU translators). It builds a trivial IR function and JITs it
// with LLJIT (ORCv2) — the same category of API RPCS3's recompiler drives.
//
// Two separate things have to be true, and this only tests the first:
//   1. LLVM cross-compiles and links for arm64-apple-ios at all (this file,
//      validated by CI build success on the macOS runner).
//   2. LLJIT's default memory manager can actually allocate executable
//      memory on-device without the dynamic-codesigning entitlement — it
//      almost certainly can't out of the box, since it doesn't know about
//      our dual-map bypass from Phase 0. That integration (a custom
//      JITLinkMemoryManager routing through JITBypass.cpp's
//      MmapCodeDualMap-equivalent) is follow-up work, not attempted here.
//
// This program is compiled for iOS by CI (proves it builds) but running it
// end-to-end still needs a real device via StikDebug, same as Phase 0.

#include <llvm/ExecutionEngine/Orc/LLJIT.h>
#include <llvm/IR/IRBuilder.h>
#include <llvm/IR/LLVMContext.h>
#include <llvm/IR/Module.h>
#include <llvm/IR/Verifier.h>
#include <llvm/Support/TargetSelect.h>

#include <cstdio>

using namespace llvm;
using namespace llvm::orc;

int main()
{
	InitializeNativeTarget();
	InitializeNativeTargetAsmPrinter();

	auto context = std::make_unique<LLVMContext>();
	auto mod = std::make_unique<Module>("ays3_probe", *context);

	FunctionType* fnTy = FunctionType::get(Type::getInt32Ty(*context), false);
	Function* fn = Function::Create(fnTy, Function::ExternalLinkage, "ays3_probe", mod.get());
	BasicBlock* bb = BasicBlock::Create(*context, "entry", fn);
	IRBuilder<> builder(bb);
	builder.CreateRet(ConstantInt::get(Type::getInt32Ty(*context), 42));

	if (verifyFunction(*fn, &errs()))
	{
		std::fprintf(stderr, "AYS3_LLVM_PROBE: function verification failed\n");
		return 1;
	}

	auto jitOrErr = LLJITBuilder().create();
	if (!jitOrErr)
	{
		std::fprintf(stderr, "AYS3_LLVM_PROBE: LLJIT create failed: %s\n",
			toString(jitOrErr.takeError()).c_str());
		return 1;
	}
	auto jit = std::move(*jitOrErr);

	if (auto err = jit->addIRModule(ThreadSafeModule(std::move(mod), std::move(context))))
	{
		std::fprintf(stderr, "AYS3_LLVM_PROBE: addIRModule failed: %s\n",
			toString(std::move(err)).c_str());
		return 1;
	}

	auto symOrErr = jit->lookup("ays3_probe");
	if (!symOrErr)
	{
		std::fprintf(stderr, "AYS3_LLVM_PROBE: lookup failed: %s\n",
			toString(symOrErr.takeError()).c_str());
		return 1;
	}

	auto fnPtr = symOrErr->toPtr<int (*)()>();
	const int result = fnPtr();
	std::printf("AYS3_LLVM_PROBE: ays3_probe() = %d (expected 42)\n", result);
	return (result == 42) ? 0 : 1;
}
