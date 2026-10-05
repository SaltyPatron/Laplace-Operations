# The Laplace toolchain for CMake: icx, and the floating-point contract in determinism.tsv on every C and C++ target.
# Use as -DCMAKE_TOOLCHAIN_FILE=<Laplace-Operations>/toolchain/laplace.cmake, from the oneAPI dev shell, with
# -DLAPLACE_MATH=<laplace-math static library>: every executable and shared library then takes its libm functions from
# laplace-math, whatever it lists after. Building laplace-math itself needs no LAPLACE_MATH.
set(CMAKE_C_COMPILER icx)
if(WIN32 OR CMAKE_HOST_WIN32)
  set(CMAKE_CXX_COMPILER icx)                          # icx-cl compiles C++ too; Windows has no icpx-style driver
else()
  set(CMAKE_CXX_COMPILER icpx)
endif()

include("${CMAKE_CURRENT_LIST_DIR}/flags.cmake")
laplace_fp_flags(_laplace_compile _laplace_link)
list(JOIN _laplace_compile " " _laplace_compile)
list(JOIN _laplace_link " " _laplace_link)
set(CMAKE_C_FLAGS_INIT "${_laplace_compile}")
set(CMAKE_CXX_FLAGS_INIT "${_laplace_compile}")
foreach(_kind EXE SHARED MODULE)
  set(CMAKE_${_kind}_LINKER_FLAGS_INIT "${_laplace_link}")
endforeach()

# laplace-math ahead of every libm. On Linux a static library listed after -lm would lose to libm.so, so it goes in
# whole. On Windows link.exe resolves a reference from the libraries after the one that made it before it wraps
# around, and every icx object names libmmd (Intel's libm) as a default library, searched last: a static library listed
# after laplace-math took sin from libmmd. So libmmd is no default library, and every link ends with laplace-math, then
# libmmd for the exact operations laplace-math leaves to it (determinism.tsv).
set(LAPLACE_MATH "$ENV{LAPLACE_MATH}" CACHE FILEPATH "laplace-math static library (core-math under the libm names)")
if(LAPLACE_MATH)
  if(NOT EXISTS "${LAPLACE_MATH}")
    message(FATAL_ERROR "LAPLACE_MATH: ${LAPLACE_MATH} does not exist")
  endif()
  if(CMAKE_HOST_WIN32)
    foreach(_kind EXE SHARED MODULE)
      string(APPEND CMAKE_${_kind}_LINKER_FLAGS_INIT " /NODEFAULTLIB:libmmd.lib")
    endforeach()
    foreach(_lang C CXX)
      # The standard libraries close every link line. The cache entry is the one CMake's MSVC platform would create,
      # with laplace-math and libmmd appended.
      set(CMAKE_${_lang}_STANDARD_LIBRARIES "kernel32.lib user32.lib gdi32.lib winspool.lib shell32.lib ole32.lib oleaut32.lib uuid.lib comdlg32.lib advapi32.lib \"${LAPLACE_MATH}\" libmmd.lib"
        CACHE STRING "Libraries linked by default with all ${_lang} applications.")
    endforeach()
  else()
    foreach(_kind EXE SHARED MODULE)
      string(APPEND CMAKE_${_kind}_LINKER_FLAGS_INIT " -Wl,--whole-archive ${LAPLACE_MATH} -Wl,--no-whole-archive")
    endforeach()
  endif()
endif()
