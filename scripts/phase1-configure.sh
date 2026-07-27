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
  local osc="${RPCS3_DIR}/3rdparty/libusb/os.cmake"
  if [ -f "${osc}" ] && ! grep -q 'STREQUAL "iOS"' "${osc}"; then
    sed -i.bak 's/if (CMAKE_SYSTEM_NAME STREQUAL "Darwin")/if (CMAKE_SYSTEM_NAME STREQUAL "Darwin" OR CMAKE_SYSTEM_NAME STREQUAL "iOS")/' "${osc}"
    echo "  patched libusb/os.cmake for iOS: $(grep -c 'STREQUAL "iOS"' "${osc}") hit(s)"
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
    grep -rlZ 'pthread_jit_write_protect_np' \
        "${RPCS3_DIR}/rpcs3" "${RPCS3_DIR}/Utilities" "${RPCS3_DIR}/3rdparty/asmjit" \
        --include=*.cpp --include=*.h --include=*.hpp 2>/dev/null \
      | xargs -0 -r sed -i.bak 's/pthread_jit_write_protect_np/ays3_jit_wp/g'
    echo "  JIT: shim written + renamed pthread_jit_write_protect_np -> ays3_jit_wp"
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
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_MACOSX_BUNDLE=OFF \
  -DCMAKE_C_FLAGS="-include ${WORK}/ays3_ios_jit_shim.h" \
  -DCMAKE_CXX_FLAGS="-include ${WORK}/ays3_ios_jit_shim.h" \
  -DAYS3_CORE_ONLY=ON \
  -DUSE_NATIVE_INSTRUCTIONS=OFF \
  -DUSE_SYSTEM_FFMPEG=OFF \
  -DUSE_SYSTEM_SDL=OFF \
  -DUSE_SYSTEM_CURL=OFF \
  -DWITH_LLVM=ON \
  -DBUILD_LLVM=ON \
  -DLLVM_TARGETS_TO_BUILD=AArch64 \
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
else
  echo "iOS configure did not succeed (exit ${IOS_CFG_EXIT}); skipping build."
fi

echo "== Phase 1 spike done. Logs in ${LOG_DIR}. =="
echo "First iOS-configure error lines:"
grep -iE "error|fatal|not found|required|CMake Error" "${LOG_DIR}/20-configure-ios.log" | head -40 || true
