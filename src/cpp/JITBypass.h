// SPDX-License-Identifier: GPL-3.0-or-later
//
// AYS3 Phase 0 — iOS JIT bypass probe.
//
// Adapted from AYS2's common/Darwin/DarwinMisc.cpp (itself carrying the
// technique forward from ARMSX2/PCSX2, GPL-3.0+). See NOTICE. This is a
// deliberately minimal, standalone extraction: just enough to prove the
// dual-map JIT bypass works end-to-end (allocate executable memory without
// the `dynamic-codesigning` entitlement, write a trivial function into it,
// execute it, verify the result) before any RPCS3 integration exists.
//
// C linkage so this can be called directly from Swift via a bridging
// header, with no Objective-C++ glue layer needed for something this small.

#pragma once

#ifdef __cplusplus
extern "C"
{
#endif

	// Mirrors DarwinMisc::JitMode. Values are part of the C ABI exposed to
	// Swift — do not renumber without updating ContentView.swift.
	typedef enum AYS3JitMode
	{
		AYS3JitModeSimulator = 0, // MAP_JIT works directly (Mac Catalyst / simulator / already-entitled build)
		AYS3JitModeLuckTXM = 1,   // iOS 26+, TXM-equipped SoC (A15/M2+): dual-map via brk #0xf00d handshake
		AYS3JitModeLuckNoTXM = 2, // iOS 26+, forced dual-map without the TXM handshake
		AYS3JitModeLegacy = 3,    // iOS < 26: mmap RW, mprotect toggle around execution
		AYS3JitModeUnknown = 4,
	} AYS3JitMode;

	// True if code signing reports CS_DEBUGGED (i.e. a debugger — StikDebug —
	// is currently attached to this process). JIT is not reachable at all
	// without this, on any mode.
	int ays3_is_cs_debugged(void);

	// Probes the OS version and TXM firmware presence to pick a JIT strategy.
	// Safe to call repeatedly; result is cached after the first call.
	AYS3JitMode ays3_detect_jit_mode(void);

	const char* ays3_jit_mode_name(AYS3JitMode mode);

	// Runs the full probe: allocate dual-mapped executable memory, write an
	// 8-byte arm64 stub (`mov w0, #42; ret`) through the writable view,
	// invalidate the instruction cache, call it through the executable view,
	// and check the return value is 42. Frees the memory either way.
	//
	// Returns 1 if the entire round trip succeeded (JIT bypass proven
	// functional on this device, right now), 0 otherwise.
	int ays3_run_jit_stub(void);

	// Newline-separated, human-readable stage log of the most recent
	// ays3_run_jit_stub() call — meant to be shown directly in the app UI so
	// a failure is diagnosable without pulling device console logs.
	const char* ays3_last_stub_log(void);

#ifdef __cplusplus
}
#endif
