#!/usr/bin/env bash
# AYS3 Phase 1 — de-risk the toolchain.
# Attempt to CONFIGURE RPCS3 for arm64-apple-ios and record exactly how far it
# gets and what the first real wall is. Configure-only (no full build) so we get
# fast signal on toolchain viability. Every step is best-effort: we WANT to see
# where it breaks, so failures are captured, not fatal.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${ROOT}/.spike"
RPCS3_DIR="${WORK}/rpcs3"
TOOLCHAIN="${WORK}/ios-cmake/ios.toolchain.cmake"
LOG_DIR="${ROOT}/spike-logs"
mkdir -p "${WORK}" "${LOG_DIR}"

# Pin points (override via env in the workflow if needed).
RPCS3_REF="${RPCS3_REF:-master}"
IOS_CMAKE_REF="${IOS_CMAKE_REF:-4.5.0}"

echo "== AYS3 Phase 1 configure spike =="
echo "date: $(date -u)"
uname -a

# --- 1. RPCS3 source (recursive submodules: LLVM, etc.) -----------------------
if [ ! -d "${RPCS3_DIR}/.git" ]; then
  echo "== cloning RPCS3 (${RPCS3_REF}) recursively — this is large =="
  git clone --recursive --depth 1 --shallow-submodules \
    --branch "${RPCS3_REF}" https://github.com/RPCS3/rpcs3 "${RPCS3_DIR}" \
    2>&1 | tee "${LOG_DIR}/00-clone.log" || \
  git clone --recursive --depth 1 --shallow-submodules \
    https://github.com/RPCS3/rpcs3 "${RPCS3_DIR}" \
    2>&1 | tee -a "${LOG_DIR}/00-clone.log"
fi
RPCS3_SHA="$(git -C "${RPCS3_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)"
echo "RPCS3 pinned at: ${RPCS3_SHA}" | tee "${LOG_DIR}/01-rpcs3-sha.txt"

