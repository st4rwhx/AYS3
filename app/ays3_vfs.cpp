// ays3_vfs.cpp — repoint the core VFS at the writable app sandbox (step 4a).
//
// Unlike the app seam (which re-declares symbols to avoid core headers), this
// file CALLS real core internals (g_cfg_vfs), so it is compiled INSIDE the core
// CMake target with the core's include paths. It exposes a flat C ABI the
// Swift/bridge side calls before Init/Boot.
//
// Why it's required on iOS: the default $(EmulatorDir) resolves to the app
// BUNDLE, which is read-only. dev_flash / dev_hdd0 must live under Documents or
// firmware install, saves, and HDD writes all fail. We set emulator_dir to a
// writable base so every $(EmulatorDir)-relative mount lands in the sandbox.

#include "Emu/vfs_config.h"
#include <string>

extern "C" void ips3_core_setup_vfs(const char* base)
{
	if (!base || !*base) return;
	std::string dir(base);
	if (dir.back() != '/') dir += '/';
	// Base for all $(EmulatorDir)-relative mounts (dev_flash, dev_hdd0, ...).
	g_cfg_vfs.emulator_dir.from_string(dir);
	g_cfg_vfs.save();
}
