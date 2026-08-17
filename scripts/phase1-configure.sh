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
# GitHub intermittently returns HTTP 500 mid-fetch, which used to leave a
# submodule (e.g. 3rdparty/zstd's inner tree, or zlib) half-checked-out and blow
# up configure with "zstd/build/cmake ... not an existing directory". So clone
# the (small, reliable) main repo first, THEN pull submodules in a retry loop,
# and hard-assert the tree is complete. Note: only `set -u` is active (no
# pipefail), so we must check git's own exit status, not a tee pipeline's.
if [ ! -d "${RPCS3_DIR}/.git" ]; then
  echo "== cloning RPCS3 (${RPCS3_REF}) main repo =="
  : > "${LOG_DIR}/00-clone.log"
  for i in 1 2 3 4; do
    rm -rf "${RPCS3_DIR}"
    if git clone --depth 1 --branch "${RPCS3_REF}" \
         https://github.com/RPCS3/rpcs3 "${RPCS3_DIR}" >>"${LOG_DIR}/00-clone.log" 2>&1; then
      break
    fi
    echo "main clone attempt $i failed; retry in $((i*5))s" | tee -a "${LOG_DIR}/00-clone.log"
    sleep $((i*5))
  done
fi

# Fetch submodules with retries — a transient failure on one leaves the tree
# unconfigurable; retrying almost always clears a GitHub 5xx.
if [ -d "${RPCS3_DIR}/.git" ]; then
  echo "== fetching RPCS3 submodules (recursive, retried) =="
  for i in 1 2 3 4 5; do
    if git -C "${RPCS3_DIR}" submodule update --init --recursive \
         --depth 1 --jobs 4 >>"${LOG_DIR}/00-clone.log" 2>&1; then
      echo "submodules OK on attempt $i" | tee -a "${LOG_DIR}/00-clone.log"
      break
    fi
    echo "submodule attempt $i failed (transient GitHub fetch?); retry in $((i*5))s" | tee -a "${LOG_DIR}/00-clone.log"
    sleep $((i*5))
  done
  # Hard-assert the submodule that has bitten us actually materialized, so an
  # infra flake fails LOUD and re-runnable instead of as a cryptic CMake error.
  if [ ! -d "${RPCS3_DIR}/3rdparty/zstd/zstd/build/cmake" ]; then
    echo "::error::RPCS3 submodules still incomplete after retries (zstd/build/cmake missing) — GitHub fetch flake, not a code issue. Re-run this job." | tee -a "${LOG_DIR}/00-clone.log"
    exit 1
  fi
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

  # Wall #16: perf_meter's g_tls_perf_stat is a `static inline thread_local`
  # struct with a NON-trivial ctor/dtor (perf_stat_base::add/remove). That forces
  # a dynamic thread-local INITIALIZATION routine (_ZTH...), which the Xcode-16
  # linker emits per-TU without coalescing, so two TUs sharing the same
  # perf_stat<Name> instantiation collide: "duplicate symbol thread-local
  # initialization routine for perf_stat<...>::g_tls_perf_stat". It fires under
  # normal on-demand linking too (both TUs land in the boot subgraph), so it
  # would break the real app link, not just the probe. Drop the ctor/dtor so the
  # struct is an aggregate → g_tls_perf_stat is CONSTANT-initialized → no dynamic
  # init routine → no duplicate. Only disables perf-stat *registration* (add/
  # remove); m_log still works and a headless core needs no exit-time profiling.
  local pm="${RPCS3_DIR}/rpcs3/Emu/perf_meter.hpp"
  if [ -f "${pm}" ] && grep -q 'perf_stat_local() noexcept' "${pm}"; then
    perl -0pi -e 's/(u64 m_log\[66\]\{\};).*?(\}\s*g_tls_perf_stat;)/$1\n\t$2/s' "${pm}"
    echo "  perf_meter: g_tls_perf_stat made constant-initialized (no TLS init dup)"
  fi

  # Wall #17: RPCS3 reserves EXECUTABLE JIT memory at STATIC INIT. asmjit's
  # get_global_runtime() builds a custom_runtime that reserves+commits 16 MiB of
  # W^X memory, and PPUThread.cpp's global constructors pull it in at load. On
  # iOS, reserving/committing executable (MAP_JIT) memory before any debugger/JIT
  # session exists returns EPERM -> ensure() -> report_fatal_error at load, so
  # the app dies before main() (confirmed on-device: JITASM.cpp:351, errno=1).
  # For the headless RAM probe (which NEVER runs the JIT) degrade executable JIT
  # allocations to plain RW on iOS so the core loads and we can measure memory.
  # Real JIT execution needs the debugger-granted RWX (StikDebug) established
  # after launch — deferred to a JIT-timing phase (AYS2's specialty).
  local ja="${RPCS3_DIR}/Utilities/JITASM.cpp"
  if [ -f "${ja}" ] && ! grep -q 'AYS3_JIT_DEGRADE' "${ja}"; then
    perl -0pi -e 's/utils::memory_reserve\(size, true\)/utils::memory_reserve(size, AYS3_JIT_RESERVE_EXEC)/g' "${ja}"
    perl -pi  -e 's/utils::protection::wx/AYS3_JIT_WX/g' "${ja}"
    perl -0pi -e 's/\A/\/\/ AYS3_JIT_DEGRADE\n#if defined(__APPLE__)\n#include <TargetConditionals.h>\n#endif\n#if defined(__APPLE__) \&\& TARGET_OS_IPHONE\n#define AYS3_JIT_RESERVE_EXEC false\n#define AYS3_JIT_WX utils::protection::rw\n#else\n#define AYS3_JIT_RESERVE_EXEC true\n#define AYS3_JIT_WX utils::protection::wx\n#endif\n/' "${ja}"
    echo "  JITASM: static-init exec JIT reserve degraded to RW on iOS ($(grep -c 'AYS3_JIT_WX' "${ja}") site(s))"
  fi

  # Wall #18: RPCS3's vm reserves ~56 GiB of virtual address at STATIC INIT
  # (g_base_addr 8 GiB @ 0x2'0000'0000, g_exec 12 GiB, g_hook 32 GiB, g_stat
  # 4 GiB) as PROT_READ|PROT_WRITE|MAP_NORESERVE — that succeeds lazily on iOS.
  # But memory_commit()/memory_protect() then do `ensure(::mprotect(...) != -1)`,
  # and on iOS mprotect over that noreserve range returns ENOMEM (errno 12) ->
  # report_fatal_error at load (confirmed on-device: vm_native.cpp:325). Same
  # class as Wall #17: an iOS-incompatible low-level op is fatally asserted.
  # Degrade it: try mprotect; if iOS rejects it, force-map the pages with a
  # MAP_FIXED anonymous mapping (best-effort, non-fatal) so the core finishes
  # static init and we reach the next wall instead of dying before main().
  local vmn="${RPCS3_DIR}/rpcs3/util/vm_native.cpp"
  if [ -f "${vmn}" ] && ! grep -q 'AYS3_MPROTECT_OR_MAP' "${vmn}"; then
    # (#20b) The JIT pool is reserved with can_be_jit=true -> jit_flag=MAP_JIT,
    # and iOS refuses MAP_JIT without the dynamic-codesigning entitlement, so the
    # reserve returns null -> pool base 0 -> SPU-runtime trampoline data lands at
    # raw 0x40000000 and segfaults at load. Route every MAP_JIT through a macro
    # (0 on iOS). Done on the RAW file FIRST so we don't rewrite the #define.
    perl -pi -e 's/\bMAP_JIT\b/AYS3_MAP_JIT/g' "${vmn}"
    cat > "${WORK}/ays3_vm18.h" <<'HDR'
