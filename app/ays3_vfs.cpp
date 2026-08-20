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
#include "Emu/VFS.h"
#include "Loader/PUP.h"
#include "Loader/TAR.h"
#include "Crypto/unself.h"
#include "util/fs.hpp"
#include "util/types.hpp"
#include <algorithm>
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

// Headless port of main_window::InstallPup (step 4b): unpack a PS3UPDAT.PUP into
// dev_flash using only core primitives (no Qt). Returns 0 on success, negative
// on failure at each stage. The Qt version's progress dialog / logging is
// dropped; the crypto + tar logic is reproduced faithfully.
extern "C" int ips3_core_install_firmware(const char* pup_path)
{
	if (!pup_path || !*pup_path) return -1;

	fs::file pup_f(pup_path);
	if (!pup_f) return -2;

	pup_object pup(std::move(pup_f));
	if (pup.operator pup_error() != pup_error::ok) return -3;

	fs::file update_files_f = pup.get_file(0x300);
	if (!update_files_f || !update_files_f.size()) return -4;

	tar_object update_files(update_files_f);

	auto update_filenames = update_files.get_filenames();
	update_filenames.erase(std::remove_if(update_filenames.begin(), update_filenames.end(),
		[](const std::string& s) { return s.find("dev_flash_") == umax; }), update_filenames.end());
	if (update_filenames.empty()) return -5;

	vfs::mount("/dev_flash", g_cfg_vfs.get_dev_flash());

	for (const auto& update_filename : update_filenames)
	{
		auto update_file_stream = update_files.get_file(update_filename);
		if (update_file_stream->m_file_handler)
		{
			update_file_stream->m_file_handler->handle_file_op(
				*update_file_stream, 0, update_file_stream->get_size(umax), nullptr);
		}

		fs::file update_file = fs::make_stream(std::move(update_file_stream->data));

		SCEDecrypter self_dec(update_file);
		self_dec.LoadHeaders();
		self_dec.LoadMetadata(SCEPKG_ERK, SCEPKG_RIV);
		self_dec.DecryptData();

		auto dev_flash_tar_f = self_dec.MakeFile();
		if (dev_flash_tar_f.size() < 3) return -6;

		tar_object dev_flash_tar(dev_flash_tar_f[2]);
		if (!dev_flash_tar.extract()) return -7;
	}

	return 0;
}
