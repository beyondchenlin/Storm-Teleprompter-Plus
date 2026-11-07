cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Use an ASCII logical target while preserving the branded executable name.
# Change BINARY_NAME in the top-level CMakeLists.txt to change the on-disk name;
# Flutter also reads that value to locate the executable for `flutter run`.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_TARGET} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)
set_target_properties(${BINARY_TARGET} PROPERTIES OUTPUT_NAME "${BINARY_NAME}")

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_TARGET})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_TARGET} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_TARGET} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_TARGET} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_TARGET} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_TARGET} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_TARGET} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_TARGET} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_TARGET} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_TARGET} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_TARGET} flutter_assemble)
