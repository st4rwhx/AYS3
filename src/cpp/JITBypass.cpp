// SPDX-License-Identifier: GPL-3.0-or-later
// See JITBypass.h and NOTICE. Adapted from AYS2's common/Darwin/DarwinMisc.cpp.

#include "JITBypass.h"

#include <TargetConditionals.h>

#include <cerrno>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <csignal>

#if defined(__APPLE__)
#include <dlfcn.h>
#include <glob.h>
#include <setjmp.h> // sigsetjmp/siglongjmp are POSIX, not in <csetjmp>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <unistd.h> // getpid(), getpagesize()
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <libkern/OSCacheControl.h>

// csops() is not in a public iOS SDK header, but the symbol is present in
// libSystem and this exact prototype is what the kernel expects (the same
// declaration WebKit and every other iOS JIT-bypass project uses).
extern "C" int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize);
#define AYS3_CS_OPS_STATUS 0
#define AYS3_CS_DEBUGGED 0x10000000u
#endif

namespace
{
	char s_log[4096] = {};

	void LogReset()
	{
		s_log[0] = '\0';
	}

	void LogAppend(const char* fmt, ...)
	{
		char line[256];
		va_list args;
		va_start(args, fmt);
		std::vsnprintf(line, sizeof(line), fmt, args);
		va_end(args);
		std::strncat(s_log, line, sizeof(s_log) - std::strlen(s_log) - 1);
		std::strncat(s_log, "\n", sizeof(s_log) - std::strlen(s_log) - 1);
	}

	AYS3JitMode s_mode = AYS3JitModeUnknown;
	bool s_mode_detected = false;

#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
	bool HasTXM()
	{
		glob_t g = {};
		const int ret = glob(
			"/System/Volumes/Preboot/*/boot/*/usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4",
			GLOB_NOSORT, nullptr, &g);
		const bool found = (ret == 0 && g.gl_pathc > 0);
		globfree(&g);
		return found;
	}

	// The `brk #0xf00d` / `brk #0x69` handshake: on iOS 26+ with TXM, a plain
	// mmap(MAP_JIT) can fail for a get-task-allow process even while
	// CS_DEBUGGED, unless the attached debugger (StikDebug) is told, via this
	// trap convention, to permit the specific memory region that follows. If
	// no debugger is attached to intercept the trap, it raises a real SIGTRAP
	// that we catch below and treat as "handshake unavailable".
	__attribute__((noinline, optnone)) void JIT26PrepareRegion(void* addr, size_t len)
	{
		asm volatile("mov x0, %0\n"
					 "mov x1, %1\n"
					 "mov x16, #1\n"
					 "brk #0xf00d\n" ::"r"(addr),
			"r"(len)
			: "x0", "x1", "x16", "memory");
	}

	__attribute__((noinline, optnone)) void JIT26Detach(void)
	{
		asm volatile("mov x16, #0\n"
					 "brk #0xf00d\n" ::
					 : "x16", "memory");
	}
#endif
} // namespace

int ays3_is_cs_debugged(void)
{
#if defined(__APPLE__)
	unsigned int cs_flags = 0;
	const int rv = csops(getpid(), AYS3_CS_OPS_STATUS, &cs_flags, sizeof(cs_flags));
	return (rv == 0) && ((cs_flags & AYS3_CS_DEBUGGED) != 0) ? 1 : 0;
#else
	return 0;
#endif
}

const char* ays3_jit_mode_name(AYS3JitMode mode)
{
	switch (mode)
	{
		case AYS3JitModeSimulator: return "Simulator";
		case AYS3JitModeLuckTXM: return "LuckTXM";
		case AYS3JitModeLuckNoTXM: return "LuckNoTXM";
		case AYS3JitModeLegacy: return "Legacy";
		default: return "Unknown";
	}
}

