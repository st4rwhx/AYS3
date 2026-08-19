#!/usr/bin/env bash
# merge-app.sh — step 2b: build the merged SwiftUI app that links the core.
#
# Runs INSIDE the spike job, AFTER the core + ays3_app have built, so build-ios
# holds every archive the recipe (core-link.txt, emitted by step 2a) references
# by build-ios-relative path. SwiftUI cannot compile inside the core's Ninja
# tree, so we build it here by hand:
#   1. swiftc compiles the SwiftUI frontend + the Swift bridge into one object.
#   2. clang++ compiles the Obj-C++ bridge (PS3Core.mm).
#   3. we REPLAY the core's exact link line, swapping the probe's app objects and
#      output for ours and adding the Swift object, the bridge, and SwiftUI.
#   4. assemble a flat iOS .app, embed the memory entitlements, package iPS3.ipa.
#
# Expected to hit walls on first runs (like Phase 1). Never fatal to the spike:
# the caller runs it best-effort and the log (60-merge-app.log) is the deliverable.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${1:-${ROOT}/.spike}"
BUILD="${WORK}/build-ios"
RECIPE="${ROOT}/core-link.txt"
STUBLIBS="${WORK}/stublibs"
LOG_DIR="${ROOT}/spike-logs"
mkdir -p "${LOG_DIR}"
LOG="${LOG_DIR}/60-merge-app.log"
: > "${LOG}"
exec > >(tee -a "${LOG}") 2>&1

echo "== merge-app 2b: build dir ${BUILD} =="
if [ ! -f "${RECIPE}" ] || [ ! -s "${RECIPE}" ]; then
  echo "::error::core-link.txt missing/empty — core app did not link; cannot build merged app."
  exit 1
fi
if [ ! -f "${BUILD}/rpcs3/Emu/librpcs3_emu.a" ]; then
  echo "::error::librpcs3_emu.a missing in ${BUILD} — core not built."
  exit 1
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SWIFTC="$(xcrun --sdk iphoneos -f swiftc)"
CLANGXX="$(xcrun --sdk iphoneos -f clang++)"
# The SwiftUI frontend uses @Observable (iOS 17+), so the merged app's minimum
# is 17.0 — higher than the core's 16.3. Objects built at 16.3 link fine into a
# 17.0 binary (the reverse would not), so we bump BOTH the Swift compile and the
# replayed link line to 17.0 below.
TARGET="arm64-apple-ios17.0"
OUT="${WORK}/ips3-merge"; rm -rf "${OUT}"; mkdir -p "${OUT}"
echo "sdk=${SDK}"; echo "swiftc=${SWIFTC}"

# --- 1. Compile the SwiftUI frontend + Swift bridge (whole-module) -----------
SWIFT_SRC=$(ls "${ROOT}"/ios/App.swift \
               "${ROOT}"/ios/Systems/*.swift \
               "${ROOT}"/ios/Views/*.swift \
               "${ROOT}"/ios/Core/*.swift 2>/dev/null)
echo "== compiling Swift ($(echo "${SWIFT_SRC}" | wc -w | tr -d ' ') files) =="
"${SWIFTC}" -target "${TARGET}" -sdk "${SDK}" -O -wmo -parse-as-library \
  -module-name iPS3 \
  -D IPS3_WITH_CORE \
  -import-objc-header "${ROOT}/ios/Core/iPS3-Bridging-Header.h" \
  -emit-object -o "${OUT}/ips3_swift.o" \
  ${SWIFT_SRC}
echo "swift compile exit: $?"

# --- 2. Compile the Obj-C++ bridge -------------------------------------------
echo "== compiling bridge (PS3Core.mm) =="
"${CLANGXX}" --target="${TARGET}" -isysroot "${SDK}" -fobjc-arc \
  -fvisibility=hidden -fvisibility-inlines-hidden -O3 -std=gnu++20 \
  -c "${ROOT}/ios/Core/PS3Core.mm" -o "${OUT}/PS3Core.o"
echo "bridge compile exit: $?"

# --- 3. Replay the core link recipe, swapped for our app ---------------------
# Strip ninja's ": && … && :" wrapper, drop the probe's UIKit object and the
# ays3_app output path, keep the shared seam object, and append our objects +
# SwiftUI + the Swift runtime search path.
LINK="$(cat "${RECIPE}")"
LINK="${LINK#*: && }"
LINK="${LINK% && :}"
LINK="${LINK//rpcs3\/CMakeFiles\/ays3_app.dir\/ays3_ramprobe.mm.o/}"
LINK="${LINK//-o bin\/ays3_app.app\/ays3_app/-o ${OUT}/iPS3}"
# Bump the recipe's 16.3 min-version to 17.0 (the merged app's real minimum, set
# by @Observable). Lower-minos core archives still link into the 17.0 binary.
LINK="${LINK//arm64-apple-ios16.3/arm64-apple-ios17.0}"
LINK="${LINK//-miphoneos-version-min=16.3/-miphoneos-version-min=17.0}"
echo "== linking merged app =="
( cd "${BUILD}" && eval "${LINK} \
    ${OUT}/ips3_swift.o ${OUT}/PS3Core.o \
    -framework SwiftUI \
    -L${SDK}/usr/lib/swift -Wl,-rpath,/usr/lib/swift" )
LINK_RC=$?
echo "merged link exit: ${LINK_RC}"
if [ ${LINK_RC} -ne 0 ] || [ ! -f "${OUT}/iPS3" ]; then
  echo "== merged app did NOT link — first unresolved symbols =="
  grep -oE "\"[^\"]+\", referenced from|Undefined symbols|ld: symbol.*not found|Undefined symbol.*" "${LOG}" | sort -u | head -40 || true
  exit 1
fi

# --- 4. Assemble a flat iOS .app + entitlements + package --------------------
IPA_DIR="${WORK}/ips3-ipa"; APP="${IPA_DIR}/Payload/iPS3.app"
rm -rf "${IPA_DIR}"; mkdir -p "${APP}"
cp "${OUT}/iPS3" "${APP}/iPS3"; chmod +x "${APP}/iPS3"
xcrun strip -x "${APP}/iPS3" 2>/dev/null || true
# Bundle the controller art the SwiftUI skin loads by name.
cp "${ROOT}"/ios/Resources/*.png "${APP}/" 2>/dev/null || true
# Info.plist: reuse the probe's (UIFileSharingEnabled + background audio) and
# rename it to iPS3; a SwiftUI @main app needs no scene manifest.
cp "${ROOT}/app/ays3_Info.plist" "${APP}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable iPS3" "${APP}/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleName iPS3"       "${APP}/Info.plist" 2>/dev/null || true
BV="${IPS3_BUILD_NUM:-0}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BV}" "${APP}/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.0.${BV}" "${APP}/Info.plist" 2>/dev/null || true
printf 'APPL????' > "${APP}/PkgInfo"
# Embed the memory entitlements (extended-virtual-addressing + increased-memory-limit).
if [ -f "${ROOT}/app/ays3.entitlements" ]; then
  codesign --force --sign - --timestamp=none \
    --entitlements "${ROOT}/app/ays3.entitlements" "${APP}" 2>&1 | tail -2 || true
fi
( cd "${IPA_DIR}" && zip -qr "${ROOT}/iPS3.ipa" Payload )
echo "== merged app packaged =="
ls -1 "${APP}"
ls -lh "${ROOT}/iPS3.ipa" 2>/dev/null
xcrun vtool -show-build "${APP}/iPS3" 2>/dev/null | grep -iE "platform|minos" || true
echo "IPA: ${ROOT}/iPS3.ipa"
