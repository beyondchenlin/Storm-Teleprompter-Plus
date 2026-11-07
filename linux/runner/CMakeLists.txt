cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# Use an ASCII logical target while preserving the branded executable name.
# Change BINARY_NAME in the top-level CMakeLists.txt to change the on-disk name;
# Flutter also reads that value to locate the executable for `flutter run`.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_TARGET}
  "main.cc"
  "my_application.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)
set_target_properties(${BINARY_TARGET} PROPERTIES OUTPUT_NAME "${BINARY_NAME}")

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_TARGET})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_TARGET} PRIVATE flutter)
target_link_libraries(${BINARY_TARGET} PRIVATE PkgConfig::GTK)

target_include_directories(${BINARY_TARGET} PRIVATE "${CMAKE_SOURCE_DIR}")
