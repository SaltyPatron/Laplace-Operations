# laplace-math: the static library every Laplace build links ahead of the platform libm (see names.c), from the
# CORE-MATH checkout the manifest pins. Standalone:
#   cmake -S math -B <build> -G Ninja -DCMAKE_TOOLCHAIN_FILE=toolchain/laplace.cmake -DCORE_MATH=<checkout>
#         -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=<deps>/laplace-math/<pin>
# or inside another build (Laplace-Native): add_subdirectory(<Laplace-Operations>/math) with CORE_MATH set, then link
# laplace::math, which carries the whole-archive link and the contract's link flags.
cmake_minimum_required(VERSION 3.25)
project(laplace_math C)

set(CORE_MATH "" CACHE PATH "CORE-MATH checkout")
include("${CMAKE_CURRENT_SOURCE_DIR}/../toolchain/flags.cmake")
laplace_fp_flags(LAPLACE_FP_COMPILE LAPLACE_FP_LINK)   # applied here too: CORE-MATH is only correctly rounded under it
if(NOT EXISTS "${CORE_MATH}/src/binary64/cos/cos.c")
  message(FATAL_ERROR "CORE_MATH: no CORE-MATH checkout at '${CORE_MATH}'")
endif()

# Every function CORE-MATH has, in both precisions: <dir>/<dir>.c and <dir>/<dir>f.c. compound (binary32 only) is not
# a C library function and stays out.
set(FUNCTIONS acos acosh acospi asin asinh asinpi atan atan2 atan2pi atanh atanpi cbrt cos cosh cospi erf erfc exp
    exp10 exp10m1 exp2 exp2m1 expm1 hypot lgamma log log10 log10p1 log1p log2 log2p1 pow rsqrt sin sincos sinh sinpi
    tan tanh tanpi tgamma)
set(SOURCES names.c)
foreach(f IN LISTS FUNCTIONS)
  list(APPEND SOURCES "${CORE_MATH}/src/binary64/${f}/${f}.c" "${CORE_MATH}/src/binary32/${f}/${f}f.c")
endforeach()

add_library(laplace_math STATIC ${SOURCES})
set_target_properties(laplace_math PROPERTIES OUTPUT_NAME laplace-math)
target_compile_options(laplace_math PRIVATE ${LAPLACE_FP_COMPILE})
# errno as the C library sets it (EDOM, ERANGE): callers such as PostgreSQL check it.
target_compile_definitions(laplace_math PRIVATE CORE_MATH_SUPPORT_ERRNO)
# Under icx CORE-MATH's rsqrt and rsqrtf are Intel's invsqrt; without the compiler's macro they are its own, and
# names.c gives them their names like every other function.
set_source_files_properties("${CORE_MATH}/src/binary64/rsqrt/rsqrt.c" "${CORE_MATH}/src/binary32/rsqrt/rsqrtf.c"
  PROPERTIES COMPILE_OPTIONS "-U__INTEL_CLANG_COMPILER")
if(MSVC)
  # No default-library directive in the objects, so the one library serves /MT and /MD links alike; signgam declared
  # for CORE-MATH's lgamma.
  target_compile_options(laplace_math PRIVATE /Zl)
  set_source_files_properties("${CORE_MATH}/src/binary64/lgamma/lgamma.c" "${CORE_MATH}/src/binary32/lgamma/lgammaf.c"
    PROPERTIES COMPILE_OPTIONS "/FI${CMAKE_CURRENT_SOURCE_DIR}/signgam.h")
  target_compile_definitions(laplace_math PRIVATE _CRT_SECURE_NO_WARNINGS)
else()
  target_compile_options(laplace_math PRIVATE -fPIC)
endif()
install(TARGETS laplace_math ARCHIVE DESTINATION lib)

# What a consumer links: laplace-math ahead of every libm, and the contract's link flags. On Linux a static library
# listed after -lm would lose to libm.so, so it goes in whole; on Windows a library on the command line is searched
# before the compiler's default libraries (libmmd, the UCRT), which is enough (and CMake spells WHOLE_ARCHIVE for icx
# there in GNU form, which link.exe does not take).
add_library(laplace_math_link INTERFACE)
add_library(laplace::math ALIAS laplace_math_link)
if(MSVC)
  # CORE-MATH's int128 conversions (__floattidf and kin) use the compiler's builtins runtime on Windows.
  execute_process(COMMAND "${CMAKE_C_COMPILER}" -print-resource-dir
    OUTPUT_VARIABLE _compiler_resource OUTPUT_STRIP_TRAILING_WHITESPACE)
  find_library(_compiler_builtins NAMES clang_rt.builtins-x86_64
    PATHS "${_compiler_resource}/lib/windows" NO_DEFAULT_PATH REQUIRED)
  target_link_libraries(laplace_math_link INTERFACE laplace_math "${_compiler_builtins}")
else()
  # Then libm itself, for the exact operations laplace-math leaves to it (sqrt, fmax, the fenv calls), after the
  # library so a linker that drops unused libraries (--as-needed) keeps it. Its own imported target: CMake would fold
  # a plain m into an earlier -lm, before laplace-math.
  add_library(laplace_math_libm INTERFACE IMPORTED)
  set_target_properties(laplace_math_libm PROPERTIES IMPORTED_LIBNAME m)
  target_link_libraries(laplace_math_link INTERFACE "$<LINK_LIBRARY:WHOLE_ARCHIVE,laplace_math>" laplace_math_libm)
endif()
target_link_options(laplace_math_link INTERFACE ${LAPLACE_FP_LINK})

# The fingerprint (test/determinism.c), linked the way every consumer links laplace-math.
add_executable(determinism test/determinism.c)
target_compile_options(determinism PRIVATE ${LAPLACE_FP_COMPILE})
target_link_libraries(determinism PRIVATE laplace::math)
if(NOT MSVC)
  target_link_libraries(determinism PRIVATE m)
endif()
if(PROJECT_IS_TOP_LEVEL)
  enable_testing()
  add_test(NAME determinism COMMAND determinism)
else()
  set_target_properties(determinism PROPERTIES EXCLUDE_FROM_ALL ON)
endif()
