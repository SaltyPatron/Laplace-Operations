# laplace-math: the static library every Laplace build links ahead of the platform libm (see names.c). Built with
# toolchain/laplace.cmake from the CORE-MATH checkout the manifest pins:
#   cmake -S math -B <build> -G Ninja -DCMAKE_TOOLCHAIN_FILE=toolchain/laplace.cmake -DCORE_MATH=<checkout>
#         -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=<deps>/laplace-math/<pin>
cmake_minimum_required(VERSION 3.25)
project(laplace_math C)

set(CORE_MATH "" CACHE PATH "CORE-MATH checkout")
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

# The fingerprint (test/determinism.c), linked the way every consumer links laplace-math: ahead of libm, through the
# toolchain's own rule, not by naming the library on this target.
enable_testing()
add_executable(determinism test/determinism.c)
add_dependencies(determinism laplace_math)
if(MSVC)
  target_link_options(determinism PRIVATE "$<TARGET_FILE:laplace_math>")
else()
  target_link_options(determinism PRIVATE -Wl,--whole-archive "$<TARGET_FILE:laplace_math>" -Wl,--no-whole-archive)
  target_link_libraries(determinism PRIVATE m)
endif()
add_test(NAME determinism COMMAND determinism)