AYS3JitMode ays3_detect_jit_mode(void)
{
	if (s_mode_detected)
		return s_mode;

#if TARGET_OS_SIMULATOR
	s_mode = AYS3JitModeSimulator;
#elif TARGET_OS_IPHONE
	char version[64] = {};
	size_t version_len = sizeof(version);
	if (sysctlbyname("kern.osproductversion", version, &version_len, nullptr, 0) != 0)
		std::snprintf(version, sizeof(version), "0");
	const int major = std::atoi(version);
	const bool has_txm = HasTXM();
	(void)has_txm;
	s_mode = (major >= 26) ? AYS3JitModeLuckTXM : AYS3JitModeLegacy;

	if (const char* force_dual = std::getenv("AYS3_FORCE_DUAL_MAP"))
	{
		if (std::atoi(force_dual) == 1)
			s_mode = AYS3JitModeLuckNoTXM;
	}
#else
	s_mode = AYS3JitModeSimulator;
#endif
	s_mode_detected = true;
	return s_mode;
}

namespace
{
	struct JitAlloc
	{
		void* rx = nullptr;
		size_t size = 0;
		ptrdiff_t rw_offset = 0; // 0 => write through rx directly (toggle W^X around it)
		uintptr_t rw_dealloc_base = 0;
		size_t rw_dealloc_size = 0;
		bool legacy_toggle = false; // true => single RW/RX mapping, mprotect toggle needed
	};

#if defined(__APPLE__)
	bool AllocDualMap(size_t size, JitAlloc* out)
	{
		AYS3JitMode mode = ays3_detect_jit_mode();

		void* direct = mmap(nullptr, size, PROT_READ | PROT_WRITE | PROT_EXEC,
			MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
		if (direct != MAP_FAILED)
		{
			LogAppend("mmap(MAP_JIT) succeeded directly (mode=%s treated as Simulator for this alloc)",
				ays3_jit_mode_name(mode));
			out->rx = direct;
			out->size = size;
			out->rw_offset = 0;
			out->legacy_toggle = false; // pthread_jit_write_protect_np path, not mprotect
			return true;
		}
		LogAppend("mmap(MAP_JIT) direct failed (err=%d), falling back to mode=%s", errno, ays3_jit_mode_name(mode));

#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
		if (mode == AYS3JitModeLegacy)
		{
			void* ptr = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
			if (ptr == MAP_FAILED)
			{
				LogAppend("legacy mmap(RW) failed (err=%d)", errno);
				return false;
			}
			LogAppend("legacy mmap(RW) ok at %p, will mprotect toggle to RX before execution", ptr);
			out->rx = ptr;
			out->size = size;
			out->rw_offset = 0;
			out->legacy_toggle = true;
			return true;
		}

		void* rx_ptr = mmap(nullptr, size, PROT_READ | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);
		if (rx_ptr == MAP_FAILED)
		{
			LogAppend("dual-map RX mmap failed (err=%d)", errno);
			return false;
		}
		LogAppend("dual-map RX region allocated at %p", rx_ptr);

		if (mode == AYS3JitModeLuckTXM)
		{
			static sigjmp_buf s_jmp;
			struct sigaction sa = {}, old_sa = {};
			sa.sa_handler = +[](int) { siglongjmp(s_jmp, 1); };
			sigemptyset(&sa.sa_mask);
			sigaction(SIGTRAP, &sa, &old_sa);

			bool ok = false;
			if (sigsetjmp(s_jmp, 1) == 0)
			{
				JIT26PrepareRegion(rx_ptr, size);
				LogAppend("brk #0xf00d prepare-region handshake acknowledged");
				if (sigsetjmp(s_jmp, 1) == 0)
				{
					JIT26Detach();
					ok = true;
					LogAppend("brk #0xf00d detach acknowledged");
				}
				else
				{
					LogAppend("brk #0xf00d detach raised SIGTRAP (no debugger attached to intercept it)");
				}
			}
			else
			{
				LogAppend("brk #0xf00d prepare-region raised SIGTRAP (no debugger attached to intercept it — is StikDebug's JIT enabled for this launch?)");
			}
			sigaction(SIGTRAP, &old_sa, nullptr);

			if (!ok)
			{
				munmap(rx_ptr, size);
				return false;
			}
		}

		vm_address_t rw_region = 0;
		vm_address_t target = reinterpret_cast<vm_address_t>(rx_ptr);
		vm_prot_t cur_protection = 0, max_protection = 0;
		const kern_return_t kr = vm_remap(mach_task_self(), &rw_region, static_cast<vm_size_t>(size), 0,
			VM_FLAGS_ANYWHERE, mach_task_self(), target, false, &cur_protection, &max_protection, VM_INHERIT_DEFAULT);
		if (kr != KERN_SUCCESS)
		{
			LogAppend("vm_remap failed (kr=%d) — this is where TXM most commonly blocks the dual mapping", kr);
			munmap(rx_ptr, size);
			return false;
		}

		void* rw_ptr = reinterpret_cast<void*>(rw_region);
		if (mprotect(rw_ptr, size, PROT_READ | PROT_WRITE) != 0)
		{
			LogAppend("mprotect(RW view) failed (err=%d)", errno);
			vm_deallocate(mach_task_self(), rw_region, static_cast<vm_size_t>(size));
			munmap(rx_ptr, size);
			return false;
		}

		out->rx = rx_ptr;
		out->size = size;
		out->rw_offset = reinterpret_cast<uint8_t*>(rw_ptr) - reinterpret_cast<uint8_t*>(rx_ptr);
		out->rw_dealloc_base = rw_region;
		out->rw_dealloc_size = size;
		out->legacy_toggle = false;
		LogAppend("dual-map established: rx=%p rw=%p (mode=%s)", rx_ptr, rw_ptr, ays3_jit_mode_name(mode));
		return true;
#else
		(void)size;
		return false;
#endif
	}

	void FreeDualMap(const JitAlloc& alloc)
	{
		if (alloc.rw_dealloc_base)
			vm_deallocate(mach_task_self(), static_cast<vm_address_t>(alloc.rw_dealloc_base), static_cast<vm_size_t>(alloc.rw_dealloc_size));
		if (alloc.rx)
			munmap(alloc.rx, alloc.size);
	}

	void BeginWrite(const JitAlloc& alloc)
	{
		if (alloc.rw_offset != 0)
			return; // dual-mapped: RW view is always writable, nothing to toggle
		if (alloc.legacy_toggle)
		{
			mprotect(alloc.rx, alloc.size, PROT_READ | PROT_WRITE);
			return;
		}
		auto func = reinterpret_cast<void (*)(int)>(dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np"));
		if (func)
			func(0);
	}

	void EndWrite(const JitAlloc& alloc)
	{
		if (alloc.rw_offset != 0)
			return;
		if (alloc.legacy_toggle)
		{
			mprotect(alloc.rx, alloc.size, PROT_READ | PROT_EXEC);
			return;
		}
		auto func = reinterpret_cast<void (*)(int)>(dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np"));
		if (func)
			func(1);
	}
#endif // __APPLE__
} // namespace

int ays3_run_jit_stub(void)
{
	LogReset();
#if !defined(__APPLE__)
	LogAppend("not an Apple platform, nothing to probe");
	return 0;
#else
	LogAppend("cs_debugged=%d", ays3_is_cs_debugged());
	LogAppend("jit_mode=%s", ays3_jit_mode_name(ays3_detect_jit_mode()));

	const size_t page = static_cast<size_t>(getpagesize());
	JitAlloc alloc;
	if (!AllocDualMap(page, &alloc))
	{
		LogAppend("RESULT: FAIL (could not obtain executable memory)");
		return 0;
	}

	// arm64: `mov w0, #42` (0x52800540) ; `ret` (0xD65F03C0), little-endian.
	const uint8_t stub[] = {0x40, 0x05, 0x80, 0x52, 0xC0, 0x03, 0x5F, 0xD6};

	BeginWrite(alloc);
	void* write_ptr = reinterpret_cast<uint8_t*>(alloc.rx) + alloc.rw_offset;
	std::memcpy(write_ptr, stub, sizeof(stub));
	EndWrite(alloc);

	sys_icache_invalidate(alloc.rx, sizeof(stub));

	auto fn = reinterpret_cast<int (*)(void)>(alloc.rx);
	LogAppend("calling stub at %p", alloc.rx);
	const int result = fn();
	LogAppend("stub returned %d (expected 42)", result);

	FreeDualMap(alloc);

	const bool ok = (result == 42);
	LogAppend("RESULT: %s", ok ? "PASS" : "FAIL");
	return ok ? 1 : 0;
#endif
}

const char* ays3_last_stub_log(void)
{
	return s_log;
}
