cmake_minimum_required(VERSION 3.22)
project(lumeo-desktop LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 6.8 is the oldest LTS the distributions' own Qt might be; development and
# CI run 6.12 (docs/qt-port.md, Open questions).
find_package(Qt6 6.8 REQUIRED COMPONENTS Quick QuickControls2 Network LinguistTools)
find_package(PkgConfig REQUIRED)
pkg_check_modules(MPV REQUIRED IMPORTED_TARGET mpv)

qt_standard_project_setup(REQUIRES 6.8)

include(cmake/tokens.cmake)
lumeo_tokens(${CMAKE_CURRENT_SOURCE_DIR}/../design/tokens.json
  ${CMAKE_CURRENT_BINARY_DIR}/Tokens.qml)
set_source_files_properties(${CMAKE_CURRENT_BINARY_DIR}/Tokens.qml PROPERTIES
  QT_RESOURCE_ALIAS Tokens.qml QT_QML_SINGLETON_TYPE TRUE)
set_source_files_properties(qml/Theme.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

# Shared with the Flutter client until it goes (docs/qt-port.md); loaded
# from :/qt/qml/Lumeo/fonts.
file(GLOB fonts ${CMAKE_CURRENT_SOURCE_DIR}/../client/assets/fonts/*.ttf)
foreach(font ${fonts})
  get_filename_component(name ${font} NAME)
  set_source_files_properties(${font} PROPERTIES QT_RESOURCE_ALIAS fonts/${name})
endforeach()

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
    qml/Theme.qml
    ${CMAKE_CURRENT_BINARY_DIR}/Tokens.qml
  RESOURCES ${fonts}
  SOURCES
    src/api/core.h src/api/core.cpp
    src/api/addons.h src/api/addons.cpp
    src/api/downloads.h src/api/downloads.cpp
    src/api/preferences.h src/api/preferences.cpp
    src/platform/fonts.h src/platform/fonts.cpp
    src/platform/language.h src/platform/language.cpp
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

# The interface's text, by id (qsTrId): the .ts files are the source, and
# lupdate is not run over the code.
qt_add_translations(lumeo
  TS_FILES i18n/lumeo_en.ts i18n/lumeo_ru.ts
  RESOURCE_PREFIX /i18n
  LRELEASE_OPTIONS -idbased
  NO_GENERATE_PLURALS_TS_FILE
)

qt_add_executable(lumeo-desktop src/main.cpp)
target_link_libraries(lumeo-desktop PRIVATE lumeo lumeoplugin)

include(CTest)
if(BUILD_TESTING)
  add_subdirectory(tests)
endif()
