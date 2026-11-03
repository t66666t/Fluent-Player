cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "clipboard_revision.cc"
  "file_picker.cc"
  "desktop_media_controls.cc"
  "${LINUX_PLUGIN_REGISTRANT}"
)
apply_standard_settings(${BINARY_NAME})
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")
target_link_libraries(${BINARY_NAME} PRIVATE flutter PkgConfig::GTK)
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
