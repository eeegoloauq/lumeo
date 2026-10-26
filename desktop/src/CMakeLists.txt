# The executable is made here rather than beside the module: the deploy ships
# the QML imports it finds under the target's own directory, and desktop/
# holds the tests and, often, a build tree laid out as the bundle, every Qt
# style in it. Here there is no QML, so the scan is the module's alone.
# QT_QML_IMPORT_SCANNER_EXTRA_ROOT_PATHS is Qt's own setting for QML that
# lives outside the target's directory (Qt6QmlMacros.cmake), not documented.

# What the client says it is; a release passes its tag's.
set(LUMEO_VERSION "dev" CACHE STRING "The client's version")
qt_add_executable(lumeo-desktop main.cpp)
target_link_libraries(lumeo-desktop PRIVATE lumeo lumeoplugin)
target_compile_definitions(lumeo-desktop PRIVATE LUMEO_VERSION="${LUMEO_VERSION}")
set_target_properties(lumeo-desktop PROPERTIES
  OUTPUT_NAME lumeo
  RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
  WIN32_EXECUTABLE TRUE
)
set_property(TARGET lumeo-desktop PROPERTY QT_QML_IMPORT_SCANNER_EXTRA_ROOT_PATHS ${PROJECT_SOURCE_DIR}/qml)
if(WIN32)
  # The icon Explorer, the taskbar and the window show.
  target_sources(lumeo-desktop PRIVATE ${PROJECT_SOURCE_DIR}/lumeo.rc)
endif()

# The install is the bundle a package carries whole: the binary, the Qt it
# was built and tested with (lib/, plugins/, qml/), and the shaders. libmpv
# stays the system's (decisions/shipping.md).
install(TARGETS lumeo-desktop RUNTIME DESTINATION bin)
install(DIRECTORY ${anime4k}/ DESTINATION share/lumeo/anime4k)
# Qt's own translations are for its dialogs, which are the system's here.
if(WIN32)
  # windeployqt lays Qt out beside the binary, the compiler's runtime with it.
  qt_generate_deploy_qml_app_script(TARGET lumeo-desktop OUTPUT_SCRIPT deploy NO_TRANSLATIONS)
  install(FILES ${MPV_DIR}/libmpv-2.dll DESTINATION bin)
else()
  # Wayland alongside X11, which the deploy would leave as the only platform;
  # not the QML debugger, nor the plugins for a device with no desktop, nor
  # the GTK theme, which would pull GTK in where the portal's theme serves.
  qt_generate_deploy_qml_app_script(TARGET lumeo-desktop OUTPUT_SCRIPT deploy NO_TRANSLATIONS
    INCLUDE_PLUGINS qwayland
    EXCLUDE_PLUGINS qgtk3
    EXCLUDE_PLUGIN_TYPES qmltooling generic egldeviceintegrations networkinformation)
  # What the deploy leaves out: the system's libraries, which it finds in the
  # compiler's directories, and libmpv wherever pkg-config found it.
  install(CODE "set(QT_DEPLOY_IGNORED_LIB_DIRS \"${CMAKE_CXX_IMPLICIT_LINK_DIRECTORIES};${MPV_LIBRARY_DIRS}\")")
endif()
install(SCRIPT ${deploy})