// AYS3 Wall #18/#20: make RPCS3's memory reservation + commit fit iOS limits.
//  (#20) Large PROT_READ|WRITE reservations FAIL on iOS (no extended-VA
//        entitlement) -> memory_reserve returns null -> the JIT pool base is 0,
//        so data allocs land at raw 0x40000000 and the SPU-runtime trampoline
//        writes segfault at load. Fix: reserve NON-JIT regions as PROT_NONE
//        (virtual, always succeeds); on-demand commit backs the sub-ranges.
//  (#18) commit/protect mprotect is non-fatal with a MAP_FIXED fallback, and
//        drops PROT_EXEC (iOS forbids W^X before a debugger JIT session — the
//        trampoline CODE is written now, executed later). madvise is a no-op.
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
#include <sys/mman.h>
#include <cstdlib>
#include <unistd.h>
#if defined(__APPLE__) && TARGET_OS_IPHONE
#define AYS3_MAP_JIT 0
#define AYS3_RESERVE_PROT (jit_flag ? (PROT_READ | PROT_WRITE) : PROT_NONE)
#define AYS3_MPROTECT_OR_MAP(p, s, pr) do { const int _apr = (pr) & ~PROT_EXEC; if (::mprotect((p), (s), _apr) != 0) { (void)::mmap((p), (s), _apr, MAP_FIXED | MAP_ANON | MAP_PRIVATE, -1, 0); } } while (0)
#define AYS3_MADVISE(...) ((void)::madvise(__VA_ARGS__))
#else
#define AYS3_MAP_JIT MAP_JIT
#define AYS3_RESERVE_PROT (PROT_READ | PROT_WRITE)
#define AYS3_MPROTECT_OR_MAP(p, s, pr) ensure(::mprotect((p), (s), (pr)) != -1)
#define AYS3_MADVISE(...) ensure(::madvise(__VA_ARGS__) != -1)
#endif
HDR
    cat "${WORK}/ays3_vm18.h" "${vmn}" > "${vmn}.tmp" && mv "${vmn}.tmp" "${vmn}"
    perl -pi -e 's{ensure\(::mprotect\((.*?), \+prot\) != -1\);}{AYS3_MPROTECT_OR_MAP($1, +prot);}g' "${vmn}"
    perl -pi -e 's{ensure\(::madvise\((.*?)\) != -1\);}{AYS3_MADVISE($1);}g' "${vmn}"
    # Wall #20: reserve non-JIT regions as PROT_NONE on iOS (the Apple ARM64
    # reserve otherwise maps PROT_READ|WRITE, which iOS rejects at these sizes).
    perl -pi -e 's{::mmap\(use_addr, size, PROT_READ \| PROT_WRITE, MAP_ANON \| MAP_PRIVATE \| jit_flag}{::mmap(use_addr, size, AYS3_RESERVE_PROT, MAP_ANON | MAP_PRIVATE | jit_flag}g' "${vmn}"
    # Wall #23: utils::shm backs guest memory with shm_open (named POSIX shared
    # memory). iOS sandboxes shm_open -> EPERM (confirmed: __GLOBAL__sub_I_vm.cpp
    # constructs the 32 GiB hook shm at load and dies). Back it with an unlinked
    # temp file in the app container ($TMPDIR, writable and set before main).
    perl -0pi -e 's{(\t*const std::string name = "/rpcs3-mem2-".*?ensure\(::shm_unlink\(name\.c_str\(\)\) >= 0\);)}{#if defined(__APPLE__) \&\& TARGET_OS_IPHONE\n\t\t\t{ const char* _td = ::getenv("TMPDIR"); std::string _tp = std::string(_td ? _td : "/tmp") + "/rpcs3-mem2-XXXXXX"; m_file = ::mkstemp(\&_tp[0]); ensure(m_file >= 0); ::unlink(_tp.c_str()); } /* AYS3 Wall #23: iOS shm via container temp file (shm_open EPERM) */\n#else\n$1\n#endif}s' "${vmn}"
    echo "  vm_native: iOS no-MAP_JIT ($(grep -c 'AYS3_MAP_JIT' "${vmn}") refs) + reserve->PROT_NONE ($(grep -c 'AYS3_RESERVE_PROT,' "${vmn}") site) + shm->tmpfile ($(grep -c 'AYS3 Wall #23' "${vmn}")) + mprotect/madvise non-fatal/no-EXEC"
  fi

  # Wall #21+#22: memory_reserve_4GiB places the vm base by scanning FIXED
  # addresses (mmap uses use_addr only as a HINT). iOS ignores the hint (ASLR),
  # AND without the extended-virtual-addressing entitlement it caps the address
  # space (~4 GiB max reservation on this hardware), so the full 8/12/32 GiB
  # reserves fail and the loop throws "Failed to reserve vm memory". Confirmed by
  # the competitor's own diary: it FALLS BACK to a smaller reservation "so the
  # app opens" (emulation won't work without the entitlement, but Init runs).
  # Mirror that: reserve at a kernel-chosen address, halving the size on failure
  # down to 64 MiB, so the app opens instead of crashing at load.
  local vmc="${RPCS3_DIR}/rpcs3/Emu/Memory/vm.cpp"
  if [ -f "${vmc}" ] && ! grep -q 'AYS3 Wall #21' "${vmc}"; then
    perl -pi -e 's{(^\t*for \(u64 addr = reinterpret_cast<u64>\(_addr\))}{\t\tfor (u64 _sz = size; _sz >= 0x4000000; _sz /= 2) { if (auto _ap = utils::memory_reserve(_sz, nullptr, is_memory_mapping, false)) return static_cast<u8*>(_ap); } /* AYS3 Wall #21+#22: iOS VA fallback to a smaller kernel-chosen size so the app opens */\n$1}' "${vmc}"
    echo "  vm: memory_reserve_4GiB kernel-chosen + size-halving fallback on iOS ($(grep -c 'AYS3 Wall #21' "${vmc}") site)"
  fi

  # Phase 2: a link probe that references the core `Emu` global (pulls the real
  # boot subgraph on demand) AND provides the Emu<->app seam via ays3_seam.cpp,
  # so it links WITHOUT dynamic_lookup — a strict test that the seam is complete.
  local rc2="${RPCS3_DIR}/rpcs3/CMakeLists.txt"
  if [ -f "${rc2}" ] && ! grep -q 'ays3_probe' "${rc2}"; then
    cat > "${RPCS3_DIR}/rpcs3/ays3_probe.cpp" <<'PROBE'
