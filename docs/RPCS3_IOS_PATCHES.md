# RPCS3 → iOS patches (Phase 1 log)

Each entry is a configure/build wall found by the Phase 1 spike and the minimal
change that clears it. Patches are applied in `scripts/phase1-configure.sh`
(`patch_rpcs3`) as small in-place edits so they survive RPCS3 master drift.

## Wall #1 — libusb rejects iOS (configure)

- **Where:** `3rdparty/libusb/os.cmake` → `message(FATAL_ERROR "Unsupported
  platform iOS...")`.
- **Cause:** the `elseif (APPLE)` branch only fills `PLATFORM_SRC` when
  `CMAKE_SYSTEM_NAME STREQUAL "Darwin"`. The iOS CMake toolchain sets
  `CMAKE_SYSTEM_NAME = iOS`, so the branch runs (APPLE is true) but leaves
  `PLATFORM_SRC` empty → fatal.
- **Fix (now):** let iOS reuse the Darwin/IOKit backend
  (`... OR CMAKE_SYSTEM_NAME STREQUAL "iOS"`) so configure proceeds.
- **Caveat:** `darwin_usb.c` uses IOKit USB APIs that are largely unavailable in
  the iOS SDK, so this will likely fail to *compile* later. iOS can't do raw USB
  device access anyway. The proper long-term fix is to **stub out libusb** (no
  USB pad handlers on iOS). We take the minimal patch now to reveal the next
  configure wall; libusb stubbing is tracked for the build phase.
