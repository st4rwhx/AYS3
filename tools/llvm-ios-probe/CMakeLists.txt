# SPDX-License-Identifier: GPL-3.0-or-later
#
# AYS3 Phase 1a — cross-compile LLVM (Core + AArch64 target + ORC JIT) from
# the vendored RPCS3 submodule for arm64-apple-ios, and link a trivial LLJIT
# probe against it. See probe.cpp for what this does and doesn't prove, and
# PLAN.md Phase 1a for why this needs two builds (see LLVM_NATIVE_TOOL_DIR
# below) and Ninja instead of Xcode (see ios-ninja-toolchain.cmake).
#
# Two-stage build, both required:
#   1. A NATIVE (macOS host) build of just llvm-tblgen/llvm-min-tblgen —
#      TableGen must run ON THE BUILD MACHINE to generate .inc files even
#      though the resulting libraries target iOS; an iOS-arch llvm-tblgen
#      can't execute on the macOS host that's building it.
#   2. This iOS cross-build, pointed at stage 1's binaries via
#      LLVM_NATIVE_TOOL_DIR so it never tries to build/run its own copy.
#
# Configure on macOS (after stage 1 — see .github/workflows/llvm-ios-probe.yml):
#   cmake -B build -G Ninja \
#       -DCMAKE_TOOLCHAIN_FILE=ios-ninja-toolchain.cmake \
#       -DLLVM_NATIVE_TOOL_DIR=/path/to/stage1/bin \
#       tools/llvm-ios-probe
#   cmake --build build

cmake_minimum_required(VERSION 3.24)

# CMAKE_TOOLCHAIN_FILE (and the CMAKE_SYSTEM_NAME it sets) is only actually
# processed by CMake during the first project()/enable_language() call — a
# check before that point always sees the un-cross-compiled host value
# ("Darwin" on the macOS runner, never "iOS"), regardless of what toolchain
# file was passed on the command line. This bit run #2 of the Phase 1a CI
# (see PLAN.md): the guard below used to sit before project() and fired
# unconditionally. project() must come first.
project(AYS3LLVMiOSProbe LANGUAGES C CXX)

if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
	message(FATAL_ERROR "This probe targets iOS only (that's the whole point). Configure with -DCMAKE_TOOLCHAIN_FILE=ios-ninja-toolchain.cmake.")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(LLVM_ROOT "${CMAKE_SOURCE_DIR}/../../external/rpcs3/3rdparty/llvm/llvm")
if(NOT EXISTS "${LLVM_ROOT}/llvm/CMakeLists.txt")
	message(FATAL_ERROR "LLVM submodule not checked out at ${LLVM_ROOT}. Run: git submodule update --init --depth 1 -- external/rpcs3/3rdparty/llvm/llvm (from the AYS3 repo root, after external/rpcs3 itself is initialized).")
endif()

if(NOT LLVM_NATIVE_TOOL_DIR)
	message(FATAL_ERROR "LLVM_NATIVE_TOOL_DIR not set — pass -DLLVM_NATIVE_TOOL_DIR=<path to a native build's bin/ containing llvm-tblgen and llvm-min-tblgen>. See the comment block above.")
endif()

# Mirrors external/rpcs3/3rdparty/llvm/CMakeLists.txt's BUILD_LLVM branch,
# scoped to what a JIT actually needs — no tools/tests/docs/examples/utils,
# same as RPCS3 builds it. AArch64 only: that's both our host and our only
# JIT target on iOS (no need for RPCS3's desktop dual AArch64+X86 build).
set(LLVM_TARGETS_TO_BUILD "AArch64" CACHE STRING "" FORCE)
set(LLVM_BUILD_RUNTIME OFF CACHE BOOL "")
set(LLVM_BUILD_TOOLS OFF CACHE BOOL "")
set(LLVM_BUILD_UTILS OFF CACHE BOOL "") # also skips the tblgen install() rule that broke under -G Xcode
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

add_subdirectory("${LLVM_ROOT}/llvm" "${CMAKE_BINARY_DIR}/llvm_build" EXCLUDE_FROM_ALL)

add_executable(ays3_llvm_probe probe.cpp)
target_include_directories(ays3_llvm_probe PRIVATE
	"${LLVM_ROOT}/llvm/include"
	"${CMAKE_BINARY_DIR}/llvm_build/include"
)
llvm_map_components_to_libnames(AYS3_LLVM_LIBS AArch64 Core OrcJIT native)
# Run #3 (see PLAN.md): the resolved component list carries a plain "rt"
# system library (Linux's librt, for POSIX realtime symbols like
# clock_gettime that live in libSystem on Apple platforms instead) that
# doesn't exist for any Darwin target, iOS included, and fails the final
# link with "library 'rt' not found". Everything else in the 1630-step
# build succeeded — this was the only broken piece.
list(REMOVE_ITEM AYS3_LLVM_LIBS rt)
target_link_libraries(ays3_llvm_probe PRIVATE ${AYS3_LLVM_LIBS})