# --- 1b. iOS patches (idempotent) ---------------------------------------------
# Each patch clears one configure wall found by a previous spike run. Kept as
# small in-place edits (robust against RPCS3 master drift) rather than fragile
# patch files. Documented in docs/RPCS3_IOS_PATCHES.md.
patch_rpcs3() {
  echo "== applying iOS patches to RPCS3 tree =="

  # Wall #1: 3rdparty/libusb/os.cmake rejects iOS. The Apple branch only fills
  # PLATFORM_SRC when CMAKE_SYSTEM_NAME == "Darwin"; the iOS toolchain sets it to
  # "iOS". Let iOS reuse the Darwin/IOKit backend so configure proceeds.
  # iOS gets a device-LESS libusb backend: posix threads/events only, no
  # darwin_usb.c (its IOKit USB headers — IOKit/IOCFBundle.h — don't exist on
  # iOS, and iOS can't do raw USB anyway). The generic libusb core still
  # compiles; the missing backend symbol only matters at final executable link
  # (a later phase), not when creating the static core lib.
  local osc="${RPCS3_DIR}/3rdparty/libusb/os.cmake"
  if [ -f "${osc}" ] && ! grep -q 'STREQUAL "iOS"' "${osc}"; then
    perl -0pi -e 's{if \(CMAKE_SYSTEM_NAME STREQUAL "Darwin"\)}{if (CMAKE_SYSTEM_NAME STREQUAL "iOS")\n\t\tset(PLATFORM_SRC threads_posix.c events_posix.c)\n\telseif (CMAKE_SYSTEM_NAME STREQUAL "Darwin")}' "${osc}"
    echo "  patched libusb/os.cmake: iOS device-less backend"
  fi

  # Wall #7 (strategic): RPCS3 is a monolithic Qt desktop app. Its rpcs3/
  # CMakeLists guards Qt + the rpcs3qt frontend + the desktop executable behind
  # `if (NOT ANDROID)`. iOS wants the SAME Qt-less core-only path Android uses.
  # Gate those three blocks on our AYS3_CORE_ONLY flag too, so only the Emu core
  # (rpcs3_emu) is configured — we ship our own Swift UI on top, never Qt.
  local rc="${RPCS3_DIR}/rpcs3/CMakeLists.txt"
  if [ -f "${rc}" ] && ! grep -q 'AYS3_CORE_ONLY' "${rc}"; then
    sed -i.bak 's/if (NOT ANDROID)/if (NOT ANDROID AND NOT AYS3_CORE_ONLY)/g' "${rc}"
    echo "  patched rpcs3/CMakeLists.txt core-only gates: $(grep -c 'AYS3_CORE_ONLY' "${rc}") hit(s)"
  fi

  # Wall #8: skip OpenAL on iOS. openal-soft uses C++23 std::ranges::views::join
  # (absent here) and a headless core needs no audio. The only bare
  # `if (NOT ANDROID)` (with space) in 3rdparty/CMakeLists.txt is the OpenAL
  # block; gating it on AYS3_CORE_ONLY makes iOS take the else branch that
  # defines WITHOUT_OPENAL — exactly what Android does.
  local tp="${RPCS3_DIR}/3rdparty/CMakeLists.txt"
  if [ -f "${tp}" ] && ! grep -q 'AYS3_CORE_ONLY' "${tp}"; then
    sed -i.bak 's/if (NOT ANDROID)/if (NOT ANDROID AND NOT AYS3_CORE_ONLY)/g' "${tp}"
    echo "  patched 3rdparty/CMakeLists.txt (OpenAL skip): $(grep -c 'AYS3_CORE_ONLY' "${tp}") hit(s)"
  fi

  # Wall #9: RPCS3 builds with -Werror; iOS-only warnings (return-type,
  # implicit-fallthrough) become fatal. Downgrade -Werror=* to plain -W* and drop
  # bare -Werror so warnings don't stop the build.
  local cc="${RPCS3_DIR}/buildfiles/cmake/ConfigureCompiler.cmake"
  if [ -f "${cc}" ] && grep -q 'Werror' "${cc}"; then
    sed -i.bak -E 's/-Werror=/-W/g; s/-Werror//g' "${cc}"
    echo "  neutralized -Werror in ConfigureCompiler.cmake"
  fi

  # Wall #10 (THE JIT bring-up): pthread_jit_write_protect_np is
  # API_UNAVAILABLE(ios) in the SDK header, so every call is a hard "unavailable"
  # error (132 of them), even though the symbol EXISTS in libSystem at runtime.
  # Rename RPCS3/asmjit call sites to our own wrapper ays3_jit_wp, defined in a
  # force-included shim that resolves the real symbol via dlsym (bypassing the
  # header attribute). On iOS the debugger-enabled JIT region is RWX, so if the
  # symbol is unavailable the wrapper is a safe no-op.
  if ! grep -rqs 'ays3_jit_wp' "${RPCS3_DIR}/Utilities/JIT.h" 2>/dev/null; then
    cat > "${WORK}/ays3_ios_jit_shim.h" <<'SHIM'
#pragma once
#if defined(__APPLE__)
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#include <dlfcn.h>
// Real pthread_jit_write_protect_np is marked unavailable for iOS in the SDK
// header but exists at runtime; reach it via dlsym. RWX JIT (debugger) makes it
// a no-op when absent.
static inline int ays3_jit_wp(int enabled) {
    typedef int (*ays3_jit_wp_fn)(int);
    /* C requires a compile-time-constant initializer for a static local, so
       resolve lazily (valid in both C and C++). */
    static ays3_jit_wp_fn fn = 0;
    static int resolved = 0;
    if (!resolved) {
        fn = (ays3_jit_wp_fn)dlsym((void*)-2 /*RTLD_DEFAULT*/, "pthread_jit_write_protect_np");
        resolved = 1;
    }
    return fn ? fn(enabled) : 0;
}
#endif
#endif
SHIM
    # NOTE: macOS xargs has no -r (GNU-only); a for-loop over `grep -rl` is
    # portable. RPCS3 paths contain no spaces.
    local jf
    for jf in $(grep -rl 'pthread_jit_write_protect_np' \
        "${RPCS3_DIR}/rpcs3" "${RPCS3_DIR}/Utilities" "${RPCS3_DIR}/3rdparty/asmjit" \
        --include=*.cpp --include=*.h --include=*.hpp 2>/dev/null); do
      sed -i.bak 's/pthread_jit_write_protect_np/ays3_jit_wp/g' "${jf}"
    done
    echo "  JIT: shim written + renamed in $(grep -rl 'ays3_jit_wp' "${RPCS3_DIR}/rpcs3" "${RPCS3_DIR}/Utilities" "${RPCS3_DIR}/3rdparty/asmjit" --include=*.cpp --include=*.h --include=*.hpp 2>/dev/null | wc -l | tr -d ' ') file(s)"
  fi

  # Wall #13: asmjit's virtmem.cpp calls sys_icache_invalidate but doesn't pull
  # its header on iOS. Add it ONLY here (a global force-include would clash with
  # LLVM's own sys_icache_invalidate declaration in Memory.inc).
  # asmjit already includes OSCacheControl.h but only under a macOS-only guard,
  # so on iOS sys_icache_invalidate is used undeclared. Prepend an unconditional
  # Apple include at the very top (own sentinel; header guards make the later
  # guarded include a no-op).
  local vm="${RPCS3_DIR}/3rdparty/asmjit/asmjit/src/asmjit/core/virtmem.cpp"
  if [ -f "${vm}" ] && ! grep -q 'AYS3_ICACHE_SHIM' "${vm}"; then
    perl -0pi -e 's/\A/\/\/ AYS3_ICACHE_SHIM\n#if defined(__APPLE__)\n#include <libkern\/OSCacheControl.h>\n#endif\n/' "${vm}"
    echo "  asmjit virtmem: added OSCacheControl.h"
  fi

  # Phase 2: a link probe target that force-loads librpcs3_emu.a so the linker
  # must resolve ALL core symbols on iOS (surfaces deferred undefined deps).
  local rc2="${RPCS3_DIR}/rpcs3/CMakeLists.txt"
  if [ -f "${rc2}" ] && ! grep -q 'ays3_probe' "${rc2}"; then
    cat > "${RPCS3_DIR}/rpcs3/ays3_probe.cpp" <<'PROBE'
#include <cstdio>
// Force-loaded against librpcs3_emu.a; entry point just proves the core links.
int main() { std::printf("AYS3 probe: rpcs3_emu linked for iOS\n"); return 0; }
PROBE
    cat >> "${rc2}" <<'CM'

# AYS3 Phase 2 link probe (added by scripts/phase1-configure.sh)
if(AYS3_PROBE)
    add_executable(ays3_probe ${CMAKE_CURRENT_SOURCE_DIR}/ays3_probe.cpp)
    target_link_libraries(ays3_probe PRIVATE rpcs3_emu)
    target_link_options(ays3_probe PRIVATE "SHELL:-Wl,-force_load,$<TARGET_FILE:rpcs3_emu>")
endif()
CM
    echo "  Phase 2: added ays3_probe link target"
  fi
}
patch_rpcs3 2>&1 | tee "${LOG_DIR}/03-patches.log"

