cmake_minimum_required(VERSION 3.24)

set(MBGA_MIN_MACOS 15.0)
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_DEPLOYMENT_TARGET ${MBGA_MIN_MACOS})
set(CMAKE_Swift_COMPILER_TARGET arm64-apple-macosx${MBGA_MIN_MACOS})
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

project(mbga LANGUAGES C CXX Swift)

set(MBGA_PRODUCT_NAME "MBGA")
set(MBGA_BUNDLE_ID "dev.mbga.browser")
set(MBGA_VERSION "0.0.10")
option(MBGA_MOCK_KEYCHAIN "Use a mock keychain (avoids prompts on ad-hoc signed builds)" ON)
option(MBGA_UPDATES "Update from MBGA's releases on GitHub" OFF)
set(MBGA_UPDATE_PUBLIC_KEY "HQrQqNM/GyMsslsnQmag+Y9mTGB2YHt1WsyouwlPpjw=")
set(MBGA_SIGN_IDENTITY "-" CACHE STRING "Code signing identity (- signs ad hoc)")
if(MBGA_SIGN_IDENTITY STREQUAL "-")
  set(MBGA_SIGN codesign --force --sign -)
  set(MBGA_SIGN_APP ${MBGA_SIGN})
  set(MBGA_SIGN_HELPER ${MBGA_SIGN})
else()
  set(MBGA_SIGN codesign --force --options runtime --timestamp=none --sign "${MBGA_SIGN_IDENTITY}")
  set(MBGA_SIGN_APP ${MBGA_SIGN} --entitlements "${CMAKE_SOURCE_DIR}/shell/resources/app.entitlements")
  set(MBGA_SIGN_HELPER ${MBGA_SIGN} --entitlements "${CMAKE_SOURCE_DIR}/shell/resources/helper.entitlements")
endif()
if(MBGA_UPDATES)
  set(MBGA_UPDATE_FEED "https://github.com/Ffinnis/make-browsers-great-again/releases/latest/download/update.json")
else()
  set(MBGA_UPDATE_FEED "")
endif()

set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/out")

set(CEF_ROOT "${CMAKE_SOURCE_DIR}/third_party/cef/dist")
if(NOT EXISTS "${CEF_ROOT}/cmake/FindCEF.cmake")
  message(FATAL_ERROR "CEF not found in ${CEF_ROOT}. Run scripts/fetch-cef.sh.")
endif()
list(APPEND CMAKE_MODULE_PATH "${CEF_ROOT}/cmake")
find_package(CEF REQUIRED)
add_subdirectory(${CEF_LIBCEF_DLL_WRAPPER_PATH} libcef_dll_wrapper)
set(CMAKE_OSX_DEPLOYMENT_TARGET ${MBGA_MIN_MACOS})
set(CEF_FRAMEWORK "${CEF_BINARY_DIR_RELEASE}/Chromium Embedded Framework.framework")

find_program(CARGO cargo HINTS "$ENV{HOME}/.cargo/bin" REQUIRED)
find_program(KACHE kache HINTS "$ENV{HOME}/.cargo/bin")
set(CORE_ENV MACOSX_DEPLOYMENT_TARGET=${MBGA_MIN_MACOS})
if(KACHE AND NOT DEFINED ENV{RUSTC_WRAPPER})
  list(APPEND CORE_ENV RUSTC_WRAPPER=${KACHE})
endif()
set(CORE_DIR "${CMAKE_SOURCE_DIR}/core")
set(CORE_TARGET_DIR "${CMAKE_BINARY_DIR}/core-target")
set(CORE_LIB "${CORE_TARGET_DIR}/release/libmbga_core.a")
set(CORE_GEN "${CMAKE_BINARY_DIR}/core-bindings")
set(CORE_SWIFT "${CORE_GEN}/mbga_core.swift")
file(GLOB_RECURSE CORE_SOURCES CONFIGURE_DEPENDS "${CORE_DIR}/src/*.rs")

add_custom_command(
  OUTPUT "${CORE_LIB}" "${CORE_SWIFT}" "${CORE_GEN}/mbga_coreFFI.h"
         "${CORE_GEN}/mbga_coreFFI.modulemap"
  COMMAND ${CMAKE_COMMAND} -E env ${CORE_ENV}
          "${CARGO}" build --release --lib
          --manifest-path "${CORE_DIR}/Cargo.toml"
          --target-dir "${CORE_TARGET_DIR}"
  COMMAND ${CMAKE_COMMAND} -E env ${CORE_ENV}
          "${CARGO}" run --release --quiet --features bindgen
          --bin uniffi-bindgen
          --manifest-path "${CORE_DIR}/Cargo.toml"
          --target-dir "${CORE_TARGET_DIR}/bindgen"
          -- generate --library "${CORE_TARGET_DIR}/release/libmbga_core.dylib"
          --language swift --out-dir "${CORE_GEN}"
  DEPENDS ${CORE_SOURCES} "${CORE_DIR}/Cargo.toml"
  WORKING_DIRECTORY "${CORE_DIR}"
  COMMENT "Building Rust core"
  USES_TERMINAL
  VERBATIM)
