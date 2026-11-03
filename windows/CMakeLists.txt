# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(video_player_app LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "fluent_player_community")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Suppress deprecated <experimental/coroutine> errors in plugins (permission_handler_windows, etc.)
add_compile_definitions(_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
# JNI is an Android-only transitive dependency in this application. Discovering
# the Android build's JAVA_HOME here would add dartjni.dll linked to jvm.dll,
# although the Windows app neither starts nor distributes a Java VM.
set(CMAKE_DISABLE_FIND_PACKAGE_JNI TRUE)
include(flutter/generated_plugins.cmake)

# CMake may omit files which are already built directly into the installation
# directory from install_manifest.txt. Record the evaluated runtime targets as
# well, including FFI libraries (SQLite, notifications, WebView2 loader, etc.).
file(GENERATE OUTPUT "${CMAKE_BINARY_DIR}/runtime_files_$<CONFIG>.txt"
  CONTENT "$<TARGET_FILE:${BINARY_NAME}>\n$<JOIN:${PLUGIN_BUNDLED_LIBRARIES},\n>\n")


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "Install path" FORCE)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")
install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)
install(FILES
  "${CMAKE_CURRENT_SOURCE_DIR}/../LICENSE"
  "${CMAKE_CURRENT_SOURCE_DIR}/../NOTICE"
  "${CMAKE_CURRENT_SOURCE_DIR}/../THIRD_PARTY_NOTICES.md"
  "${CMAKE_CURRENT_SOURCE_DIR}/../PRIVACY.md"
  DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

# Optional stand-alone media tools, never yt-dlp.
foreach(MEDIA_TOOL ffmpeg.exe ffprobe.exe)
  if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../assets/binaries/windows/${MEDIA_TOOL}")
    install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../assets/binaries/windows/${MEDIA_TOOL}"
      DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
  endif()
endforeach()

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# The upstream Flutter package bundles the CPU-only ONNX Runtime DLL. Replace
# it with Microsoft's ABI-compatible DirectML build so OCR can use any DX12
# GPU on Windows and still fall back to the CPU execution provider.
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/runtime/onnxruntime.dll"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# Keep the separately licensed UnRAR helper out of the player's linked libraries.
install(CODE "file(REMOVE \"${INSTALL_BUNDLE_LIB_DIR}/subtitle_unrar.dll\")" COMPONENT Runtime)
set(SUBTITLE_UNRAR_TOOL "${CMAKE_CURRENT_SOURCE_DIR}/../native/subtitle_archive/prebuilt/windows-x64/subtitle_unrar_tool.exe")
if(EXISTS "${SUBTITLE_UNRAR_TOOL}")
  install(FILES "${SUBTITLE_UNRAR_TOOL}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime
   PATTERN "ggml-vulkan.dll" EXCLUDE
   PATTERN "ggml-cuda.dll" EXCLUDE
   PATTERN "cudart*.dll" EXCLUDE
   PATTERN "cublas*.dll" EXCLUDE)

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

# Removing Vulkan from the hook does not remove a DLL installed by an older
# build. Native runtime discovery can still load that stale module in CPU mode.
install(CODE "
  set(LOCAL_TRANSLATION_RUNTIME_DIR \"${INSTALL_BUNDLE_LIB_DIR}\")
  include(\"${CMAKE_CURRENT_SOURCE_DIR}/cmake/local_translation_cpu_runtime.cmake\")
  " COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