# --- 2. iOS CMake toolchain (leetal/ios-cmake) --------------------------------
mkdir -p "$(dirname "${TOOLCHAIN}")"
if [ ! -f "${TOOLCHAIN}" ]; then
  echo "== fetching ios-cmake ${IOS_CMAKE_REF} =="
  curl -fsSL -o "${TOOLCHAIN}" \
    "https://raw.githubusercontent.com/leetal/ios-cmake/${IOS_CMAKE_REF}/ios.toolchain.cmake" \
    2>&1 | tee "${LOG_DIR}/02-toolchain-fetch.log" || echo "toolchain fetch FAILED"
fi
[ -f "${TOOLCHAIN}" ] && echo "toolchain: ${TOOLCHAIN} ($(wc -l < "${TOOLCHAIN}") lines)"

# --- 2c. Stub librt.a: something in the link graph adds -lrt (Linux realtime
# lib). On iOS clock_gettime/shm_open live in libSystem, so an empty arm64-iOS
# librt.a satisfies the -lrt flag with no missing symbols. Added to the linker
# search path for all executables (the probe and, later, the app).
STUBLIBS="${WORK}/stublibs"
mkdir -p "${STUBLIBS}"
if [ ! -f "${STUBLIBS}/librt.a" ]; then
  echo 'static int ays3_rt_stub;' > "${STUBLIBS}/rt.c"
  xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=16.3 \
    -c "${STUBLIBS}/rt.c" -o "${STUBLIBS}/rt.o" 2>/dev/null && \
  ar rcs "${STUBLIBS}/librt.a" "${STUBLIBS}/rt.o" && echo "stub librt.a created"
