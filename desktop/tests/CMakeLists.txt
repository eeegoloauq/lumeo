find_package(Qt6 REQUIRED COMPONENTS Test HttpServer)

# The fake core: QHttpServer is GPL, which is fine for tests, never shipped.
add_library(fakecore STATIC fakecore.h fakecore.cpp)
target_link_libraries(fakecore PUBLIC Qt6::HttpServer)
target_compile_definitions(fakecore PRIVATE
  # Shared with the Flutter client until it goes (docs/qt-port.md).
  LUMEO_FIXTURES="${CMAKE_CURRENT_SOURCE_DIR}/../../client/test/fixtures/core"
)

# Units: one executable per file under QtTest.
foreach(name core)
  qt_add_executable(${name}_test ${name}_test.cpp)
  target_link_libraries(${name}_test PRIVATE lumeo fakecore Qt6::Test)
  add_test(NAME ${name} COMMAND ${name}_test)
endforeach()
