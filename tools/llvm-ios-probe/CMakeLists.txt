# SPDX-License-Identifier: GPL-3.0-or-later
#
# AYS3 Phase 1a — cross-compile LLVM (Core + AArch64 target + ORC JIT) from
# the vendored RPCS3 submodule for arm64-apple-ios, and link a trivial LLJIT
# probe against it. See probe.cpp for what this does and doesn't prove.
#
# This is intentionally decoupled from RPCS3's own top-level CMakeLists.txt
# (which pulls in Qt, Vulkan, and everything else RPCS3 needs) — we only
# want its 3rdparty/llvm submodule, built the way RPCS3 builds it
# (external/rpcs3/3rdparty/llvm/CMakeLists.txt), minus the parts of that
# wrapper that are Android/Windows/Linux-specific.
#
# Configure on macOS with:
#   cmake -B build -G Xcode -DCMAKE_SYSTEM_NAME=iOS \
#       -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
#       -DCMAKE_POLICY_VERSION_MINIMUM=3.5 tools/llvm-ios-probe
#   xcodebuild -project build/AYS3LLVMiOSProbe.xcodeproj -scheme ays3_llvm_probe \
#       -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
#
# Expect this to be slow (LLVM, even scoped to one target backend, is a lot
# of C++) and to need iteration — this is genuinely novel cross-compilation
# territory, not a known-good recipe copied from somewhere. See
# RESEARCH.md/PLAN.md for why.

cmake_minimum_required(VERSION 3.24)

if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
	message(FATAL_ERROR "This probe targets iOS only (that's the whole point). Configure with -DCMAKE_SYSTEM_NAME=iOS -G Xcode.")
endif()

project(AYS3LLVMiOSProbe LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OSX_DEPLOYMENT_TARGET "17.0" CACHE STRING "Minimum iOS deployment target" FORCE)

set(LLVM_ROOT "${CMAKE_SOURCE_DIR}/../../external/rpcs3/3rdparty/llvm/llvm")
if(NOT EXISTS "${LLVM_ROOT}/llvm/CMakeLists.txt")
	message(FATAL_ERROR "LLVM submodule not checked out at ${LLVM_ROOT}. Run: git submodule update --init --depth 1 -- external/rpcs3/3rdparty/llvm/llvm (from the AYS3 repo root, after external/rpcs3 itself is initialized).")
endif()

# Mirrors external/rpcs3/3rdparty/llvm/CMakeLists.txt's BUILD_LLVM branch,
# scoped to what a JIT actually needs — no tools/tests/docs/examples/utils,
# same as RPCS3 builds it. AArch64 only: that's both our host and our only
# JIT target on iOS (no need for RPCS3's desktop dual AArch64+X86 build).
set(LLVM_TARGETS_TO_BUILD "AArch64" CACHE STRING "" FORCE)
set(LLVM_BUILD_RUNTIME OFF CACHE BOOL "")
set(LLVM_BUILD_TOOLS OFF CACHE BOOL "")
set(LLVM_INCLUDE_BENCHMARKS OFF CACHE BOOL "")
set(LLVM_INCLUDE_DOCS OFF CACHE BOOL "")
set(LLVM_INCLUDE_EXAMPLES OFF CACHE BOOL "")
set(LLVM_INCLUDE_TESTS OFF CACHE BOOL "")
set(LLVM_INCLUDE_TOOLS OFF CACHE BOOL "")
set(LLVM_INCLUDE_UTILS OFF CACHE BOOL "")
set(LLVM_ENABLE_WARNINGS OFF CACHE BOOL "")
set(LLVM_ENABLE_THREADS ON CACHE BOOL "")
set(LLVM_ENABLE_TERMINFO OFF CACHE BOOL "")
set(LLVM_ENABLE_LIBXML2 OFF CACHE BOOL "")
set(LLVM_ENABLE_ZLIB OFF CACHE BOOL "")
# LLVM's own CMake needs to run its TableGen-based codegen during the build;
# TableGen (llvm-tblgen) is a build-time tool that must run on the build
# HOST (the Mac), not on iOS, even though the resulting libraries are for
# iOS. Cross-compiling LLVM normally means pointing LLVM_TABLEGEN at a
# native (macOS-arm64) llvm-tblgen built separately — CMake/Xcode-generator
# cross-builds do NOT do this automatically. Left unset for the first probe
# run on purpose: if this is the failure, the CI log will say so explicitly
# ("cannot execute ... llvm-tblgen ... incompatible architecture" or
# similar), which tells us exactly what to build next (a native tblgen) —
# guessing the fix blind wastes more CI time than reading one real error.
add_subdirectory("${LLVM_ROOT}/llvm" "${CMAKE_BINARY_DIR}/llvm_build" EXCLUDE_FROM_ALL)

add_executable(ays3_llvm_probe probe.cpp)
target_include_directories(ays3_llvm_probe PRIVATE
	"${LLVM_ROOT}/llvm/include"
	"${CMAKE_BINARY_DIR}/llvm_build/include"
)
llvm_map_components_to_libnames(AYS3_LLVM_LIBS AArch64 Core OrcJIT native)
target_link_libraries(ays3_llvm_probe PRIVATE ${AYS3_LLVM_LIBS})

set_target_properties(ays3_llvm_probe PROPERTIES
	XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
	XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "NO"
)