fi

# --- 2d. Cross-compile FFmpeg for arm64-apple-ios -----------------------------
# Wall #14: RPCS3's bundled ffmpeg is the `RPCS3/ffmpeg-core` submodule, which
# DOWNLOADS a prebuilt zip per host (`ffmpeg-macos-arm64.zip` on Apple Silicon)
# and RPCS3 links libav{format,codec,util},libsw{scale,resample} from it. Those
# objects are built for macOS, so the probe link fails: "building for 'iOS', but
# linking in object file built for 'macOS'". RPCS3 only calls ffmpeg's stable
# PUBLIC C API (avcodec_*/avformat_*/sws_*/swr_*), which is present regardless of
# which codecs are compiled in — so a minimal, self-contained iOS static build
# provides every symbol RPCS3 needs. We build ffmpeg 8.0 (matches ffmpeg-core:
# LIBAVCODEC_VERSION_MAJOR 62) and later swap our .a over the extracted macOS
# ones. asm is disabled: this milestone is LINK/boot, not decode perf, and it
# removes all cross-assembler risk. Apple-framework backends are disabled so the
# static libs stay self-contained (no VideoToolbox/CoreImage/etc. link deps).
FFMPEG_IOS="${WORK}/ffmpeg-ios"     # install prefix (lib/ + include/)
FFMPEG_SRC="${WORK}/ffmpeg-src"
FFMPEG_REF="${FFMPEG_REF:-n8.0}"
if [ ! -f "${FFMPEG_IOS}/lib/libavcodec.a" ]; then
  echo "== cross-compiling ffmpeg ${FFMPEG_REF} for arm64-apple-ios =="
  if [ ! -d "${FFMPEG_SRC}/.git" ]; then
    git clone --depth 1 --branch "${FFMPEG_REF}" \
      https://github.com/FFmpeg/FFmpeg "${FFMPEG_SRC}" \
      2>&1 | tee "${LOG_DIR}/17-ffmpeg-clone.log" || echo "ffmpeg clone FAILED"
  fi
  if [ -d "${FFMPEG_SRC}" ]; then
    IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
    ( cd "${FFMPEG_SRC}" && \
      ./configure \
        --prefix="${FFMPEG_IOS}" \
        --enable-cross-compile \
        --target-os=darwin \
        --arch=arm64 \
        --sysroot="${IOS_SDK}" \
        --cc="xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=16.3" \
        --as="xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=16.3" \
        --ar="xcrun --sdk iphoneos ar" \
        --ranlib="xcrun --sdk iphoneos ranlib" \
        --extra-cflags="-arch arm64 -miphoneos-version-min=16.3 -fno-common" \
        --extra-ldflags="-arch arm64 -miphoneos-version-min=16.3" \
        --enable-static --disable-shared --enable-pic \
        --disable-asm \
        --disable-programs --disable-doc --disable-debug \
        --disable-network --disable-autodetect --disable-everything \
        --disable-videotoolbox --disable-audiotoolbox --disable-avfoundation \
        --disable-coreimage --disable-securetransport --disable-metal \
        --disable-iconv --disable-sdl2 --disable-zlib --disable-bzlib \
        --disable-lzma --disable-xlib \
      2>&1 | tee "${LOG_DIR}/18-ffmpeg-configure.log" ) || echo "ffmpeg configure FAILED"
    make -C "${FFMPEG_SRC}" -j3 2>&1 | tee "${LOG_DIR}/19-ffmpeg-build.log" \
      && make -C "${FFMPEG_SRC}" install 2>&1 | tee -a "${LOG_DIR}/19-ffmpeg-build.log" \
      || echo "ffmpeg build/install FAILED"
  fi
fi
if [ -f "${FFMPEG_IOS}/lib/libavcodec.a" ]; then
  echo "ffmpeg-ios libs: $(ls "${FFMPEG_IOS}/lib"/*.a | tr '\n' ' ')"
  xcrun lipo -info "${FFMPEG_IOS}/lib/libavcodec.a" || true
else
  echo "ffmpeg-ios build ABSENT — probe will still hit the macOS-ffmpeg wall"
fi

