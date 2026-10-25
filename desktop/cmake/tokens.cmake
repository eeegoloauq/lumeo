# Writes design/tokens.json as Tokens.qml, a singleton with one read-only
# property each: a colour as color, with the alpha moved first as Qt reads it,
# any other string as string, a number as real.
function(lumeo_tokens json out)
  file(READ "${json}" tokens)
  string(JSON count LENGTH "${tokens}")
  math(EXPR last "${count} - 1")
  # CMake's expressions have no counted repeats.
  string(REPEAT "[0-9a-fA-F]" 6 rgb)
  string(REPEAT "[0-9a-fA-F]" 2 alpha)
  set(body "")
  foreach(i RANGE ${last})
    string(JSON name MEMBER "${tokens}" ${i})
    string(JSON type TYPE "${tokens}" "${name}")
    string(JSON value GET "${tokens}" "${name}")
    if(type STREQUAL "NUMBER")
      string(APPEND body "    readonly property real ${name}: ${value}\n")
    elseif(value MATCHES "^#(${rgb})(${alpha})?$")
      string(APPEND body "    readonly property color ${name}: \"#${CMAKE_MATCH_2}${CMAKE_MATCH_1}\"\n")
    else()
      string(APPEND body "    readonly property string ${name}: \"${value}\"\n")
    endif()
  endforeach()
  file(CONFIGURE OUTPUT "${out}" CONTENT
"// Generated from design/tokens.json by desktop/cmake/tokens.cmake.
pragma Singleton
import QtQuick

QtObject {
${body}}
" @ONLY)
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${json}")
endfunction()
