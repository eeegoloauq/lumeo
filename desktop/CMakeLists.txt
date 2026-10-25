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

qt_add_executable(lumeo-desktop src/main.cpp)

qt_add_qml_module(lumeo-desktop
  URI Lumeo
  QML_FILES
    qml/Main.qml
    qml/Browse.qml
    qml/Player.qml
  SOURCES
    src/core.h src/core.cpp
    src/mpvitem.h src/mpvitem.cpp
)

# The generated type registrations include the headers by their bare names.
target_include_directories(lumeo-desktop PRIVATE src)

target_compile_definitions(lumeo-desktop PRIVATE
  # The prototype reads the shaders where the Flutter client keeps them.
  LUMEO_ANIME4K_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../client/assets/anime4k"
)

target_link_libraries(lumeo-desktop PRIVATE
  Qt6::Quick Qt6::QuickControls2 Qt6::Network PkgConfig::MPV
)
