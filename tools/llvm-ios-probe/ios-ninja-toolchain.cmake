# SPDX-License-Identifier: GPL-3.0-or-later
#
# Minimal iOS toolchain file for Ninja/Makefiles-generator cross-builds.
#
# Why Ninja and not Xcode here, when Phase 0's actual app (src/cpp/CMakeLists.txt)
# uses -G Xcode: the Xcode generator requires every add_executable() target
# to be treated as an app bundle when CMAKE_SYSTEM_NAME=iOS — fine for our
# real .app product, but it broke LLVM's own build the first time this ran
# (llvm-tblgen is a plain build-time CLI tool, not an app; CMake's
# `install(TARGETS llvm-tblgen ... RUNTIME DESTINATION ...)` errored with
# "given no BUNDLE DESTINATION for MACOSX_BUNDLE executable target" — see
# PLAN.md Phase 1a). Ninja has no such bundle requirement for plain
# executables, which is why cross-compiling LLVM (a library with internal
# CLI build tools) is done this way instead. The actual AYS3 app target
# stays on the Xcode generator; only the LLVM dependency build uses this.
#
# The Xcode generator resolves the SDK/sysroot automatically from
# CMAKE_SYSTEM_NAME=iOS; Ninja/Makefiles generators need it spelled out.

set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "")
set(CMAKE_OSX_DEPLOYMENT_TARGET 17.0 CACHE STRING "")

execute_process(
	COMMAND xcrun --sdk iphoneos --show-sdk-path
	OUTPUT_VARIABLE AYS3_IOS_SYSROOT
	OUTPUT_STRIP_TRAILING_WHITESPACE
)
set(CMAKE_OSX_SYSROOT "${AYS3_IOS_SYSROOT}" CACHE PATH "")

# CMake's compiler-check try_compile() defaults to linking+wanting-to-run a
# full executable, which doesn't make sense for a mobile-target toolchain
# during host-side configure. This is the standard fix used by essentially
# every iOS/Android CMake toolchain file (ios-cmake, the Android NDK's own
# toolchain file, etc.) — not specific to this project.
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

set(CMAKE_C_COMPILER clang)
set(CMAKE_CXX_COMPILER clang++)
set(CMAKE_C_FLAGS_INIT "-arch arm64 -isysroot ${AYS3_IOS_SYSROOT} -mios-version-min=17.0")
set(CMAKE_CXX_FLAGS_INIT "-arch arm64 -isysroot ${AYS3_IOS_SYSROOT} -mios-version-min=17.0")

set(CMAKE_FIND_ROOT_PATH "${AYS3_IOS_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