#include <cstdio>
// Reference RPCS3's real core global `Emulator Emu;` (Emu/System.cpp). Taking
// its address forces the linker to pull the ACTUAL boot dependency graph from
// librpcs3_emu.a on demand — a genuine "does the headless-boot path link for
// arm64-iOS?" test — instead of -force_load pulling every object (which
// duplicated a weak thread-local perf_stat init routine). The forward
// declaration matches RPCS3's definition, so this emits the same reference the
// core's own TUs use; the archive resolves it.
class Emulator;
extern Emulator Emu;
int main() { std::printf("AYS3 probe: boot path linked for iOS (&Emu=%p)\n", (const void*)&Emu); return 0; }
PROBE
    # App seam glue + RAM-probe app sources (versioned in the AYS3 repo under app/).
    cp "${ROOT}/app/ays3_seam.cpp"     "${RPCS3_DIR}/rpcs3/ays3_seam.cpp"
    cp "${ROOT}/app/ays3_ramprobe.mm"  "${RPCS3_DIR}/rpcs3/ays3_ramprobe.mm"
    cp "${ROOT}/app/ays3_Info.plist"   "${RPCS3_DIR}/rpcs3/ays3_Info.plist"
    cat >> "${rc2}" <<'CM'

# AYS3 Phase 2 link probe + app seam (added by scripts/phase1-configure.sh)
if(AYS3_PROBE)
    add_executable(ays3_probe
        ${CMAKE_CURRENT_SOURCE_DIR}/ays3_probe.cpp
        ${CMAKE_CURRENT_SOURCE_DIR}/ays3_seam.cpp)
    target_link_libraries(ays3_probe PRIVATE rpcs3_emu)
    # No -undefined dynamic_lookup: the Emu<->app seam is now PROVIDED by
    # ays3_seam.cpp, so this is a STRICT link. Success => the seam set is
    # complete and the core + real 3rdparty link into a runnable arm64-iOS binary
    # (std:: from libc++, iconv from the SDK). This is exactly the link the real
    # AYS3 app performs; any remaining undefined symbol is a genuine seam gap.
    target_link_options(ays3_probe PRIVATE "SHELL:-liconv")
