# Resolve a Laplace source checkout before loading its CMake helpers.
# Environment and sibling/fallback defaults must not become persistent cache
# overrides. Explicit cache (-DVAR=...) and parent selections remain
# authoritative, including existing cache entries until cleared with -U.
macro(laplace_resolve_source_path var fallback doc)
  if(NOT DEFINED ${var} OR "${${var}}" STREQUAL "")
    if(DEFINED ENV{${var}} AND NOT "$ENV{${var}}" STREQUAL "")
      set(${var} "$ENV{${var}}")
    else()
      set(${var} "${fallback}")
    endif()
  endif()
  if(DEFINED CACHE{${var}})
    set(${var} "${${var}}" CACHE PATH "${doc}")
  endif()
  file(TO_CMAKE_PATH "${${var}}" ${var})
endmacro()
