# iPS3 SwiftUI app — milestone 1 (standalone, no emulator core yet).
#
# Built with the CMake Xcode generator (the only reliable way to compile a
# SwiftUI iOS app), exactly like the reference build proves out. This target is
# pure Swift: it compiles the ported systems + the first screen into a
# sideloadable .app. The RPCS3 core is linked in a later milestone.
#
# Configure:  cmake -B build -G Xcode -DCMAKE_SYSTEM_NAME=iOS \
#               -DCMAKE_OSX_ARCHITECTURES=arm64 ios
# Build:      xcodebuild -project build/iPS3.xcodeproj -scheme iPS3 \
#               -sdk iphoneos -configuration Release CODE_SIGNING_ALLOWED=NO build

cmake_minimum_required(VERSION 3.20)
project(iPS3 LANGUAGES Swift)

# Generate a per-target Xcode scheme so `xcodebuild -scheme iPS3` works
# (required when -derivedDataPath is passed).
set(CMAKE_XCODE_GENERATE_SCHEME ON)

set(IPS3_VERSION "1.0.${IPS3_BUILD_NUM}" CACHE STRING "iPS3 marketing version")
set(IPS3_BUILD "${IPS3_BUILD_NUM}" CACHE STRING "iPS3 build number")
if(NOT IPS3_BUILD_NUM)
	set(IPS3_VERSION "1.0.0")
	set(IPS3_BUILD "1")
endif()

file(GLOB IPS3_SWIFT_SOURCES
	"${CMAKE_CURRENT_SOURCE_DIR}/App.swift"
	"${CMAKE_CURRENT_SOURCE_DIR}/Systems/*.swift"
	"${CMAKE_CURRENT_SOURCE_DIR}/Views/*.swift"
)

configure_file("${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
	"${CMAKE_BINARY_DIR}/Info.plist" @ONLY)

add_executable(iPS3 MACOSX_BUNDLE ${IPS3_SWIFT_SOURCES})

set_target_properties(iPS3 PROPERTIES
	MACOSX_BUNDLE TRUE
	MACOSX_BUNDLE_GUI_IDENTIFIER "com.ips3.app"
	MACOSX_BUNDLE_BUNDLE_NAME "iPS3"
	MACOSX_BUNDLE_INFO_PLIST "${CMAKE_BINARY_DIR}/Info.plist"
	OUTPUT_NAME "iPS3"
	XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "com.ips3.app"
	XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
	XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET "17.0"
	XCODE_ATTRIBUTE_SWIFT_VERSION "5.0"
	XCODE_ATTRIBUTE_CLANG_ENABLE_MODULES "YES"
	XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
	XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "NO"
	XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY ""
	XCODE_ATTRIBUTE_LD_RUNPATH_SEARCH_PATHS "@executable_path/Frameworks /usr/lib/swift"
	XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS "iphoneos iphonesimulator"
	XCODE_ATTRIBUTE_ENABLE_ON_DEMAND_RESOURCES "NO"
)
