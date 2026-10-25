cmake_minimum_required(VERSION 3.22)
project(lumeo-desktop LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 6.8 is the oldest LTS the distributions' own Qt might be; development and
# CI run 6.12 (docs/qt-port.md, Open questions).
find_package(Qt6 6.8 REQUIRED COMPONENTS Quick QuickControls2 Network)
find_package(PkgConfig REQUIRED)
pkg_check_modules(MPV REQUIRED IMPORTED_TARGET mpv)

qt_standard_project_setup(REQUIRES 6.8)

# Everything but main(), so the tests load the module the app does.
qt_add_library(lumeo STATIC)
qt_add_qml_module(lumeo
  URI Lumeo
  # Where tooling such as qmllint looks for a module named Lumeo.
  OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/Lumeo
  QML_FILES
    qml/Main.qml
    qml/Browse.qml
    qml/Player.qml
  SOURCES
    src/api/core.h src/api/core.cpp
    src/api/addons.h src/api/addons.cpp
    src/api/downloads.h src/api/downloads.cpp
    src/api/preferences.h src/api/preferences.cpp
    src/player/mpvitem.h src/player/mpvitem.cpp
    src/prototype.h src/prototype.cpp
)

# The generated type registrations include the headers by their bare names.
target_include_directories(lumeo PUBLIC src src/api src/player src/platform)

target_compile_definitions(lumeo PRIVATE
  # The prototype reads the shaders where the Flutter client keeps them.
  LUMEO_ANIME4K_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../client/assets/anime4k"
)

target_link_libraries(lumeo PUBLIC
  Qt6::Quick Qt6::QuickControls2 Qt6::Network PkgConfig::MPV
)

qt_add_executable(lumeo-desktop src/main.cpp)
target_link_libraries(lumeo-desktop PRIVATE lumeo lumeoplugin)

include(CTest)
if(BUILD_TESTING)
  add_subdirectory(tests)
endif()