endif()

# AYS3 Phase 2 RAM-probe iOS app: a real .app bundle (UIKit) that links the core
# and shows resident memory on-device. Same strict link as ays3_probe; the .mm
# builds with ARC. Packaged into an unsigned .ipa; the sideloader re-signs.
if(AYS3_APP)
    add_executable(ays3_app MACOSX_BUNDLE
        ${CMAKE_CURRENT_SOURCE_DIR}/ays3_ramprobe.mm
        ${CMAKE_CURRENT_SOURCE_DIR}/ays3_seam.cpp)
    set_source_files_properties(${CMAKE_CURRENT_SOURCE_DIR}/ays3_ramprobe.mm
        PROPERTIES COMPILE_FLAGS "-fobjc-arc")
    target_link_libraries(ays3_app PRIVATE rpcs3_emu "-framework AVFoundation")
    target_link_options(ays3_app PRIVATE "SHELL:-liconv")
    set_target_properties(ays3_app PROPERTIES
        MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/ays3_Info.plist
        MACOSX_BUNDLE_GUI_IDENTIFIER com.ays3.ramprobe
        MACOSX_BUNDLE_BUNDLE_NAME AYS3
        XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO)
endif()
CM
    echo "  Phase 2: added ays3_probe + ays3_app (strict link, no dynamic_lookup)"
  fi
}
patch_rpcs3 2>&1 | tee "${LOG_DIR}/03-patches.log"

