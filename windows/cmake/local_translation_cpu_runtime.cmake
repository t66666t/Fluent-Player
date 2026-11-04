# The player ships CPU only; Vulkan lives in resources/translation beside its
# isolated worker. Remove modules left in the player directory by older builds.
if(NOT IS_ABSOLUTE "${LOCAL_TRANSLATION_RUNTIME_DIR}")
  message(FATAL_ERROR "LOCAL_TRANSLATION_RUNTIME_DIR must be an absolute bundle path")
endif()

foreach(_translation_module ggml-vulkan.dll ggml-cuda.dll)
  set(_obsolete_translation_gpu "${LOCAL_TRANSLATION_RUNTIME_DIR}/${_translation_module}")
  if(EXISTS "${_obsolete_translation_gpu}")
    file(REMOVE "${_obsolete_translation_gpu}")
    if(EXISTS "${_obsolete_translation_gpu}")
      message(FATAL_ERROR "Cannot remove obsolete ${_translation_module}; close the running app before updating this bundle")
    endif()
  endif()
endforeach()
