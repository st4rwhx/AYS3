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

## Wall #2 — SDL3 not found (configure)

- **Where:** `3rdparty/CMakeLists.txt:223` → `FATAL_ERROR "SDL3 is not available
  on this system"`.
- **Cause:** with `USE_SYSTEM_SDL=ON`, RPCS3 does `find_package(SDL3)` and
  fatals when the system lib is missing. There is no iOS system SDL3.
- **Fix:** `-DUSE_SYSTEM_SDL=OFF` → RPCS3 builds the **bundled static SDL3**
  from its `3rdparty/libsdl-org` submodule, which supports iOS.

## Wall #3 — CMake 4.x rejects old subprojects (configure)

- **Where:** several `CMake Error ... No cmake_minimum_required` /
  "Compatibility with CMake < 3.5 will be removed".
- **Cause:** the macOS runner ships CMake 4.x, which drops compatibility with
  subprojects declaring `cmake_minimum_required(VERSION < 3.5)`.
- **Fix:** `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` globally.

## Noted for later (not yet fatal)

- MoltenVK was **found/built** from the submodule, but Vulkan reports
  `missing components: glslc glslangValidator` — a SPIR-V shader-compiler
  dependency that may become a build-phase wall.