# --- 2. iOS CMake toolchain (leetal/ios-cmake) --------------------------------
mkdir -p "$(dirname "${TOOLCHAIN}")"
if [ ! -f "${TOOLCHAIN}" ]; then
  echo "== fetching ios-cmake ${IOS_CMAKE_REF} =="
  : > "${LOG_DIR}/02-toolchain-fetch.log"
  # raw.githubusercontent.com occasionally 429s (rate limit); the old single-shot
  # curl -f then left NO file and configure died with "Could not find toolchain
  # file". Try the raw host with retries, then fall back to the jsdelivr CDN
  # mirror (different infra, rarely throttled). A file <50 lines is a truncated/
  # error body, not the real toolchain — treat it as a miss.
  for url in \
    "https://raw.githubusercontent.com/leetal/ios-cmake/${IOS_CMAKE_REF}/ios.toolchain.cmake" \
    "https://raw.githubusercontent.com/leetal/ios-cmake/${IOS_CMAKE_REF}/ios.toolchain.cmake" \
    "https://cdn.jsdelivr.net/gh/leetal/ios-cmake@${IOS_CMAKE_REF}/ios.toolchain.cmake" \
    "https://cdn.jsdelivr.net/gh/leetal/ios-cmake@${IOS_CMAKE_REF}/ios.toolchain.cmake"; do
    for i in 1 2 3; do
      echo "try: ${url} (attempt ${i})" >> "${LOG_DIR}/02-toolchain-fetch.log"
      if curl -fsSL --max-time 60 -o "${TOOLCHAIN}" "${url}" 2>>"${LOG_DIR}/02-toolchain-fetch.log" \
         && [ "$(wc -l < "${TOOLCHAIN}")" -gt 50 ]; then
        echo "toolchain OK from ${url}" >> "${LOG_DIR}/02-toolchain-fetch.log"
        break 2
      fi
      rm -f "${TOOLCHAIN}"
      sleep $((i*4))
    done
  done
fi
if [ -f "${TOOLCHAIN}" ] && [ "$(wc -l < "${TOOLCHAIN}")" -gt 50 ]; then
  echo "toolchain: ${TOOLCHAIN} ($(wc -l < "${TOOLCHAIN}") lines)"
else
  echo "::error::iOS toolchain download failed (raw.githubusercontent + jsdelivr all unavailable — infra flake, not a code issue). Re-run this job." \
    | tee -a "${LOG_DIR}/02-toolchain-fetch.log"
  exit 1
