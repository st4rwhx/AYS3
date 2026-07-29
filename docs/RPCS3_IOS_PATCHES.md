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

## Wall #4 — LLVM not found (configure)

- **Where:** `3rdparty/llvm/CMakeLists.txt:69` → `FATAL_ERROR "Can't find LLVM
  libraries..."` after `Could NOT find LLVM (missing: LLVM_DIR)`.
- **Cause:** `BUILD_LLVM` defaults OFF, so RPCS3 looks for a prebuilt/system
  LLVM (none exists for iOS).
- **Fix:** `-DBUILD_LLVM=ON` → build LLVM from the bundled submodule
  (`3rdparty/llvm/llvm`, targets `AArch64;X86`).
- **Watch next:** cross-compiling LLVM for iOS typically needs a **native
  `llvm-tblgen`** (host tool) via `-DLLVM_TABLEGEN=...`. If the LLVM subproject
  configure demands native tools, add a host-tblgen pre-build step.

## Wall #5 — LLVM cross-compile needs native tblgen (configure)

- **Where:** `3rdparty/llvm/llvm/llvm/cmake/modules/TableGen.cmake:239` →
  `install TARGETS given no BUNDLE DESTINATION for MACOSX_BUNDLE executable
  target "llvm-tblgen"`.
- **Cause:** cross-compiling LLVM auto-starts a NATIVE sub-build, but under the
  iOS toolchain it inherits `CMAKE_MACOSX_BUNDLE=ON`, so llvm-tblgen's install
  rule wants a bundle destination.
- **Fix:** build `llvm-tblgen`/`llvm-min-tblgen` natively (host macOS) in a
  separate step, then pass `-DLLVM_NATIVE_TOOL_DIR=<bin>` and
  `-DLLVM_TABLEGEN=<bin>/llvm-tblgen` so the iOS build uses the prebuilt host
  tools instead of trying to build+install them in the iOS tree.

## Wall #6 — CURL not found (configure)

- **Where:** `3rdparty/curl/CMakeLists.txt:5` → `Could NOT find CURL`.
- **Cause:** `USE_SYSTEM_CURL` defaults ON → `find_package(CURL REQUIRED)`; no
  system libcurl for iOS.
- **Fix:** `-DUSE_SYSTEM_CURL=OFF` → RPCS3 builds bundled libcurl + WolfSSL
  statically (HTTP-only), which supports iOS.

## Wall #5b — llvm-tblgen MACOSX_BUNDLE install (configure)

- **Symptom persisted** even with `LLVM_NATIVE_TOOL_DIR`/`LLVM_TABLEGEN`: LLVM
  still declared the tblgen target and its install rule fataled under
  `MACOSX_BUNDLE`.
- **Root cause:** `ios.toolchain.cmake` only sets `CMAKE_MACOSX_BUNDLE=YES`
  `if (NOT DEFINED CMAKE_MACOSX_BUNDLE)`.
- **Fix:** pass `-DCMAKE_MACOSX_BUNDLE=OFF` (we build a static core lib, not a
  desktop `.app`; the real iOS app target sets bundling itself later).

## Wall #7 (strategic) — RPCS3 is a monolithic Qt app; build the core only

- **Where:** `3rdparty/qt6.cmake:47` → `FATAL_ERROR` "You need Qt6 installed"
  (there is no Qt6 for iOS), reached via `rpcs3/CMakeLists.txt` including
  `qt6.cmake`.
- **Key insight:** RPCS3 already ships a **Qt-less path — the Android build**.
  `rpcs3/CMakeLists.txt` guards the Qt include, the `rpcs3qt` frontend, and the
  desktop executable behind `if (NOT ANDROID)`, while `add_subdirectory(Emu)`
  (the `rpcs3_emu` core) is always built.
- **Fix / strategy:** gate those same three blocks on `AYS3_CORE_ONLY` too
  (`if (NOT ANDROID AND NOT AYS3_CORE_ONLY)`) and pass `-DAYS3_CORE_ONLY=ON`, so
  iOS configures/builds **only the Emu core** — exactly like Android. AYS3
  provides its own Swift UI on top; the Qt desktop frontend is never used on
  iOS. This is both the correct architecture and a big speed-up (no Qt, no
  frontend to fight or compile).

## Build phase — LLVM (arm64) compiled; core-compile errors, batched

LLVM cross-compiled fully; the build reached the RPCS3 Emu core. `ninja -k 0`
collected the errors; grouped:

- **-Werror (return-type, implicit-fallthrough)** in PPUDisAsm/SPUThread/atomic/
  bin_patch → neutralize `-Werror` in `buildfiles/cmake/ConfigureCompiler.cmake`.
- **`std::to_chars` unavailable (iOS 16.3)** in Config.cpp → bump
  `DEPLOYMENT_TARGET` 16.0 → 16.3.
- **`std::ranges::views::join` missing** (openal-soft) → skip OpenAL on iOS
  (define WITHOUT_OPENAL like Android); headless core needs no audio.
