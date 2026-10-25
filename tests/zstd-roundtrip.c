/* Exercise the actual Windows codec DLL on deterministic, synthetic data. */
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef size_t (*CompressBound)(size_t);
typedef size_t (*Compress)(void *, size_t, const void *, size_t, int);
typedef size_t (*Decompress)(void *, size_t, const void *, size_t);
typedef unsigned (*IsError)(size_t);
typedef struct { unsigned offset, litLength, matchLength, rep; } Sequence;
typedef void *(*CreateCCtx)(void);
typedef size_t (*FreeCCtx)(void *);
typedef size_t (*CompressSequences)(void *, void *, size_t, const Sequence *, size_t, const void *, size_t);
static uint32_t seed = 0xC0FFEEu;
static uint32_t next(void) { seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; return seed; }

int main(int argc, char **argv) {
    HMODULE encoder, decoder;
    CompressBound bound; Compress compress; Decompress decompress; IsError is_error;
    CreateCCtx create; FreeCCtx release; CompressSequences sequences;
    unsigned char input[32768], actual[32832];
    unsigned char *packed;
    size_t capacity, n, c, out, j, difference;
    unsigned number, pattern;
    int level;
    if (argc != 3) { fprintf(stderr, "usage: zstd-roundtrip encoder.dll decoder.dll\n"); return 2; }
    encoder = LoadLibraryA(argv[1]); decoder = LoadLibraryA(argv[2]);
    if (!encoder || !decoder) { fprintf(stderr, "DLL load failed: %lu\n", GetLastError()); return 2; }
    bound = (CompressBound)GetProcAddress(encoder, "ZSTD_compressBound");
    compress = (Compress)GetProcAddress(encoder, "ZSTD_compress");
    decompress = (Decompress)GetProcAddress(decoder, "ZSTD_decompress");
    is_error = (IsError)GetProcAddress(decoder, "ZSTD_isError");
    create = (CreateCCtx)GetProcAddress(encoder, "ZSTD_createCCtx");
    release = (FreeCCtx)GetProcAddress(encoder, "ZSTD_freeCCtx");
    sequences = (CompressSequences)GetProcAddress(encoder, "ZSTD_compressSequences");
    if (!bound || !compress || !decompress || !is_error || !create || !release || !sequences) return 2;
    capacity = bound(sizeof(input)); packed = malloc(capacity);
    if (!packed) return 2;
    printf("encoder=%s\ndecoder=%s\n", argv[1], argv[2]);
    /* Overlapping short matches after several preceding matches. A lone short
       match or ordinary compressor round trips miss the ICX 2026.1 failure. */
    for (number = 0; number < 4096; number++) {
        Sequence seq[] = {{1,153,11,0},{16,2,7,0},{8,0,8,0},{2,0,23,0},
                          {44,6,6,0},{76,34,10,0},{12,2,10,0},{76,0,8,0},
                          {number % 32 + 1,0,number / 32 % 64 + 4,0},
                          {128,2886,0,0}};
        void *ctx = create();
        size_t pos = 0, k;
        n = 8140;
        for (j = 0; j < n; j++) input[j] = (unsigned char)next();
        seq[9].matchLength = (unsigned)(n - 280 - seq[8].matchLength - seq[9].litLength);
        for (k = 0; k < sizeof(seq)/sizeof(seq[0]); k++) {
            pos += seq[k].litLength;
            for (j = 0; j < seq[k].matchLength; j++) input[pos+j] = input[pos+j-seq[k].offset];
            pos += seq[k].matchLength;
        }
        c = sequences(ctx, packed, capacity, seq, sizeof(seq)/sizeof(seq[0]), input, n);
        release(ctx);
        memset(actual, 0xA5, sizeof(actual));
        out = is_error(c) ? c : decompress(actual, n, packed, c);
        for (difference = 0; difference < n && input[difference] == actual[difference]; difference++) {}
        if (is_error(out) || out != n || difference != n) {
            fprintf(stderr, "FAIL short-match case=%u offset=%u match=%u compressed=%zu returned=%zu first_difference=%zu expected=%02x actual=%02x\n",
                    number, seq[8].offset, seq[8].matchLength, c, out, difference,
                    difference < n ? input[difference] : 0, difference < n ? actual[difference] : 0);
            return 1;
        }
        for (j = n; j < sizeof(actual); j++) if (actual[j] != 0xA5) {
            fprintf(stderr, "FAIL short-match output overrun case=%u offset=%zu\n", number, j); return 1;
        }
    }
    for (number = 0; number < 12000; number++) {
        n = number < 2049 ? number : next() % sizeof(input);
        pattern = number % 8;
        for (j = 0; j < n; j++) {
            if (pattern == 0) input[j] = (unsigned char)next();
            else if (pattern == 1) input[j] = (unsigned char)(j % 17);
            else if (pattern == 2) input[j] = j % 97 == 0 ? (unsigned char)next() : 'A';
            else if (pattern == 3) input[j] = (unsigned char)(next() % 8);
            else if (pattern == 4) input[j] = j % 512 < 384 ? 0 : (unsigned char)next();
            else if (pattern == 5) input[j] = (unsigned char)((j / 4) % 256);
            else if (pattern == 6) input[j] = j < 512 || j % 16 < 4 ? 0 : (unsigned char)(j % 251);
            else input[j] = j < 256 ? (unsigned char)next() : input[j % 256];
        }
        level = number % 3 == 0 ? 1 : number % 3 == 1 ? 3 : 9;
        c = compress(packed, capacity, input, n, level);
        if (is_error(c)) { fprintf(stderr, "FAIL compression case=%u\n", number); return 1; }
        memset(actual, 0xA5, sizeof(actual));
        out = decompress(actual, n, packed, c);
        for (difference = 0; difference < n && input[difference] == actual[difference]; difference++) {}
        if (is_error(out) || out != n || difference != n) {
            fprintf(stderr, "FAIL case=%u pattern=%u length=%zu level=%d compressed=%zu returned=%zu first_difference=%zu expected=%02x actual=%02x\n",
                    number, pattern, n, level, c, out, difference,
                    difference < n ? input[difference] : 0, difference < n ? actual[difference] : 0);
            return 1;
        }
        for (j = n; j < sizeof(actual); j++) if (actual[j] != 0xA5) {
            fprintf(stderr, "FAIL output overrun case=%u offset=%zu\n", number, j); return 1;
        }
    }
    puts("PASS 16096 synthetic cases: overlapping short matches, levels 1/3/9, exact output and bounds");
    free(packed); FreeLibrary(encoder); FreeLibrary(decoder); return 0;
}
