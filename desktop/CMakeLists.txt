cmake_minimum_required(VERSION 3.22)
project(lumeo-desktop LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 6.8 is the oldest LTS the distributions' own Qt might be; development and
# CI run 6.12 (docs/qt-port.md, Open questions).
find_package(Qt6 6.8 REQUIRED COMPONENTS Quick QuickControls2 Network Svg Concurrent ShaderTools
  LinguistTools)
find_package(PkgConfig REQUIRED)
pkg_check_modules(MPV REQUIRED IMPORTED_TARGET mpv)

qt_standard_project_setup(REQUIRES 6.8)

include(cmake/tokens.cmake)
lumeo_tokens(${CMAKE_CURRENT_SOURCE_DIR}/../design/tokens.json
  ${CMAKE_CURRENT_BINARY_DIR}/Tokens.qml)
set_source_files_properties(${CMAKE_CURRENT_BINARY_DIR}/Tokens.qml PROPERTIES
  QT_RESOURCE_ALIAS Tokens.qml QT_QML_SINGLETON_TYPE TRUE)
set_source_files_properties(qml/Theme.qml qml/Words.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

# Plex Sans speaks and Unbounded is the wordmark (decisions/interface.md);
# shared with the Flutter client until it goes (docs/qt-port.md), and loaded
# from :/qt/qml/Lumeo/fonts.
set(fonts)
foreach(name IBMPlexSans-400 IBMPlexSans-500 IBMPlexSans-600 IBMPlexSans-700 Unbounded)
  set(font ${CMAKE_CURRENT_SOURCE_DIR}/../client/assets/fonts/${name}.ttf)
  set_source_files_properties(${font} PROPERTIES QT_RESOURCE_ALIAS fonts/${name}.ttf)
  list(APPEND fonts ${font})
endforeach()

# Everything but main(), so the tests load the module the app does.
qt_add_library(lumeo STATIC)
qt_add_qml_module(lumeo
  URI Lumeo
  # Where tooling such as qmllint looks for a module named Lumeo.
  OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/Lumeo
  QML_FILES
    qml/Main.qml
    qml/Banner.qml
    qml/Bar.qml
    qml/Browse.qml
    qml/DownloadButton.qml
    qml/DownloadMark.qml
    qml/EpisodeCard.qml
    qml/Glyph.qml
    qml/Heading.qml
    qml/HomePage.qml
    qml/HeroLogo.qml
    qml/IconButton.qml
    qml/Loading.qml
    qml/PillTab.qml
    qml/PlayButton.qml
    qml/PlayLine.qml
    qml/PosterTile.qml
    qml/QuietButton.qml
    qml/RatingButton.qml
    qml/ShelfRow.qml
    qml/SourcesDrawer.qml
    qml/Shell.qml
    qml/ShellPage.qml
    qml/Strip.qml
    qml/TintButton.qml
    qml/TitlePage.qml
    qml/Trouble.qml
    qml/Player.qml
    qml/Theme.qml
    qml/Words.qml
    qml/format.js
    ${CMAKE_CURRENT_BINARY_DIR}/Tokens.qml
  RESOURCES
    ${fonts}
    # Material Symbols, Apache 2.0 (icons/LICENSE): only the ones in use.
    icons/add.svg
    icons/arrow_back.svg
    icons/arrow_drop_down.svg
    icons/check.svg
    icons/chevron_left.svg
    icons/chevron_right.svg
    icons/close.svg
    icons/download.svg
    icons/error.svg
    icons/ios_share.svg
    icons/play_arrow.svg
    icons/play_circle.svg
    icons/search.svg
    icons/star.svg
    icons/star_border.svg
  SOURCES
    src/api/core.h src/api/core.cpp
    src/api/artwork.h src/api/artwork.cpp
    src/api/home.h src/api/home.cpp
    src/api/title.h src/api/title.cpp
    src/api/mine.h src/api/mine.cpp
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
  Qt6::Quick Qt6::QuickControls2 Qt6::Network Qt6::Svg Qt6::Concurrent PkgConfig::MPV
)

# The banner's scrim, compiled for every graphics API Qt might run on.
qt_add_shaders(lumeo "shaders"
  PREFIX /qt/qml/Lumeo
  FILES shaders/scrim.frag
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
