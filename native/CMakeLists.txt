cmake_minimum_required(VERSION 3.30)
project(usd_mojo_bridge VERSION 0.2.0 LANGUAGES CXX)
find_package(pxr CONFIG REQUIRED)
add_library(usd_mojo_bridge SHARED bridge.cpp)
target_compile_features(usd_mojo_bridge PRIVATE cxx_std_17)
# Retain useful relative diagnostic paths without exposing local checkout/SDK prefixes.
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(usd_mojo_bridge PRIVATE
    "-ffile-prefix-map=${CMAKE_CURRENT_SOURCE_DIR}=native"
    "-ffile-prefix-map=${CMAKE_PREFIX_PATH}=openusd-sdk")
  # Imported SDK paths may retain a Pixi symlink instead of its resolved prefix.
  foreach(SDK_INCLUDE_DIR IN LISTS PXR_INCLUDE_DIRS)
    target_compile_options(usd_mojo_bridge PRIVATE
      "-ffile-prefix-map=${SDK_INCLUDE_DIR}=openusd-sdk/include")
  endforeach()
endif()
target_compile_options(usd_mojo_bridge PRIVATE -Wall -Wextra -Werror)
# GCC 12 ignores a scoped -Wcpp pragma for libstdc++'s legacy hash header.
# Keep that SDK preprocessor warning visible; ordinary C++ warnings stay fatal.
if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU" AND CMAKE_CXX_COMPILER_VERSION VERSION_LESS 13)
  target_compile_options(usd_mojo_bridge PRIVATE -Wno-error=cpp)
endif()
target_include_directories(usd_mojo_bridge PRIVATE ${PXR_INCLUDE_DIRS})
target_link_libraries(usd_mojo_bridge PRIVATE usd usdGeom usdPhysics usdShade sdf tf gf vt)
# The Conda SDK is built with Python support. Standalone C++/Mojo hosts must
# provide its CPython symbols even though this bridge never calls the Python API.
if(TARGET Python3::Python)
  target_link_libraries(usd_mojo_bridge PRIVATE Python3::Python)
endif()
set_target_properties(usd_mojo_bridge PROPERTIES
  CXX_VISIBILITY_PRESET default VISIBILITY_INLINES_HIDDEN NO
  BUILD_RPATH "${CMAKE_PREFIX_PATH}/lib")

# USD compares RTTI identity for asset/timecode arrays across shared libraries.
# Their template typeinfo must remain coalescible on macOS libc++.

if(APPLE)
  set_target_properties(usd_mojo_bridge PROPERTIES INSTALL_RPATH "@loader_path")
else()
  # Let the consumer's SDK RPATH reach dependencies of this installed bridge.
  # A bridge DT_RUNPATH would prevent that inherited search on glibc.
  target_link_options(usd_mojo_bridge PRIVATE -Wl,--disable-new-dtags)
  set_target_properties(usd_mojo_bridge PROPERTIES INSTALL_RPATH "$ORIGIN")
endif()
install(TARGETS usd_mojo_bridge LIBRARY DESTINATION lib)

option(USD_MOJO_TESTS "Build native exception-boundary regression" OFF)
if(USD_MOJO_TESTS)
  add_executable(diagnostic_ownership ../tests/diagnostic_ownership.cpp)
  target_compile_features(diagnostic_ownership PRIVATE cxx_std_17)
  target_compile_options(diagnostic_ownership PRIVATE -Wall -Wextra -Werror -UNDEBUG)
  if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU" AND CMAKE_CXX_COMPILER_VERSION VERSION_LESS 13)
    target_compile_options(diagnostic_ownership PRIVATE -Wno-error=cpp)
  endif()
  target_include_directories(diagnostic_ownership PRIVATE ${PXR_INCLUDE_DIRS})
  target_link_libraries(diagnostic_ownership PRIVATE usd usdGeom usdPhysics usdShade sdf tf gf vt)
  if(TARGET Python3::Python)
    target_link_libraries(diagnostic_ownership PRIVATE Python3::Python)
  endif()
  if(NOT APPLE)
    target_link_directories(diagnostic_ownership PRIVATE "${CMAKE_PREFIX_PATH}/lib")
    target_link_options(diagnostic_ownership PRIVATE -Wl,--disable-new-dtags)
  endif()
  set_target_properties(diagnostic_ownership PROPERTIES BUILD_RPATH "${CMAKE_PREFIX_PATH}/lib")
endif()
