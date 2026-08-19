// iPS3 bridging header — the C ABI the Swift side calls to drive the PS3 core.
//
// Kept to a flat C interface on purpose: Swift imports this header directly (no
// C++ interop needed), while the implementation (PS3Core.mm) is Obj-C++ that
// talks to the linked core's Emulator global. This is the seam between the SwiftUI
// frontend and the linked core — the heart of merging the two apps into one.

#ifndef IPS3_BRIDGING_HEADER_H
#define IPS3_BRIDGING_HEADER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Initialise the core (Emulator::Init). Safe to call once at startup.
void ips3_core_init(void);

// Boot a game by filesystem path (decrypted or encrypted-with-key ISO, a
// decrypted game folder, or a package). Returns the core's game_boot_result as
// an int: 0 == no_errors. Until the VFS + firmware are configured this reports
// how far boot gets rather than actually running a title.
int ips3_core_boot(const char* path);

// Human-readable name for a game_boot_result int (for logs / on-screen status).
const char* ips3_core_boot_result_name(int result);

// Resident footprint in MB (phys_footprint — the value iOS jetsam charges for).
double ips3_core_footprint_mb(void);

#ifdef __cplusplus
}
#endif

#endif // IPS3_BRIDGING_HEADER_H
