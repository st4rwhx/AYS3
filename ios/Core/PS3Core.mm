// PS3Core.mm — Obj-C++ bridge from the flat C ABI to the linked PS3 core.
//
// Only compiled in the MERGED build (the app target that links the core lib); the
// pure-Swift frontend build never sees this file (it lives under ios/Core/, which
// the frontend CMake does not glob). Declarations mirror just the core symbols we
// call — enough for the mangled names to match — exactly like the app seam.

#include "iPS3-Bridging-Header.h"

#include <string>
#include <optional>
#include <mach/mach.h>

// ---- Minimal mirror of the core Emulator global ---------------------------
// game_boot_result: verbatim from Emu/System.h so we can decode the return code.
enum class game_boot_result : unsigned int {
	no_errors, generic_error, nothing_to_boot, wrong_disc_location,
	invalid_file_or_folder, invalid_bdvd_folder, install_failed,
	decryption_error, file_creation_error, firmware_missing, firmware_version,
	unsupported_disc_type, savestate_corrupted, savestate_version_unsupported,
	still_running, already_added, currently_restricted, database_config_missing,
};
// Only the TYPE NAME drives BootGame's mangling, so an opaque enum is enough;
// we pass mode 0 (the first mode, "custom") via a cast, not a guessed enumerator.
enum class cfg_mode : int;

class Emulator {
public:
	void Init();
	// Exact signature from Emu/System.h (defaults are not part of the symbol).
	game_boot_result BootGame(const std::string& path, const std::string& title_id,
		bool direct, cfg_mode config_mode, const std::string& config_path,
		const std::optional<std::string>& db_config);
};
extern Emulator Emu;

// ---- C ABI ----------------------------------------------------------------

extern "C" void ips3_core_init(void)
{
	Emu.Init();
}

extern "C" int ips3_core_boot(const char* path)
{
	const game_boot_result r = Emu.BootGame(
		std::string(path ? path : ""), std::string(), false,
		static_cast<cfg_mode>(0), std::string(), std::optional<std::string>());
	return static_cast<int>(r);
}

extern "C" const char* ips3_core_boot_result_name(int result)
{
	switch (static_cast<game_boot_result>(result)) {
		case game_boot_result::no_errors:                     return "no_errors";
		case game_boot_result::generic_error:                 return "generic_error";
		case game_boot_result::nothing_to_boot:               return "nothing_to_boot";
		case game_boot_result::wrong_disc_location:           return "wrong_disc_location";
		case game_boot_result::invalid_file_or_folder:        return "invalid_file_or_folder";
		case game_boot_result::invalid_bdvd_folder:           return "invalid_bdvd_folder";
		case game_boot_result::install_failed:                return "install_failed";
		case game_boot_result::decryption_error:              return "decryption_error";
		case game_boot_result::file_creation_error:           return "file_creation_error";
		case game_boot_result::firmware_missing:              return "firmware_missing";
		case game_boot_result::firmware_version:              return "firmware_version";
		case game_boot_result::unsupported_disc_type:         return "unsupported_disc_type";
		case game_boot_result::savestate_corrupted:           return "savestate_corrupted";
		case game_boot_result::savestate_version_unsupported: return "savestate_version_unsupported";
		case game_boot_result::still_running:                 return "still_running";
		case game_boot_result::already_added:                 return "already_added";
		case game_boot_result::currently_restricted:          return "currently_restricted";
		case game_boot_result::database_config_missing:       return "database_config_missing";
	}
	return "unknown";
}

extern "C" double ips3_core_footprint_mb(void)
{
	task_vm_info_data_t info;
	mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
	const kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO,
		reinterpret_cast<task_info_t>(&info), &count);
	if (kr != KERN_SUCCESS) return 0.0;
	return static_cast<double>(info.phys_footprint) / (1024.0 * 1024.0);
}
