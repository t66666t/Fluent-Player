cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

set(BINARY_NAME "fluent-player")
set(APPLICATION_ID "cn.teezy.fluentplayer.standard")
cmake_policy(SET CMP0063 NEW)
set(CMAKE_INSTALL_RPATH "$ORIGIN;$ORIGIN/lib")
set(CMAKE_BUILD_RPATH_USE_ORIGIN TRUE)
set(CMAKE_INSTALL_RPATH_USE_LINK_PATH FALSE)

if(FLUTTER_TARGET_PLATFORM_SYSROOT)
  set(CMAKE_SYSROOT ${FLUTTER_TARGET_PLATFORM_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
  set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
endif()

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE STRING "Flutter build mode" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS "Debug" "Profile" "Release")
endif()

function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_14)
  target_compile_options(${TARGET} PRIVATE -Wall -Werror)
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
endfunction()

set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)

find_package(Python3 REQUIRED COMPONENTS Interpreter)
set(LINUX_PLUGIN_DIR "${PROJECT_BINARY_DIR}/fluent_plugins")
execute_process(
  COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/../tool/configure_linux_plugins.py"
    --source "${FLUTTER_MANAGED_DIR}" --destination "${LINUX_PLUGIN_DIR}"
  RESULT_VARIABLE PLUGIN_CONFIGURATION_RESULT)
if(NOT PLUGIN_CONFIGURATION_RESULT EQUAL 0)
  message(FATAL_ERROR "Could not configure the Linux CLI media backend")
endif()
set(LINUX_PLUGIN_REGISTRANT "${LINUX_PLUGIN_DIR}/plugin_registrant.cc")
add_subdirectory("runner")
add_dependencies(${BINARY_NAME} flutter_assemble)
set_target_properties(${BINARY_NAME} PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run")

# JNI arrives through Android-only Dart implementations. This Linux app never
# uses it; finding a runner's JDK would otherwise bundle a libdartjni.so tied to
# that build machine's JVM and make desktop installation depend on Java.
set(CMAKE_DISABLE_FIND_PACKAGE_JNI TRUE)
include("${LINUX_PLUGIN_DIR}/plugins.cmake")
include(cmake/onnxruntime_arch.cmake)
configure_local_onnxruntime()

set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()
install(CODE "file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}/\")" COMPONENT Runtime)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}/lib")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)
install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)
install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)

foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  install(FILES "${bundled_library}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
endforeach(bundled_library)

set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/linux/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime PATTERN "*ggml-vulkan*" EXCLUDE
  PATTERN "*ggml-cuda*" EXCLUDE PATTERN "libcudart*" EXCLUDE
  PATTERN "libcublas*" EXCLUDE)
include("${CMAKE_CURRENT_SOURCE_DIR}/../native/translation_worker.cmake")
add_local_translation_worker()
include("${CMAKE_CURRENT_SOURCE_DIR}/../native/asr_worker.cmake")
add_local_asr_worker()
include("${CMAKE_CURRENT_SOURCE_DIR}/../native/qwen_asr_worker.cmake")
add_local_qwen_asr_worker()
include("${CMAKE_CURRENT_SOURCE_DIR}/../native/cohere_asr_worker.cmake")
add_local_cohere_asr_worker()
include("${CMAKE_CURRENT_SOURCE_DIR}/../native/parakeet_ja_worker.cmake")
add_local_parakeet_ja_worker()
include("${CMAKE_CURRENT_SOURCE_DIR}/../native/ocr_worker.cmake")
add_local_ocr_worker()

set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")" COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

if(NOT CMAKE_BUILD_TYPE MATCHES "Debug")
  install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
endif()
