/* laplace-math: CORE-MATH's correctly rounded functions under the C library's names, so every call in every Laplace
 * build (Native, Engine, PostgreSQL, PostGIS, GEOS, PROJ, GDAL, SFCGAL...) gets the one right answer instead of the
 * platform libm's. CORE-MATH sets errno (built with CORE_MATH_SUPPORT_ERRNO) and signgam as the C library does.
 * No <math.h>: its declarations (and the Windows UCRT's inline wrappers) are exactly what this file replaces. */

#ifdef _WIN32
int signgam;                                          /* POSIX's, for lgamma; the UCRT has none */
/* CORE-MATH converts 128-bit integers (__floattidf and kin); on Windows those come from the compiler's own runtime,
 * which no other library on the link line provides. Exact conversions: no result changes. */
#pragma comment(lib, "clang_rt.builtins-x86_64.lib")
#endif

#ifdef _WIN32
/* A call compiled against a header that declares the function dllimport (icx's does for exp10 and the C23 names)
 * goes through __imp_<name>, not <name>: laplace-math answers that spelling too, so neither reaches libmmd. */
#define IMP(t, f, a) t (*__imp_##f) a = f;
#else
#define IMP(t, f, a)
#endif
#define D1(f) double cr_##f(double); double f(double x){ return cr_##f(x); } IMP(double, f, (double))
#define D2(f) double cr_##f(double, double); double f(double y, double x){ return cr_##f(y, x); } IMP(double, f, (double, double))
#define F1(f) float cr_##f(float); float f(float x){ return cr_##f(x); } IMP(float, f, (float))
#define F2(f) float cr_##f(float, float); float f(float y, float x){ return cr_##f(y, x); } IMP(float, f, (float, float))

D1(acos) D1(acosh) D1(asin) D1(asinh) D1(atan) D2(atan2) D1(atanh) D1(cbrt) D1(cos) D1(cosh) D1(erf) D1(erfc)
D1(exp) D1(exp10) D1(exp2) D1(expm1) D2(hypot) D1(lgamma) D1(log) D1(log10) D1(log1p) D1(log2) D2(pow) D1(sin)
D1(sinh) D1(tan) D1(tanh) D1(tgamma)
D1(acospi) D1(asinpi) D1(atanpi) D2(atan2pi) D1(cospi) D1(sinpi) D1(tanpi) D1(exp10m1) D1(exp2m1) D1(log10p1)
D1(log2p1) D1(rsqrt)

F1(acosf) F1(acoshf) F1(asinf) F1(asinhf) F1(atanf) F2(atan2f) F1(atanhf) F1(cbrtf) F1(cosf) F1(coshf) F1(erff)
F1(erfcf) F1(expf) F1(exp10f) F1(exp2f) F1(expm1f) F2(hypotf) F1(lgammaf) F1(logf) F1(log10f) F1(log1pf) F1(log2f)
F2(powf) F1(sinf) F1(sinhf) F1(tanf) F1(tanhf) F1(tgammaf)
F1(acospif) F1(asinpif) F1(atanpif) F2(atan2pif) F1(cospif) F1(sinpif) F1(tanpif) F1(exp10m1f) F1(exp2m1f)
F1(log10p1f) F1(log2p1f) F1(rsqrtf)

void cr_sincos(double, double *, double *);
void sincos(double x, double *s, double *c){ cr_sincos(x, s, c); }
void cr_sincosf(float, float *, float *);
void sincosf(float x, float *s, float *c){ cr_sincosf(x, s, c); }
IMP(void, sincos, (double, double *, double *)) IMP(void, sincosf, (float, float *, float *))

#ifdef _WIN32
/* The UCRT's hypotf is an inline wrapper around _hypotf, and _hypot is its other spelling of hypot. */
double _hypot(double y, double x){ return cr_hypot(y, x); }
float _hypotf(float y, float x){ return cr_hypotf(y, x); }
IMP(double, _hypot, (double, double)) IMP(float, _hypotf, (float, float))
#endif
