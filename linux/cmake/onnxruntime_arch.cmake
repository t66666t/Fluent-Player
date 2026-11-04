# onnxruntime_v2 1.23.2+2 ships only an x64 Linux binary, although sherpa and
# the application also support aarch64. Select the matching official CPU build.
function(configure_local_onnxruntime)
  string(TOLOWER "${CMAKE_SYSTEM_PROCESSOR}" ort_arch)
  if(NOT ort_arch MATCHES "^(aarch64|arm64)$")
    return()
  endif()

  set(ort_version "1.22.0")
  set(ort_name "onnxruntime-linux-aarch64-${ort_version}")
  set(ort_cache "${CMAKE_BINARY_DIR}/_deps/onnxruntime-arm64")
  set(ort_archive "${ort_cache}/${ort_name}.tgz")
  set(ort_library "${ort_cache}/${ort_name}/lib/libonnxruntime.so.${ort_version}")
  set(ort_sha256 "bb76395092d150b52c7092dc6b8f2fe4d80f0f3bf0416d2f269193e347e24702")
  if(NOT EXISTS "${ort_library}")
    file(MAKE_DIRECTORY "${ort_cache}")
    if(EXISTS "${ort_archive}")
      file(SHA256 "${ort_archive}" actual_sha256)
    endif()
    if(NOT actual_sha256 STREQUAL ort_sha256)
      file(DOWNLOAD
        "https://github.com/microsoft/onnxruntime/releases/download/v${ort_version}/${ort_name}.tgz"
        "${ort_archive}"
        EXPECTED_HASH "SHA256=${ort_sha256}"
        TLS_VERIFY ON
        STATUS download_status)
      list(GET download_status 0 download_code)
      if(NOT download_code EQUAL 0)
        message(FATAL_ERROR "Downloading the ARM64 ONNX Runtime failed: ${download_status}")
      endif()
    endif()
    execute_process(
      COMMAND "${CMAKE_COMMAND}" -E tar xzf "${ort_archive}"
      WORKING_DIRECTORY "${ort_cache}"
      RESULT_VARIABLE extract_code)
    if(NOT extract_code EQUAL 0 OR NOT EXISTS "${ort_library}")
      message(FATAL_ERROR "Extracting the ARM64 ONNX Runtime failed")
    endif()
  endif()

  file(READ "${ort_library}" ort_header LIMIT 20 HEX)
  string(SUBSTRING "${ort_header}" 0 12 ort_ident)
  string(SUBSTRING "${ort_header}" 36 4 ort_machine)
  if(NOT ort_ident STREQUAL "7f454c460201" OR NOT ort_machine STREQUAL "b700")
    message(FATAL_ERROR "The Linux ARM64 ONNX Runtime is not an aarch64 ELF64 library")
  endif()

  # Keep sherpa's libonnxruntime.so (SONAME libonnxruntime.so) alongside the
  # newer direct-FFI runtime (SONAME libonnxruntime.so.1). They are separate ELF
  # dependencies; replacing sherpa's library would recreate the Android error.
  set(libraries)
  set(found_runtime FALSE)
  foreach(library IN LISTS PLUGIN_BUNDLED_LIBRARIES)
    get_filename_component(filename "${library}" NAME)
    if(filename STREQUAL "libonnxruntime.so.${ort_version}")
      list(APPEND libraries "${ort_library}")
      set(found_runtime TRUE)
    else()
      list(APPEND libraries "${library}")
    endif()
  endforeach()
  if(NOT found_runtime)
    message(FATAL_ERROR "onnxruntime_v2's Linux library changed; review the ARM64 runtime selection")
  endif()
  set(PLUGIN_BUNDLED_LIBRARIES "${libraries}" PARENT_SCOPE)
  install(FILES
    "${ort_cache}/${ort_name}/LICENSE"
    "${ort_cache}/${ort_name}/ThirdPartyNotices.txt"
    DESTINATION "share/licenses/onnxruntime" COMPONENT Runtime)
endfunction()