# --- 2b. Host llvm-tblgen (cross-compiling LLVM to iOS needs native tools) -----
# When BUILD_LLVM cross-compiles LLVM for iOS, the table-gen tools must run on
# the build host. LLVM auto-starts a NATIVE sub-build, but under the iOS
# toolchain that sub-build inherits CMAKE_MACOSX_BUNDLE=ON and its llvm-tblgen
# install() fatals ("no BUNDLE DESTINATION"). Build the tblgens natively here
# and point the iOS configure at them via LLVM_NATIVE_TOOL_DIR/LLVM_TABLEGEN.
LLVM_SRC="${RPCS3_DIR}/3rdparty/llvm/llvm/llvm"
HOST_TOOLDIR=""
if [ -d "${LLVM_SRC}" ]; then
  echo "== building host llvm-tblgen / llvm-min-tblgen =="
  cmake -S "${LLVM_SRC}" -B "${WORK}/llvm-native" -G Ninja \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_TARGETS_TO_BUILD=AArch64 \
    -DLLVM_ENABLE_PROJECTS="" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    2>&1 | tee "${LOG_DIR}/15-llvm-native-configure.log"
  cmake --build "${WORK}/llvm-native" --target llvm-tblgen llvm-min-tblgen -j3 \
    2>&1 | tee "${LOG_DIR}/16-llvm-native-build.log" || \
  cmake --build "${WORK}/llvm-native" --target llvm-tblgen -j3 \
    2>&1 | tee -a "${LOG_DIR}/16-llvm-native-build.log"
  if [ -x "${WORK}/llvm-native/bin/llvm-tblgen" ]; then
    HOST_TOOLDIR="${WORK}/llvm-native/bin"
    echo "host tools: ${HOST_TOOLDIR} ($(ls "${HOST_TOOLDIR}" | tr '\n' ' '))"
  else
    echo "host tblgen build FAILED — iOS LLVM configure will likely still hit the tblgen wall"
  fi
fi

# --- 3. iOS arm64 configure (THE spike) ---------------------------------------
# Flags explained:
#   USE_SYSTEM_SDL=OFF          -> build the bundled static SDL3 (system SDL3 is
#                                  absent and would be a macOS lib anyway)
#   CMAKE_POLICY_VERSION_MINIMUM -> let CMake 4.x accept old 3rdparty projects
#                                  that declare cmake_minimum_required < 3.5
echo "== arm64-apple-ios configure (the real Phase 1 target) =="
cmake -S "${RPCS3_DIR}" -B "${WORK}/build-ios" -G Ninja \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN}" \
  -DPLATFORM=OS64 \
  -DDEPLOYMENT_TARGET=16.3 \
  -DENABLE_BITCODE=OFF \
  -DUSE_VULKAN=OFF \
  -DUSE_FAUDIO=OFF \
  -DUSE_AUDIOUNIT=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_MACOSX_BUNDLE=OFF \
  -DCMAKE_C_FLAGS="-include ${WORK}/ays3_ios_jit_shim.h" \
  -DCMAKE_CXX_FLAGS="-include ${WORK}/ays3_ios_jit_shim.h -I${RPCS3_DIR}/3rdparty/OpenAL/openal-soft/include -I${RPCS3_DIR}/3rdparty/OpenAL/openal-soft/include/AL" \
  -DAYS3_CORE_ONLY=ON \
  -DAYS3_PROBE=ON \
  -DCMAKE_EXE_LINKER_FLAGS="-L${STUBLIBS}" \
  -DUSE_SYSTEM_ZSTD=OFF \
  -DCURL_ZSTD=OFF \
  -DCURL_BROTLI=OFF \
  -DUSE_NGHTTP2=OFF \
  -DUSE_NATIVE_INSTRUCTIONS=OFF \
  -DUSE_SYSTEM_FFMPEG=OFF \
  -DUSE_SYSTEM_SDL=OFF \
  -DUSE_SYSTEM_CURL=OFF \
  -DWITH_LLVM=ON \
  -DBUILD_LLVM=ON \
  -DLLVM_TARGETS_TO_BUILD=AArch64 \
  -DLLVM_ENABLE_ZSTD=OFF \
  -DLLVM_ENABLE_LIBXML2=OFF \
  -DLLVM_ENABLE_TERMINFO=OFF \
  -DLLVM_ENABLE_LIBEDIT=OFF \
  ${HOST_TOOLDIR:+-DLLVM_NATIVE_TOOL_DIR=${HOST_TOOLDIR}} \
  ${HOST_TOOLDIR:+-DLLVM_TABLEGEN=${HOST_TOOLDIR}/llvm-tblgen} \
  2>&1 | tee "${LOG_DIR}/20-configure-ios.log"