add_custom_target(mbga_core DEPENDS "${CORE_LIB}" "${CORE_SWIFT}")

set(MEDIA_DIR "${CMAKE_SOURCE_DIR}/media")
set(MEDIA_TARGET_DIR "${CMAKE_BINARY_DIR}/media-target")
set(MEDIA_WASM "${MEDIA_TARGET_DIR}/wasm32-unknown-unknown/release/mbga_media.wasm")
file(GLOB_RECURSE MEDIA_SOURCES CONFIGURE_DEPENDS "${MEDIA_DIR}/src/*.rs")
add_custom_command(
  OUTPUT "${MEDIA_WASM}"
  COMMAND "${CARGO}" build --release --lib --target wasm32-unknown-unknown
          --manifest-path "${MEDIA_DIR}/Cargo.toml"
          --target-dir "${MEDIA_TARGET_DIR}"
  DEPENDS ${MEDIA_SOURCES} "${MEDIA_DIR}/Cargo.toml" "${MEDIA_DIR}/Cargo.lock"
  WORKING_DIRECTORY "${MEDIA_DIR}"
  COMMENT "Building the video converter"
  USES_TERMINAL
  VERBATIM)
add_custom_target(mbga_media DEPENDS "${MEDIA_WASM}")

add_library(mbga_engine STATIC
  shell/engine/MBEngine.h
  shell/engine/MBEngine.mm)
SET_LIBRARY_TARGET_PROPERTIES(mbga_engine)
target_compile_options(mbga_engine PRIVATE -fobjc-arc)
if(MBGA_MOCK_KEYCHAIN)
  target_compile_definitions(mbga_engine PRIVATE MBGA_MOCK_KEYCHAIN)
endif()
add_dependencies(mbga_engine libcef_dll_wrapper)

set(MBGA_HELPER_TARGETS "")
set(MBGA_HELPER_NAMES "")
foreach(_suffixes ${CEF_HELPER_APP_SUFFIXES})
  string(REPLACE ":" ";" _suffixes "${_suffixes}")
  list(GET _suffixes 0 _name_suffix)
  list(GET _suffixes 1 _target_suffix)
  list(GET _suffixes 2 _plist_suffix)

  set(MBGA_HELPER_NAME "${MBGA_PRODUCT_NAME} Helper${_name_suffix}")
  set(MBGA_HELPER_ID_SUFFIX "${_plist_suffix}")
  set(_target "mbga_helper${_target_suffix}")
  set(_plist "${CMAKE_BINARY_DIR}/helper${_target_suffix}-Info.plist")
  configure_file(shell/resources/helper-Info.plist.in "${_plist}")

  add_executable(${_target} MACOSX_BUNDLE shell/helper/helper_main.mm)
  SET_EXECUTABLE_TARGET_PROPERTIES(${_target})
  add_dependencies(${_target} libcef_dll_wrapper)
  target_link_libraries(${_target} libcef_dll_wrapper ${CEF_STANDARD_LIBS})
  set_target_properties(${_target} PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST "${_plist}"
    OUTPUT_NAME "${MBGA_HELPER_NAME}"
    LINK_DEPENDS "${_plist}")
  add_custom_command(TARGET ${_target} POST_BUILD
    COMMAND ${MBGA_SIGN_HELPER} "$<TARGET_BUNDLE_DIR:${_target}>"
    VERBATIM)

  list(APPEND MBGA_HELPER_TARGETS ${_target})
  list(APPEND MBGA_HELPER_NAMES "${MBGA_HELPER_NAME}")
endforeach()

