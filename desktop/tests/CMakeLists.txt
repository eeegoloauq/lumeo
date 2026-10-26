find_package(Qt6 REQUIRED COMPONENTS Test HttpServer)

# The fake core: QHttpServer is GPL, which is fine for tests, never shipped.
add_library(fakecore STATIC fakecore.h fakecore.cpp)
target_link_libraries(fakecore PUBLIC Qt6::HttpServer)
target_include_directories(fakecore PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_definitions(fakecore PRIVATE
  # Shared with the Flutter client until it goes (docs/qt-port.md).
  LUMEO_FIXTURES="${CMAKE_CURRENT_SOURCE_DIR}/../../client/test/fixtures/core"
)

# Units: one executable per file under QtTest.
foreach(name artwork core facts home l10n library mpv next search settings stores title tracks)
  qt_add_executable(${name}_test ${name}_test.cpp)
  target_link_libraries(${name}_test PRIVATE lumeo fakecore Qt6::Test)
  add_test(NAME ${name} COMMAND ${name}_test)
endforeach()

# Pictures are decoded under a QGuiApplication, which needs a platform.
set_tests_properties(artwork PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

target_compile_definitions(l10n_test PRIVATE LUMEO_QML="${CMAKE_CURRENT_SOURCE_DIR}/../qml")

# App tests: the whole app over the fake core, under Qt Quick Test.
find_package(Qt6 REQUIRED COMPONENTS QuickTest)
qt_add_executable(app_test app/main.cpp)
target_link_libraries(app_test PRIVATE lumeo lumeoplugin fakecore Qt6::QuickTest)
target_compile_definitions(app_test PRIVATE QUICK_TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/app")
add_test(NAME app COMMAND app_test)
# No GPU and no display needed; the player tests have their own run.
set_tests_properties(app PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

# Player tests: a real libmpv on headless Weston, through tool/player-test.sh.
qt_add_executable(player_test player/main.cpp)
target_link_libraries(player_test PRIVATE lumeo lumeoplugin fakecore Qt6::QuickTest)
target_compile_definitions(player_test PRIVATE QUICK_TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/player")