IOS_CFG_EXIT=${PIPESTATUS[0]}
echo "iOS configure exit: ${IOS_CFG_EXIT}" | tee -a "${LOG_DIR}/20-configure-ios.log"

# --- 4. iOS core build (collect ALL compile errors in one pass) ---------------
# Configure succeeded, so compile the Emu core with `ninja -k 0` (keep going
# past errors) to gather the FULL list of build failures at once instead of one
# at a time. LLVM (AArch64 only) compiles first, then rpcs3_emu. Long build.
if [ "${IOS_CFG_EXIT}" = "0" ] && [ -f "${WORK}/build-ios/build.ninja" ]; then
  echo "== building rpcs3_emu core for iOS (ninja -k 0) =="
  ninja -C "${WORK}/build-ios" -k 0 -j3 rpcs3_emu \
    2>&1 | tee "${LOG_DIR}/30-build-ios.log"
  echo "iOS build exit: ${PIPESTATUS[0]}" | tee -a "${LOG_DIR}/30-build-ios.log"
  echo "== compile error summary =="
  grep -iE "error:|fatal error|ld: |undefined symbol|ninja: build stopped" "${LOG_DIR}/30-build-ios.log" | head -80 || true

  # --- 5. Phase 2 link probe: force-load rpcs3_emu into an iOS executable so
  # the linker must resolve EVERY core symbol (surfaces the deferred undefined
  # deps like the null libusb backend). "Does the core LINK on iOS?" de-risk.
  if [ -f "${WORK}/build-ios/rpcs3/Emu/librpcs3_emu.a" ]; then
    # Wall #14 swap: RPCS3's configure extracted the prebuilt *macOS* ffmpeg into
    # build-ios/3rdparty/ffmpeg/lib (that's the path find_library() resolved and
    # ninja will link). Overwrite those 5 .a with our arm64-iOS cross-build so the
    # probe links iOS objects. Same filenames → the resolved link paths are reused.
    FF_DST="${WORK}/build-ios/3rdparty/ffmpeg/lib"
    if [ -f "${FFMPEG_IOS}/lib/libavcodec.a" ] && [ -d "${FF_DST}" ]; then
      echo "== swapping macOS ffmpeg → iOS ffmpeg in ${FF_DST} =="
      for l in libavformat libavcodec libavutil libswscale libswresample; do
        if [ -f "${FFMPEG_IOS}/lib/${l}.a" ]; then
          cp -f "${FFMPEG_IOS}/lib/${l}.a" "${FF_DST}/${l}.a"
          echo "  swapped ${l}.a -> $(xcrun lipo -archs "${FF_DST}/${l}.a" 2>/dev/null)"
        else
          echo "  WARN: ${l}.a missing from iOS build"
        fi
      done
    else
      echo "== ffmpeg swap SKIPPED (iOS libs or dst dir absent) =="
    fi

    echo "== linking ays3_probe (force_load rpcs3_emu) =="
    ninja -C "${WORK}/build-ios" -k 0 -j3 ays3_probe \
      2>&1 | tee "${LOG_DIR}/40-link-probe.log"
    echo "probe link exit: ${PIPESTATUS[0]}" | tee -a "${LOG_DIR}/40-link-probe.log"
    echo "== undefined symbols (unique) =="
    grep -oE "\"[^\"]+\", referenced from|Undefined symbols|ld: symbol.*not found|undefined symbol: .*" "${LOG_DIR}/40-link-probe.log" | sort -u | head -60 || true
  fi
else
  echo "iOS configure did not succeed (exit ${IOS_CFG_EXIT}); skipping build."
fi

echo "== Phase 1 spike done. Logs in ${LOG_DIR}. =="
echo "First iOS-configure error lines:"
grep -iE "error|fatal|not found|required|CMake Error" "${LOG_DIR}/20-configure-ios.log" | head -40 || true
