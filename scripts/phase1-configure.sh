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

# --- 3. iOS arm64 configure (THE spike) ---------------------------------------
# Flags explained:
#   USE_SYSTEM_SDL=OFF          -> build the bundled static SDL3 (system SDL3 is
#                                  absent and would be a macOS lib anyway)
#   CMAKE_POLICY_VERSION_MINIMUM -> let CMake 4.x accept old 3rdparty projects
#                                  that declare cmake_minimum_required < 3.5
echo "== arm64-apple-ios configure (the real Phase 1 target) =="
cmake -S "${RPCS3_DIR}" -B "${WORK}/build-ios" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN}" \
  -DPLATFORM=OS64 \
  -DDEPLOYMENT_TARGET=16.0 \
  -DENABLE_BITCODE=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DUSE_NATIVE_INSTRUCTIONS=OFF \
  -DUSE_SYSTEM_FFMPEG=OFF \
  -DUSE_SYSTEM_SDL=OFF \
  -DWITH_LLVM=ON \
  -DBUILD_LLVM=ON \
  2>&1 | tee "${LOG_DIR}/20-configure-ios.log"
echo "iOS configure exit: ${PIPESTATUS[0]}" | tee -a "${LOG_DIR}/20-configure-ios.log"

echo "== Phase 1 spike done. Logs in ${LOG_DIR}. =="
echo "First iOS-configure error lines:"
grep -iE "error|fatal|not found|required|CMake Error" "${LOG_DIR}/20-configure-ios.log" | head -40 || true
