# SPDX-License-Identifier: GPL-3.0-or-later
#
# AYS3 Phase 0 — minimal iOS app skeleton: SwiftUI shell + the JIT bypass
# probe (JITBypass.cpp). No RPCS3 core yet (that's Plan Phase 1). Structure
# mirrors AYS2/ARMSX2's proven CMake+Xcode-generator pattern on purpose, so
# there's less to relearn when the real core lands.
#
# Configure on macOS with:
#   cmake -B build -G Xcode -DCMAKE_SYSTEM_NAME=iOS \
#       -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
#       -DCMAKE_POLICY_VERSION_MINIMUM=3.5 src/cpp
#   xcodebuild -project build/AYS3iOS.xcodeproj -scheme AYS3iOS \
#       -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO build

cmake_minimum_required(VERSION 3.24)

if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
	message(FATAL_ERROR "AYS3 targets iOS only. Configure with -DCMAKE_SYSTEM_NAME=iOS -G Xcode (see comment above).")
endif()

# CMake's Xcode generator names the .xcodeproj after the PROJECT name, not
# the target name — so this must match the add_executable() target below
# (and what build-ios.yml's xcodebuild -project/-scheme point at).
project(AYS3iOS LANGUAGES C CXX Swift)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(AYS3_BUNDLE_IDENTIFIER "com.st4rwhx.ays3" CACHE STRING "Apple bundle identifier")
set(AYS3_IOS_DEPLOYMENT_TARGET "17.0" CACHE STRING "Minimum iOS deployment target")
set(CMAKE_OSX_DEPLOYMENT_TARGET "${AYS3_IOS_DEPLOYMENT_TARGET}" CACHE STRING "Minimum iOS deployment target" FORCE)

# Phase 0 ships unsigned (sideload via StikDebug/AltStore/Sideloadly), same
# as AYS2. Flip these once the project actually needs a provisioning
# profile (e.g. local Xcode device runs during development).
option(AYS3_CODE_SIGNING_ALLOWED "Allow Xcode to code-sign the build" OFF)

if(AYS3_CODE_SIGNING_ALLOWED)
	set(AYS3_CODE_SIGNING_ALLOWED_STR "YES")
	set(AYS3_CODE_SIGNING_REQUIRED_STR "YES")
	set(AYS3_CODE_SIGN_STYLE_STR "Automatic")
else()
	set(AYS3_CODE_SIGNING_ALLOWED_STR "NO")
	set(AYS3_CODE_SIGNING_REQUIRED_STR "NO")
	set(AYS3_CODE_SIGN_STYLE_STR "Manual")
endif()

add_executable(AYS3iOS MACOSX_BUNDLE
	JITBypass.h
	JITBypass.cpp
	${CMAKE_SOURCE_DIR}/../swift/AYS3App.swift
	${CMAKE_SOURCE_DIR}/../swift/ContentView.swift
)

set_target_properties(AYS3iOS PROPERTIES
	MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/Info.plist.in"
	MACOSX_BUNDLE_GUI_IDENTIFIER "${AYS3_BUNDLE_IDENTIFIER}"
	XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${AYS3_BUNDLE_IDENTIFIER}"
	XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
	XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET "${AYS3_IOS_DEPLOYMENT_TARGET}"
	XCODE_ATTRIBUTE_SDKROOT "iphoneos"
	XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS "iphoneos iphonesimulator"
	XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "${AYS3_CODE_SIGNING_ALLOWED_STR}"
	XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "${AYS3_CODE_SIGNING_REQUIRED_STR}"
	XCODE_ATTRIBUTE_CODE_SIGN_STYLE "${AYS3_CODE_SIGN_STYLE_STR}"
	XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS "${CMAKE_SOURCE_DIR}/Entitlements.plist"
	XCODE_ATTRIBUTE_SWIFT_OBJC_BRIDGING_HEADER "${CMAKE_SOURCE_DIR}/AYS3-Bridging-Header.h"
	XCODE_ATTRIBUTE_SWIFT_VERSION "5.0"
	XCODE_ATTRIBUTE_CLANG_ENABLE_MODULES "YES"
	XCODE_ATTRIBUTE_ENABLE_HARDENED_RUNTIME "NO"
	XCODE_ATTRIBUTE_LD_RUNPATH_SEARCH_PATHS "@executable_path/Frameworks /usr/lib/swift"
)