fi

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
  -DAYS3_APP=ON \
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

    echo "== linking ays3_probe (on-demand rpcs3_emu via &Emu, seam deferred) =="
    ninja -C "${WORK}/build-ios" -k 0 -j3 ays3_probe \
      2>&1 | tee "${LOG_DIR}/40-link-probe.log"
    PROBE_EXIT=${PIPESTATUS[0]}
    echo "probe link exit: ${PROBE_EXIT}" | tee -a "${LOG_DIR}/40-link-probe.log"

    PROBE_BIN="${WORK}/build-ios/bin/ays3_probe"
    [ -f "${PROBE_BIN}" ] || PROBE_BIN="$(find "${WORK}/build-ios" -name ays3_probe -type f 2>/dev/null | head -1)"
    if [ -n "${PROBE_BIN}" ] && [ -f "${PROBE_BIN}" ]; then
      # MILESTONE: the core + its real 3rdparty LINKED for arm64-iOS. Confirm the
      # binary's platform, then enumerate the Emu<->app seam (the symbols left for
      # the AYS3 app layer to implement) — the concrete deliverable of Phase 2.
      echo "== ays3_probe LINKED for iOS =="
      xcrun vtool -show-build "${PROBE_BIN}" 2>/dev/null | grep -iE "platform|minos" || \
        xcrun otool -l "${PROBE_BIN}" 2>/dev/null | grep -A3 LC_BUILD_VERSION | head -6 || true
      # All undefined symbols (raw): includes iOS-provided libSystem/libc++/objc
      # runtime symbols (memcpy, __cxa_throw, __tlv_bootstrap...) that resolve at
      # load time — NOT things the app must implement.
      xcrun nm -u "${PROBE_BIN}" 2>/dev/null | sed 's/^ *//' | sort -u \
        > "${LOG_DIR}/41-app-seam-raw.txt"
      # The real Emu<->app SEAM: demangle, then drop every symbol still starting
      # with '_' — those are the C/runtime symbols iOS provides (their demangled
      # form keeps the leading underscores). What remains are the RPCS3 C++
      # frontend symbols the AYS3 app must implement (pad_thread::*, sdl_instance::*,
      # rpcs3::get_verbose_version, report_fatal_error, qt_events_aware_op, ...).
      c++filt < "${LOG_DIR}/41-app-seam-raw.txt" 2>/dev/null \
        | grep -v '^_' | sort -u > "${LOG_DIR}/41-app-seam.txt" || true
      echo "== Emu<->app seam: RPCS3 C++ symbols the AYS3 app must provide =="
      cat "${LOG_DIR}/41-app-seam.txt" || true
      echo "raw undefined: $(wc -l < "${LOG_DIR}/41-app-seam-raw.txt" | tr -d ' '), app-seam (RPCS3 C++): $(wc -l < "${LOG_DIR}/41-app-seam.txt" | tr -d ' ')"
    else
      echo "== probe did NOT link — remaining hard errors =="
      grep -oE "\"[^\"]+\", referenced from|Undefined symbols|ld: symbol.*not found|undefined symbol: .*|built for '[^']*'" "${LOG_DIR}/40-link-probe.log" | sort -u | head -60 || true
    fi

    # --- 6. Build the RAM-probe .app and package an unsigned .ipa -------------
    # Real UIKit app bundle that links the core; the user sideloads the .ipa
    # (their tool re-signs) to see resident memory on-device.
    echo "== building ays3_app (.app bundle) =="
    ninja -C "${WORK}/build-ios" -k 0 -j3 ays3_app \
      2>&1 | tee "${LOG_DIR}/50-app-build.log"
    echo "app build exit: ${PIPESTATUS[0]}" | tee -a "${LOG_DIR}/50-app-build.log"
    # CMake's MACOSX_BUNDLE under the *Ninja* generator emits a macOS-style
    # bundle: ays3_app.app/Contents/MacOS/ays3_app + Contents/Info.plist. iOS —
    # and ldid, the signer SideStore/AltStore run at install — require a FLAT
    # bundle: App.app/ays3_app + App.app/Info.plist. Given the macOS layout, ldid
    # reads CFBundleExecutable=ays3_app, looks for it at the bundle ROOT, doesn't
    # find it (it's under Contents/MacOS/), and aborts:
    #   ldid.cpp: _assert(): DiskFolder::Open(.../App.app/ays3_app)
    # Only the Xcode generator produces the flat iOS layout automatically; with
    # Ninja we must assemble it ourselves. So: find the built Mach-O and build a
    # guaranteed-flat .app by hand (binary + our Info.plist at the app root).
    APP_BIN="$(find "${WORK}/build-ios" -type f -name 'ays3_app' 2>/dev/null | head -1)"
    if [ -n "${APP_BIN}" ] && [ -f "${APP_BIN}" ]; then
      echo "== assembling FLAT iOS .app from ${APP_BIN} =="
      IPA_DIR="${WORK}/ipa"
      APP="${IPA_DIR}/Payload/ays3_app.app"
      rm -rf "${IPA_DIR}" && mkdir -p "${APP}"
      cp "${APP_BIN}" "${APP}/ays3_app"
      chmod +x "${APP}/ays3_app"
      # The core links UNSTRIPPED (~48 MB, huge symbol table). On-device signers
      # (SideStore/AltStore ldid) frequently choke on binaries that large — ldid
      # asserts opening the main executable — and every mobile emu port (incl.
      # ARMSX3) strips before packaging. Standard, and shrinks it a lot.
      echo "  binary before strip: $(du -h "${APP}/ays3_app" 2>/dev/null | cut -f1)"
      # Dump the symbol table (address-sorted) BEFORE stripping, so a stripped
      # (installable) IPA still ships with a companion map to symbolicate crash
      # backtraces (the crash reporter otherwise shows "curl_url_set + N" for
      # every RPCS3 frame). Published next to the IPA on the GitHub Release.
      nm -n "${APP}/ays3_app" 2>/dev/null | gzip -9 > "${ROOT}/ays3-symbols.txt.gz" || true
      echo "  symbol map: $(du -h "${ROOT}/ays3-symbols.txt.gz" 2>/dev/null | cut -f1) (nm, for crash symbolication)"
      xcrun strip -x "${APP}/ays3_app" 2>/dev/null || strip -x "${APP}/ays3_app" 2>/dev/null || true
      echo "  binary after  strip: $(du -h "${APP}/ays3_app" 2>/dev/null | cut -f1)"
      cp "${ROOT}/app/ays3_Info.plist" "${APP}/Info.plist"
      printf 'APPL????' > "${APP}/PkgInfo"
      # Stamp the CI build number into the bundle version so the on-device app
      # displays the exact version that matches its GitHub release (v1.0.<run>).
      # No more "which IPA is this?" — the screen and the release tag agree.
      BV="${IPS3_BUILD_NUM:-0}"
      /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BV}" "${APP}/Info.plist" 2>/dev/null || true
      /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.0.${BV}" "${APP}/Info.plist" 2>/dev/null || true
      echo "  stamped bundle version: 1.0.${BV} (build ${BV})"
      # Fold in any compiled resources CMake produced (none expected here).
      SRC_BUNDLE="$(find "${WORK}/build-ios" -type d -name 'ays3_app.app' 2>/dev/null | head -1)"
      if [ -n "${SRC_BUNDLE}" ] && [ -d "${SRC_BUNDLE}/Contents/Resources" ]; then
        cp -R "${SRC_BUNDLE}/Contents/Resources/." "${APP}/" 2>/dev/null || true
      fi
      # Embed the memory entitlements RPCS3 needs on iOS (ad-hoc signed, done
      # LAST so it seals the final binary + Info.plist):
      #   extended-virtual-addressing → the ~56 GiB virtual reservation
      #   increased-memory-limit      → the jetsam/physical memory ledger
      # Both are grantable to free-signed sideloaded apps (what GetMoreRam
      # applies). SideStore/AltStore/TrollStore re-sign but can carry these.
      if [ -f "${ROOT}/app/ays3.entitlements" ]; then
        codesign --force --sign - --timestamp=none \
          --entitlements "${ROOT}/app/ays3.entitlements" "${APP}" 2>&1 | tail -2 \
          && echo "  entitlements embedded: extended-virtual-addressing + increased-memory-limit" \
          || echo "  (ad-hoc entitlement signing failed — continuing unsigned)"
      fi

      # No -y: never store symlinks as links (a stored symlink extracts to a
      # broken link on-device → ldid can't open it). Follow/flatten everything.
      ( cd "${IPA_DIR}" && zip -qr "${ROOT}/AYS3.ipa" Payload )
      echo "== flat bundle contents (must show ays3_app + Info.plist at root) =="
      ls -1 "${APP}"
      ls -lh "${ROOT}/AYS3.ipa" 2>/dev/null | tee -a "${LOG_DIR}/50-app-build.log"
      echo "IPA: ${ROOT}/AYS3.ipa"
      xcrun vtool -show-build "${APP}/ays3_app" 2>/dev/null | grep -iE "platform|minos" || true
      echo "app binary size: $(du -h "${APP}/ays3_app" 2>/dev/null | cut -f1)"
    else
      echo "== ays3_app binary NOT produced — link/build errors =="
      grep -iE "error:|undefined|ld: |duplicate symbol|ninja: build stopped" "${LOG_DIR}/50-app-build.log" | head -40 || true
    fi
  fi
else
  echo "iOS configure did not succeed (exit ${IOS_CFG_EXIT}); skipping build."
fi

echo "== Phase 1 spike done. Logs in ${LOG_DIR}. =="
echo "First iOS-configure error lines:"
grep -iE "error|fatal|not found|required|CMake Error" "${LOG_DIR}/20-configure-ios.log" | head -40 || true
