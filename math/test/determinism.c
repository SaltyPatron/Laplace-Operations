/* The floating-point fingerprint of a machine and build: every laplace-math function over fixed inputs, and strtod
 * over fixed decimal strings, each hashed by its output bits. Two machines agree when their fingerprints are the
 * same text. It fails (exit 1) if a libm name does not resolve to laplace-math in this binary.
 * Every NaN hashes as one NaN: IEEE leaves a NaN's sign and payload open, and the compiler may commute a*b + c*d,
 * which changes which operand's NaN comes out (seen between the Linux and Windows builds). NaN is one value in the
 * contract; whatever hashes or stores float bits makes it canonical first. */
#include <math.h>
double rsqrt(double); double sinpi(double); double cospi(double);   /* C23 names no header here declares yet */
#ifndef _WIN32       /* glibc 2.35 does not declare it; icx's Windows header does, as a dllimport: that path is tested */
double exp10(double);
#endif
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define N 200000

static uint64_t mix(uint64_t *s){                    /* splitmix64 */
    uint64_t z = (*s += 0x9e3779b97f4a7c15u);
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9u; z = (z ^ (z >> 27)) * 0x94d049bb133111ebu; return z ^ (z >> 31);
}
static double bits_d(uint64_t u){ double d; memcpy(&d, &u, 8); return d; }
static float bits_f(uint32_t u){ float f; memcpy(&f, &u, 4); return f; }
static uint64_t of_d(double d){ uint64_t u; if (d != d) return 0x7ff8000000000000u; memcpy(&u, &d, 8); return u; }
static uint32_t of_f(float f){ uint32_t u; if (f != f) return 0x7fc00000u; memcpy(&u, &f, 4); return u; }
static void fnv(uint64_t *h, uint64_t v){ for (int i = 0; i < 8; i++) { *h ^= (v >> (8 * i)) & 0xff; *h *= 0x100000001b3u; } }

/* Inputs: raw bit patterns (every exponent, NaN, inf, subnormals), then dense ranges where the functions live. */
static double input_d(uint64_t *s, int i){
    uint64_t r = mix(s);
    switch (i % 4) {
    case 0: return bits_d(r);
    case 1: return ((double)(r >> 11) / 9007199254740992.0) * 2.0 - 1.0;           /* [-1, 1) */
    case 2: return ((double)(r >> 11) / 9007199254740992.0) * 40.0 - 20.0;         /* [-20, 20) */
    default: return ldexp((double)(r >> 11) / 9007199254740992.0, (int)(r & 127) - 64);
    }
}
static float input_f(uint64_t *s, int i){
    uint64_t r = mix(s);
    switch (i % 3) {
    case 0: return bits_f((uint32_t)r);
    case 1: return (float)((double)(r >> 40) / 16777216.0) * 2.0f - 1.0f;
    default: return (float)((double)(r >> 40) / 16777216.0) * 40.0f - 20.0f;
    }
}

typedef double (*d1)(double); typedef double (*d2)(double, double);
typedef float (*f1)(float); typedef float (*f2)(float, float);
#define CR1(f) double cr_##f(double);
#define CR2(f) double cr_##f(double, double);
#define CF1(f) float cr_##f(float);
#define CF2(f) float cr_##f(float, float);
CR1(acos) CR1(acosh) CR1(asin) CR1(asinh) CR1(atan) CR2(atan2) CR1(atanh) CR1(cbrt) CR1(cos) CR1(cosh) CR1(erf)
CR1(erfc) CR1(exp) CR1(exp2) CR1(expm1) CR2(hypot) CR1(lgamma) CR1(log) CR1(log10) CR1(log1p) CR1(log2) CR2(pow)
CR1(sin) CR1(sinh) CR1(tan) CR1(tanh) CR1(tgamma) CR1(rsqrt) CR1(exp10) CR1(sinpi) CR1(cospi)
CF1(acosf) CF1(asinf) CF1(atanf) CF2(atan2f) CF1(cosf) CF1(expf) CF1(logf) CF2(powf) CF1(sinf) CF1(tanf) CF1(tanhf)
CF1(log2f) CF1(exp2f) CF2(hypotf)

static const struct { const char *name; d1 f, cr; } D1[] = {
#define E(f) { #f, f, cr_##f },
    E(acos) E(acosh) E(asin) E(asinh) E(atan) E(atanh) E(cbrt) E(cos) E(cosh) E(erf) E(erfc) E(exp) E(exp2)
    E(expm1) E(lgamma) E(log) E(log10) E(log1p) E(log2) E(sin) E(sinh) E(tan) E(tanh) E(tgamma) E(rsqrt) E(exp10)
    E(sinpi) E(cospi)
#undef E
};
static const struct { const char *name; d2 f, cr; } D2[] = { { "atan2", atan2, cr_atan2 }, { "hypot", hypot, cr_hypot }, { "pow", pow, cr_pow } };
static const struct { const char *name; f1 f, cr; } F1[] = {
#define E(f) { #f, f, cr_##f },
    E(acosf) E(asinf) E(atanf) E(cosf) E(expf) E(logf) E(sinf) E(tanf) E(tanhf) E(log2f) E(exp2f)
#undef E
};
static const struct { const char *name; f2 f, cr; } F2[] = { { "atan2f", atan2f, cr_atan2f }, { "powf", powf, cr_powf }, { "hypotf", hypotf, cr_hypotf } };

