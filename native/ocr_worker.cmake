# The OCR helper uses the existing pinned runtime in a private directory. A
# native driver or allocator failure therefore cannot terminate the player.
function(add_local_ocr_worker)
  include("${FLUTTER_MANAGED_DIR}/ephemeral/generated_config.cmake")
  get_filename_component(_ocr_source "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
  set(_ocr_output "${CMAKE_BINARY_DIR}/ocr_worker")
  string(TOLOWER "${CMAKE_GENERATOR_PLATFORM};${CMAKE_SYSTEM_PROCESSOR}" _ocr_platform)
  if(_ocr_platform MATCHES "arm64|aarch64")
    set(_ocr_arch arm64)
  elseif(_ocr_platform MATCHES "x64|x86_64|amd64")
    set(_ocr_arch x64)
  else()
    message(STATUS "OCR helper is unavailable on this architecture; CPU compatibility mode remains enabled")
    return()
  endif()
  if(WIN32)
    set(_ocr_dart "${FLUTTER_ROOT}/bin/cache/dart-sdk/bin/dart.exe")
    set(_ocr_name "ocr_worker.exe")
    set(_ocr_os windows)
    execute_process(COMMAND "${_ocr_dart}" --version
      OUTPUT_VARIABLE _ocr_sdk_out ERROR_VARIABLE _ocr_sdk_err RESULT_VARIABLE _ocr_sdk_result)
    string(FIND "${_ocr_sdk_out}${_ocr_sdk_err}" "on \"windows_${_ocr_arch}\"" _ocr_native_sdk)
    if(NOT _ocr_sdk_result EQUAL 0 OR _ocr_native_sdk EQUAL -1)
      message(STATUS "OCR helper requires a native Windows ${_ocr_arch} Dart SDK; keeping CPU compatibility mode")
      install(CODE "file(REMOVE \"${CMAKE_INSTALL_PREFIX}/resources/ocr/ocr_worker.exe\")" COMPONENT Runtime)
      return()
    endif()
  else()
    set(_ocr_dart "${FLUTTER_ROOT}/bin/cache/dart-sdk/bin/dart")
    set(_ocr_name "ocr_worker")
    set(_ocr_os linux)
  endif()
  set(_ocr_hardening_args)
  if(DEFINED ENV{FLUENT_RELEASE_SYMBOL_DIR} AND NOT "$ENV{FLUENT_RELEASE_SYMBOL_DIR}" STREQUAL "")
    file(TO_CMAKE_PATH "$ENV{FLUENT_RELEASE_SYMBOL_DIR}" _ocr_symbols)
    file(MAKE_DIRECTORY "${_ocr_symbols}/ocr-worker")
    list(APPEND _ocr_hardening_args
      "--save-debugging-info=${_ocr_symbols}/ocr-worker/debug-info"
      "--extra-gen-snapshot-options=--obfuscate,--strip,--dwarf-stack-traces,--save-obfuscation-map=${_ocr_symbols}/ocr-worker/obfuscation-map.json")
  endif()
  file(GLOB _ocr_sources CONFIGURE_DEPENDS "${_ocr_source}/lib/services/ocr_*.dart"
    "${_ocr_source}/lib/models/ocr_*.dart")
  add_custom_command(OUTPUT "${_ocr_output}/${_ocr_name}"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${_ocr_output}"
    COMMAND "${_ocr_dart}" compile exe --target-os ${_ocr_os} --target-arch ${_ocr_arch}
      ${_ocr_hardening_args} "${_ocr_source}/tool/ocr_worker.dart" -o "${_ocr_output}/${_ocr_name}"
    WORKING_DIRECTORY "${_ocr_source}"
    DEPENDS ${_ocr_sources} "${_ocr_source}/tool/ocr_worker.dart"
      "${_ocr_source}/pubspec.yaml" "${_ocr_source}/pubspec.lock"
    VERBATIM)
  add_custom_target(local_ocr_worker ALL DEPENDS "${_ocr_output}/${_ocr_name}")
  add_dependencies(local_ocr_worker flutter_assemble)
  if(TARGET local_asr_worker)
    add_dependencies(local_ocr_worker local_asr_worker)
  endif()
  if(TARGET local_translation_worker)
    add_dependencies(local_ocr_worker local_translation_worker)
  endif()
  install(PROGRAMS "${_ocr_output}/${_ocr_name}"
    DESTINATION "${CMAKE_INSTALL_PREFIX}/resources/ocr" COMPONENT Runtime)
  if(WIN32)
    install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/runtime/onnxruntime.dll"
      DESTINATION "${CMAKE_INSTALL_PREFIX}/resources/ocr" COMPONENT Runtime)
    # Optional provider dependencies, when supplied by the pinned runtime.
    install(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/runtime/"
      DESTINATION "${CMAKE_INSTALL_PREFIX}/resources/ocr" COMPONENT Runtime
      FILES_MATCHING PATTERN "*.dll")
  else()
    foreach(_ocr_lib IN LISTS PLUGIN_BUNDLED_LIBRARIES)
      get_filename_component(_ocr_basename "${_ocr_lib}" NAME)
      if(_ocr_basename MATCHES "^libonnxruntime\\.so\\.[0-9].*|^libonnxruntime_providers.*\\.so$")
        install(FILES "${_ocr_lib}" DESTINATION "${CMAKE_INSTALL_PREFIX}/resources/ocr" COMPONENT Runtime)
      endif()
    endforeach()
  endif()
  install(DIRECTORY "${_ocr_output}/lib/"
    DESTINATION "${CMAKE_INSTALL_PREFIX}/resources/ocr/lib" OPTIONAL COMPONENT Runtime)
  set(_ocr_accel "${_ocr_source}/native/ocr/prebuilt/${_ocr_os}/${_ocr_arch}")
  if(EXISTS "${_ocr_accel}/manifest.json")
    find_package(Python3 COMPONENTS Interpreter REQUIRED)
    execute_process(COMMAND "${Python3_EXECUTABLE}"
      "${_ocr_source}/tool/verify_ocr_artifact.py" "${_ocr_accel}"
      --platform ${_ocr_os} --arch ${_ocr_arch}
      COMMAND_ERROR_IS_FATAL ANY)
    install(DIRECTORY "${_ocr_accel}/"
      DESTINATION "${CMAKE_INSTALL_PREFIX}/resources/ocr" COMPONENT Runtime
      FILES_MATCHING PATTERN "*.dll" PATTERN "*.so" PATTERN "*-LICENSE"
      PATTERN "*Notices.txt")
    install(DIRECTORY "${_ocr_accel}/ThirdPartyLicenses"
      DESTINATION "${CMAKE_INSTALL_PREFIX}/resources/ocr" COMPONENT Runtime)
  endif()
endfunction()
