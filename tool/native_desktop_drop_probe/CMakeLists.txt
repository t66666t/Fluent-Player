cmake_minimum_required(VERSION 3.15)
project(desktop_drop_probe LANGUAGES CXX)
get_filename_component(APP_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
set(FLUTTER_ROOT "${APP_ROOT}/windows/flutter/ephemeral")
add_executable(desktop_drop_probe main.cpp)
target_compile_features(desktop_drop_probe PRIVATE cxx_std_17)
target_compile_definitions(desktop_drop_probe PRIVATE FLUTTER_PLUGIN_IMPL UNICODE _UNICODE)
target_compile_options(desktop_drop_probe PRIVATE /utf-8 /W4 /wd4100)
target_include_directories(desktop_drop_probe PRIVATE "${FLUTTER_ROOT}" "${FLUTTER_ROOT}/cpp_client_wrapper/include")
target_link_libraries(desktop_drop_probe PRIVATE
  "${APP_ROOT}/build/windows/x64/flutter/Debug/flutter_wrapper_plugin.lib"
  "${FLUTTER_ROOT}/flutter_windows.dll.lib" ole32 shell32)
add_custom_command(TARGET desktop_drop_probe POST_BUILD COMMAND ${CMAKE_COMMAND} -E copy_if_different
  "${FLUTTER_ROOT}/flutter_windows.dll" "$<TARGET_FILE_DIR:desktop_drop_probe>")