- **`vulkan/vulkan.h` not found** (RSX/VK) → `USE_VULKAN=OFF` for this milestone
  (Null renderer); rendering re-added later with proper Vulkan-Headers include.
- **`pthread_jit_write_protect_np` unavailable on iOS** (JIT.h / JITASM.cpp /
  JITLLVM.cpp) → **the JIT W^X wall**, handled deliberately next (this is the
  make-or-break iOS-JIT bring-up, AYS2's specialty). Left in place for now so
  the rest of the core keeps compiling under `ninja -k 0`.

## Wall #10 — the JIT: pthread_jit_write_protect_np unavailable on iOS (build)

- **Where:** JIT.h / JITASM.cpp / JITLLVM.cpp / SPU*Recompiler.cpp / SPUThread.cpp
  / AArch64JIT.cpp / asmjit virtmem.cpp — 132 hard "unavailable" errors.
- **Cause:** the SDK header marks `pthread_jit_write_protect_np` as
  `API_UNAVAILABLE(ios)`, so *using* it is an error even though the symbol
  exists in libSystem at runtime (it's the W^X toggle used with MAP_JIT).
- **Fix:** rename call sites to `ays3_jit_wp`, a force-included shim that
  resolves the real symbol via `dlsym` (bypassing the header attribute). Under
  the debugger-enabled RWX JIT the toggle isn't strictly needed, so a missing
  symbol degrades to a safe no-op.

## Wall #11 — desktop audio backends (build)

- **cubeb** `cubeb_audiounit.c` uses the macOS CoreAudio HAL
  (`CoreAudio/AudioHardware.h`, `AudioObjectPropertyAddress`) absent on iOS →
  `-DUSE_AUDIOUNIT=OFF` so the bundled cubeb builds without the desktop backend
  (null output — fine for a headless core).
- **FAudio** not needed headless → `-DUSE_FAUDIO=OFF`.
- **OpenAL `alc.h`**: still referenced by some RPCS3 file after WITHOUT_OPENAL;
  pin the exact includer from the next build log and guard it.

## Superseded / notes

- **cubeb** `cubeb_audiounit.cpp`: uses the macOS CoreAudio HAL
  (`CoreAudio/AudioHardware.h`, `AudioObjectPropertyAddress`) absent on iOS.
- **OpenAL** `alc.h` still referenced somewhere despite WITHOUT_OPENAL.
- `std::ranges::contains` / C++23 range adaptors in a few spots.
- A headless core needs no audio, so strip these backends (Android-style) next.

## Wall #14 — bundled ffmpeg is prebuilt for macOS (Phase 2 link)

- **Where:** probe link → `ld: building for 'iOS', but linking in object file
  (.spike/build-ios/3rdparty/ffmpeg/lib/libavformat.a[arm64][2](aacdec.o)) built
  for 'macOS'`.
- **Cause:** RPCS3's builtin ffmpeg is the **`RPCS3/ffmpeg-core`** submodule. Its
  `CMakeLists.txt` DOWNLOADS a prebuilt zip per host (`ffmpeg-macos-arm64.zip` on
  Apple Silicon) and extracts the `.a` to `${CMAKE_BINARY_DIR}/3rdparty/ffmpeg/lib`;
  RPCS3's `3rdparty/CMakeLists.txt` then `find_library()`s
  `avformat/avcodec/avutil/swscale/swresample` there. Those objects are **macOS**,
  not iOS → the iOS probe can't link them. (ffmpeg-core is ffmpeg 8.0 —
  `LIBAVCODEC_VERSION_MAJOR 62`.)
- **Key insight:** RPCS3 only calls ffmpeg's **stable public C API**
  (`avcodec_*`/`avformat_*`/`sws_*`/`swr_*`), which is present in the libraries
  regardless of which codecs/demuxers are compiled in. So a **minimal,
  self-contained iOS static ffmpeg** supplies every symbol the core references —
  no need to reproduce ffmpeg-core's full codec set for a *link/boot* milestone.
- **Fix:** cross-compile ffmpeg 8.0 for `arm64-apple-ios` in the spike
  (`--enable-cross-compile --target-os=darwin --arch=arm64` + iphoneos
  clang/sysroot, `--disable-asm` to drop cross-assembler risk, Apple-framework
  backends disabled so the `.a` stay self-contained), then **swap** our 5 iOS
  `.a` over the extracted macOS ones in `build-ios/3rdparty/ffmpeg/lib` right
  before the `ninja ays3_probe` link (same filenames → the resolved link paths
  are reused). The core's ffmpeg-using files already compiled fine against the
  committed headers, so only the libraries need replacing.
- **Later:** re-enable the specific decoders cellVdec/ATRAC need (M2V/AVC, etc.)
  once we're past headless boot — trivial config change, more build time.

## Noted for later (not yet fatal)

- MoltenVK was **found/built** from the submodule, but Vulkan reports
  `missing components: glslc glslangValidator` — a SPIR-V shader-compiler
  dependency that may become a build-phase wall.