file(GLOB MBGA_SWIFT_SOURCES CONFIGURE_DEPENDS shell/app/*.swift)
set_source_files_properties("${CORE_SWIFT}" PROPERTIES GENERATED TRUE)
configure_file(shell/resources/Info.plist.in "${CMAKE_BINARY_DIR}/Info.plist")

add_executable(mbga MACOSX_BUNDLE ${MBGA_SWIFT_SOURCES} "${CORE_SWIFT}")
add_dependencies(mbga mbga_core mbga_media ${MBGA_HELPER_TARGETS})
file(GLOB MEDIA_RESOURCES CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/shell/resources/media/*")
set_target_properties(mbga PROPERTIES
  OUTPUT_NAME "${MBGA_PRODUCT_NAME}"
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_BINARY_DIR}/Info.plist"
  LINK_DEPENDS "${MEDIA_WASM};${MEDIA_RESOURCES}")
target_compile_options(mbga PRIVATE
  "SHELL:-import-objc-header ${CMAKE_SOURCE_DIR}/shell/engine/MBEngine.h"
  "SHELL:-Xcc -fmodule-map-file=${CORE_GEN}/mbga_coreFFI.modulemap"
  "SHELL:-I ${CORE_GEN}")
target_link_libraries(mbga PRIVATE
  mbga_engine libcef_dll_wrapper "${CORE_LIB}" ${CEF_STANDARD_LIBS})

add_executable(mbga_cli shell/cli/main.swift)
set_target_properties(mbga_cli PROPERTIES OUTPUT_NAME "mbga-cli")
add_dependencies(mbga mbga_cli)

set(_app "$<TARGET_BUNDLE_DIR:mbga>")
set(_cef "${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/${MBGA_PRODUCT_NAME}.app/Contents/Frameworks/Chromium Embedded Framework.framework")
add_custom_command(
  OUTPUT "${_cef}/Versions/A/Chromium Embedded Framework"
  COMMAND mkdir -p "${_cef}/Versions"
  COMMAND rsync -a --delete "${CEF_FRAMEWORK}/" "${_cef}/Versions/A/"
  COMMAND cd "${_cef}" &&
          ln -sfh A Versions/Current &&
          ln -sfh "Versions/A/Chromium Embedded Framework" "Chromium Embedded Framework" &&
          ln -sfh Versions/A/Libraries Libraries &&
          ln -sfh Versions/A/Resources Resources
  COMMAND find "${_cef}/Versions/A/Libraries" -name "*.dylib" -exec ${MBGA_SIGN} {} +
  COMMAND ${MBGA_SIGN} "${_cef}"
  DEPENDS "${CEF_FRAMEWORK}/Chromium Embedded Framework"
  COMMENT "Copying Chromium Embedded Framework"
  VERBATIM)
add_custom_target(mbga_cef_framework DEPENDS "${_cef}/Versions/A/Chromium Embedded Framework")
add_dependencies(mbga mbga_cef_framework)
foreach(_name ${MBGA_HELPER_NAMES})
  add_custom_command(TARGET mbga POST_BUILD
    COMMAND rsync -a --delete "${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/${_name}.app/"
            "${_app}/Contents/Frameworks/${_name}.app/"
    VERBATIM)
endforeach()
add_custom_command(TARGET mbga POST_BUILD
  COMMAND mkdir -p "${_app}/Contents/Resources/bin"
  COMMAND cp "$<TARGET_FILE:mbga_cli>" "${_app}/Contents/Resources/bin/mbga"
  COMMAND rsync -a --delete "${CMAKE_SOURCE_DIR}/shell/resources/extension/"
          "${_app}/Contents/Resources/extension/"
  COMMAND rsync -a --delete "${CMAKE_SOURCE_DIR}/shell/resources/media/"
          "${_app}/Contents/Resources/media/"
  COMMAND cp "${MEDIA_WASM}" "${_app}/Contents/Resources/media/"
  VERBATIM)
set(_icon "${CMAKE_SOURCE_DIR}/shell/resources/AppIcon.icon")
set(_icon_out "${CMAKE_BINARY_DIR}/icon")
add_custom_command(
  OUTPUT "${_icon_out}/Assets.car" "${_icon_out}/AppIcon.icns"
  COMMAND mkdir -p "${_icon_out}"
  COMMAND xcrun actool "${_icon}" --compile "${_icon_out}" --app-icon AppIcon
          --platform macosx --minimum-deployment-target ${MBGA_MIN_MACOS}
          --output-partial-info-plist "${_icon_out}/partial.plist"
  DEPENDS "${_icon}/icon.json" "${_icon}/Assets/art.png"
  VERBATIM)
add_custom_target(mbga_icon DEPENDS "${_icon_out}/Assets.car")
add_dependencies(mbga mbga_icon)
add_custom_command(TARGET mbga POST_BUILD
  COMMAND cp "${_icon_out}/Assets.car" "${_icon_out}/AppIcon.icns" "${_app}/Contents/Resources/"
  VERBATIM)
add_custom_command(TARGET mbga POST_BUILD
  COMMAND rm -f "$<TARGET_FILE:mbga>.d"
  COMMAND ${MBGA_SIGN} "${_app}/Contents/Resources/bin/mbga"
  COMMAND ${MBGA_SIGN_APP} "${_app}"
  COMMENT "Signing ${MBGA_PRODUCT_NAME}.app"
  VERBATIM)