static int wrong;
static void line(const char *name, uint64_t h, long off){
    printf("%-8s %016llx\n", name, (unsigned long long)h);
    if (off) { fprintf(stderr, "%s: %ld results differ from cr_%s: the libm name is not laplace-math here\n", name, off, name); wrong = 1; }
}

int main(void){
    for (size_t k = 0; k < sizeof D1 / sizeof *D1; k++) {
        uint64_t s = 1 + k, h = 0xcbf29ce484222325u; long off = 0; volatile d1 f = D1[k].f;
        for (int i = 0; i < N; i++) { double x = input_d(&s, i), y = f(x); fnv(&h, of_d(y)); off += of_d(y) != of_d(D1[k].cr(x)); }
        line(D1[k].name, h, off);
    }
    for (size_t k = 0; k < sizeof D2 / sizeof *D2; k++) {
        uint64_t s = 101 + k, h = 0xcbf29ce484222325u; long off = 0; volatile d2 f = D2[k].f;
        for (int i = 0; i < N; i++) { double x = input_d(&s, i), z = input_d(&s, i + 1), y = f(x, z); fnv(&h, of_d(y)); off += of_d(y) != of_d(D2[k].cr(x, z)); }
        line(D2[k].name, h, off);
    }
    for (size_t k = 0; k < sizeof F1 / sizeof *F1; k++) {
        uint64_t s = 201 + k, h = 0xcbf29ce484222325u; long off = 0; volatile f1 f = F1[k].f;
        for (int i = 0; i < N; i++) { float x = input_f(&s, i), y = f(x); fnv(&h, of_f(y)); off += of_f(y) != of_f(F1[k].cr(x)); }
        line(F1[k].name, h, off);
    }
    for (size_t k = 0; k < sizeof F2 / sizeof *F2; k++) {
        uint64_t s = 301 + k, h = 0xcbf29ce484222325u; long off = 0; volatile f2 f = F2[k].f;
        for (int i = 0; i < N; i++) { float x = input_f(&s, i), z = input_f(&s, i + 1), y = f(x, z); fnv(&h, of_f(y)); off += of_f(y) != of_f(F2[k].cr(x, z)); }
        line(F2[k].name, h, off);
    }
    /* Direct calls, not through pointers: what the compiler does with them under the contract (folding, SVML). */
    { uint64_t s = 401, h = 0xcbf29ce484222325u; long off = 0;
      for (int i = 0; i < N; i++) { double x = input_d(&s, i); double y = cos(x) * sin(x) + exp(x * 0.001) * log(fabs(x) + 1.0);
        fnv(&h, of_d(y)); off += of_d(y) != of_d(cr_cos(x) * cr_sin(x) + cr_exp(x * 0.001) * cr_log(fabs(x) + 1.0)); }
      fnv(&h, of_d(cos(0.5) + exp(1.25) + pow(3.0, 0.3)));                         /* folded unless -fno-builtin */
      off += of_d(cos(0.5) + exp(1.25) + pow(3.0, 0.3)) != of_d(cr_cos(0.5) + cr_exp(1.25) + cr_pow(3.0, 0.3));
      line("inline", h, off); }
    /* strtod over decimal strings built here (no printf in the inputs): 1 to 25 significant digits, exponents
     * -330..330, halfway-looking tails. A correctly rounding strtod gives one answer everywhere; glibc and the UCRT do
     * (200,000 strings, 2026-10-04). glibc also sets ERANGE on subnormal results and the UCRT does not. */
    { uint64_t s = 501, h = 0xcbf29ce484222325u; char b[64];
      for (int i = 0; i < N; i++) {
          uint64_t r = mix(&s); int n = 1 + (int)(r % 25), e = (int)((r >> 8) % 661) - 330, p = 0;
          if (r >> 63) b[p++] = '-';
          for (int d = 0; d < n; d++) { uint64_t q = mix(&s); b[p++] = (char)('0' + (d == 0 ? 1 + q % 9 : (i & 1) && d > 15 ? (d == 16 ? 5 : 0) : q % 10)); if (d == 0 && n > 1) b[p++] = '.'; }
          p += snprintf(b + p, sizeof b - (size_t)p, "e%d", e);
          double y = strtod(b, NULL); fnv(&h, of_d(y));   /* the value; ERANGE on a subnormal is the libc's own */
      }
      line("strtod", h, 0); }
    return wrong;
}
