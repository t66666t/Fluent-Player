# A standalone AOT Dart helper contains no Flutter engine or visible window.
# Build after Flutter's hooks to avoid concurrent native-asset staging writes.
function(add_local_translation_worker)
  include("${FLUTTER_MANAGED_DIR}/ephemeral/generated_config.cmake")
  get_filename_component(_translation_source "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
  set(_translation_output "${CMAKE_BINARY_DIR}/translation_worker")
  string(TOLOWER "${CMAKE_GENERATOR_PLATFORM};${CMAKE_SYSTEM_PROCESSOR}" _translation_platform)
  if(_translation_platform MATCHES "arm64|aarch64")
    set(_translation_arch arm64)
  elseif(_translation_platform MATCHES "x64|x86_64|amd64")
    set(_translation_arch x64)
  else()
    message(STATUS "Translation GPU worker is unavailable on this architecture; CPU fallback remains enabled")
    return()
  endif()
  if(WIN32)
    set(_translation_dart "${FLUTTER_ROOT}/bin/cache/dart-sdk/bin/dart.exe")
    set(_translation_name "translation_worker.exe")
    set(_translation_os windows)
    # Dart can cross-compile Linux targets, but its Windows executable must
    # match the SDK host architecture. Flutter itself can still cross-build
    # the player; that bundle retains CPU translation without a wrong-ABI child.
    execute_process(COMMAND "${_translation_dart}" --version
      OUTPUT_VARIABLE _translation_sdk_out ERROR_VARIABLE _translation_sdk_err
      RESULT_VARIABLE _translation_sdk_result)
    set(_translation_sdk_version "${_translation_sdk_out}${_translation_sdk_err}")
    string(FIND "${_translation_sdk_version}" "on \"windows_${_translation_arch}\"" _translation_native_sdk)
    if(NOT _translation_sdk_result EQUAL 0 OR _translation_native_sdk EQUAL -1)
      message(STATUS "Translation GPU worker needs a native Windows ${_translation_arch} Dart SDK; this cross-build keeps CPU translation")
      install(CODE "file(REMOVE \"${CMAKE_INSTALL_PREFIX}/resources/translation/translation_worker.exe\")" COMPONENT Runtime)
      return()
    endif()
  else()
    set(_translation_dart "${FLUTTER_ROOT}/bin/cache/dart-sdk/bin/dart")
    set(_translation_name "translation_worker")
    set(_translation_os linux)
  endif()
  # Flutter's --obfuscate flag does not cover this independent Dart executable.
  # The hardened release script supplies a private directory outside the bundle.
  set(_translation_hardening_args)
  if(DEFINED ENV{FLUENT_RELEASE_SYMBOL_DIR} AND NOT "$ENV{FLUENT_RELEASE_SYMBOL_DIR}" STREQUAL "")
    file(TO_CMAKE_PATH "$ENV{FLUENT_RELEASE_SYMBOL_DIR}" _translation_private_symbols)
    file(MAKE_DIRECTORY "${_translation_private_symbols}/translation-worker")
    list(APPEND _translation_hardening_args
      "--save-debugging-info=${_translation_private_symbols}/translation-worker/debug-info"
      "--extra-gen-snapshot-options=--obfuscate,--strip,--dwarf-stack-traces,--save-obfuscation-map=${_translation_private_symbols}/translation-worker/obfuscation-map.json")
  endif()
  add_custom_command(
    OUTPUT "${_translation_output}/${_translation_name}"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${_translation_output}"
    COMMAND "${_translation_dart}" compile exe
      --target-os ${_translation_os} --target-arch ${_translation_arch}
      ${_translation_hardening_args}
      "${_translation_source}/tool/translation_worker.dart"
      -o "${_translation_output}/${_translation_name}"
    WORKING_DIRECTORY "${_translation_source}"
    DEPENDS
      "${_translation_source}/tool/translation_worker.dart"
      "${_translation_source}/lib/features/model_center/translation_inference.dart"
      "${_translation_source}/lib/features/model_center/translation_compute_policy.dart"
      "${_translation_source}/lib/features/model_center/inference_resource_governor.dart"
      "${_translation_source}/lib/features/model_center/device_resource_snapshot.dart"
      "${_translation_source}/pubspec.yaml"
      "${_translation_source}/pubspec.lock"
    VERBATIM)
  add_custom_target(local_translation_worker ALL
    DEPENDS "${_translation_output}/${_translation_name}")
  add_dependencies(local_translation_worker flutter_assemble)
  install(PROGRAMS "${_translation_output}/${_translation_name}"
    DESTINATION "${CMAKE_INSTALL_PREFIX}/resources/translation" COMPONENT Runtime)
  # Both the loader and GPU module must come from the same pinned ABI bundle.
  install(DIRECTORY "${NATIVE_ASSETS_DIR}"
    DESTINATION "${CMAKE_INSTALL_PREFIX}/resources/translation" COMPONENT Runtime)
  # Dart versions which emit additional native assets beside the AOT executable.
  install(DIRECTORY "${_translation_output}/lib/"
    DESTINATION "${CMAKE_INSTALL_PREFIX}/resources/translation/lib"
    OPTIONAL COMPONENT Runtime)
endfunction()
