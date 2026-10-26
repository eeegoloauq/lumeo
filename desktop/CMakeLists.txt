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
    qml/BestMatch.qml
    qml/DownloadButton.qml
    qml/DownloadMark.qml
    qml/DownloadPanel.qml
    qml/EpisodeCard.qml
    qml/EpisodeStill.qml
    qml/EpisodesPanel.qml
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
    qml/SettingsMenu.qml
    qml/SearchField.qml
    qml/SearchPage.qml
    qml/ShelfRow.qml
    qml/SourcesDrawer.qml
    qml/Shell.qml
    qml/ShellPage.qml
    qml/Strip.qml
    qml/TintButton.qml
    qml/TitlePage.qml
    qml/Trouble.qml
    qml/MenuLabel.qml
    qml/MenuPanel.qml
    qml/MenuRow.qml
    qml/NextCard.qml
    qml/Player.qml
    qml/PlayerWaiting.qml
    qml/Scrubber.qml
    qml/Theme.qml
    qml/TracksMenu.qml
    qml/WheelScroll.qml
    qml/AboutSection.qml
    qml/AppearanceSection.qml
    qml/AudioSubtitlesSection.qml
    qml/LanguageList.qml
    qml/SettingsCard.qml
    qml/SubtitleSample.qml
    qml/ColourDots.qml
    qml/Confirm.qml
    qml/CopyButton.qml
    qml/DownloadsSection.qml
    qml/RowButton.qml
    qml/StorageBar.qml
    qml/ErrorRow.qml
    qml/GeneralSection.qml
    qml/NumberDialog.qml
    qml/PlaybackSection.qml
    qml/PreferenceStepper.qml
    qml/PresetChoice.qml
    qml/Segments.qml
    qml/SettingRow.qml
    qml/SettingSwitch.qml
    qml/SettingsBlock.qml
    qml/SettingsPage.qml
    qml/SettingsWait.qml
    qml/ShortcutsSection.qml
    qml/SourcesSection.qml
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
    icons/closed_caption.svg
    icons/closed_caption_outlined.svg
    icons/download.svg
    icons/error.svg
    icons/fullscreen.svg
    icons/fullscreen_exit.svg
    icons/ios_share.svg
    icons/pause.svg
    icons/play_arrow.svg
    icons/play_circle.svg
    icons/playlist_play.svg
    icons/remove.svg
    icons/search.svg
    icons/settings.svg
    icons/skip_next.svg
    icons/star.svg
    icons/star_border.svg
    icons/tune.svg
    icons/volume_down.svg
    icons/volume_off.svg
    icons/volume_up.svg
  SOURCES
    src/api/core.h src/api/core.cpp
    src/api/artwork.h src/api/artwork.cpp
    src/api/home.h src/api/home.cpp
    src/api/title.h src/api/title.cpp
    src/api/mine.h src/api/mine.cpp
    src/api/search.h src/api/search.cpp
    src/api/addons.h src/api/addons.cpp
    src/api/downloads.h src/api/downloads.cpp
    src/api/preferences.h src/api/preferences.cpp
    src/api/languages.h src/api/languages.cpp
    src/api/storage.h src/api/storage.cpp
    src/api/corestatus.h src/api/corestatus.cpp
    src/platform/desktop.h src/platform/desktop.cpp
    src/platform/folders.h src/platform/folders.cpp
    src/platform/fonts.h src/platform/fonts.cpp
    src/platform/language.h src/platform/language.cpp
    src/platform/settings.h src/platform/settings.cpp
    src/player/mpvitem.h src/player/mpvitem.cpp
    src/player/playback.h src/player/playback.cpp
    src/player/tracks.h src/player/tracks.cpp
    src/player/rows.h src/player/rows.cpp
    src/player/next.h src/player/next.cpp
    src/player/framegrabber.h src/player/framegrabber.cpp
    src/player/previews.h src/player/previews.cpp
    src/player/mpvfacts.h src/player/mpvfacts.cpp
    src/player/episodeframes.h src/player/episodeframes.cpp
    src/player/subtitlestyle.h src/player/subtitlestyle.cpp
    src/prototype.h src/prototype.cpp
)

# The generated type registrations include the headers by their bare names.
target_include_directories(lumeo PUBLIC src src/api src/player src/platform)

target_link_libraries(lumeo PUBLIC
  Qt6::Quick Qt6::QuickControls2 Qt6::Network Qt6::Svg Qt6::Concurrent PkgConfig::MPV
)

target_compile_definitions(lumeo PRIVATE
  # mpv reads the shaders as files; they are the Flutter client's until it
  # goes, and packages install them where the player reads them (docs/qt-port.md,
  # step 5).
  LUMEO_ANIME4K_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../client/assets/anime4k"
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

# What the client says it is; a release passes its tag's.
set(LUMEO_VERSION "dev" CACHE STRING "The client's version")
qt_add_executable(lumeo-desktop src/main.cpp)
target_link_libraries(lumeo-desktop PRIVATE lumeo lumeoplugin)
target_compile_definitions(lumeo-desktop PRIVATE LUMEO_VERSION="${LUMEO_VERSION}")

include(CTest)
if(BUILD_TESTING)
  add_subdirectory(tests)
endif()
