find_package(Qt6 REQUIRED COMPONENTS Test HttpServer)

# The fake core: QHttpServer is GPL, which is fine for tests, never shipped.
add_library(fakecore STATIC fakecore.h fakecore.cpp)
target_link_libraries(fakecore PUBLIC Qt6::HttpServer)
target_include_directories(fakecore PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_definitions(fakecore PRIVATE
  LUMEO_FIXTURES="${CMAKE_CURRENT_SOURCE_DIR}/fixtures"
)

# Units: one executable per file under QtTest.
foreach(name artwork connection core facts home l10n library mpv next opening releases search settings stores title tracks)
  qt_add_executable(${name}_test ${name}_test.cpp)
  target_link_libraries(${name}_test PRIVATE lumeo fakecore Qt6::Test)
  # Some Windows runs leave CTest's captured stream empty on failure.
  # QtTest's file logger preserves the assertion independently of that stream.
  add_test(NAME ${name} COMMAND ${name}_test
    -o ${CMAKE_CURRENT_BINARY_DIR}/${name}-results.txt,txt -o -,txt)
endforeach()

target_compile_definitions(connection_test PRIVATE LUMEO_TEST_TLS="${CMAKE_CURRENT_SOURCE_DIR}/fixtures/localhost.pem")

# Pictures are decoded under a QGuiApplication, which needs a platform.
set_tests_properties(artwork PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

target_compile_definitions(l10n_test PRIVATE LUMEO_QML="${CMAKE_CURRENT_SOURCE_DIR}/../qml")

# App tests: the whole app over the fake core, under Qt Quick Test.
find_package(Qt6 REQUIRED COMPONENTS QuickTest)
qt_add_executable(app_test app/main.cpp)
target_link_libraries(app_test PRIVATE lumeo lumeoplugin fakecore Qt6::QuickTest)
target_compile_definitions(app_test PRIVATE QUICK_TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/app")
add_test(NAME app COMMAND app_test
  -o ${CMAKE_CURRENT_BINARY_DIR}/app-results.txt,txt -o -,txt)
# No GPU and no display needed; the player tests have their own run.
set_tests_properties(app PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

# Player tests: a real libmpv on headless Weston, through tool/player-test.sh.
qt_add_executable(player_test player/main.cpp)
target_link_libraries(player_test PRIVATE lumeo lumeoplugin fakecore Qt6::QuickTest)
target_compile_definitions(player_test PRIVATE QUICK_TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/player")

# qmllint as a test, so every ctest run has it; qml/.qmllint.ini makes a
# warning fail it.
add_test(NAME qmllint COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target lumeo_qmllint)
