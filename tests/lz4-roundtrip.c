/* Native installed-library regression. No PostgreSQL service or database needed. */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

typedef int (*Compress)(const char *, char *, int, int);
typedef int (*Decompress)(const char *, char *, int, int);
typedef int (*Partial)(const char *, char *, int, int, int);
static uint32_t seed=0xC0FFEEu;
static uint32_t next(void) { seed^=seed<<13; seed^=seed>>17; seed^=seed<<5; return seed; }
static int check(Compress compress, Decompress decompress, Partial partial,
                 const char *input, int length, int number) {
    char *packed=malloc(length*2+128), *actual=malloc(length+64);
    int n=compress(input,packed,length,length*2+128), out, i, target;
    if(n<=0) { printf("FAIL compression case=%d length=%d\n",number,length); return 1; }
    memset(actual,0xA5,length+64);
    out=decompress(packed,actual,n,length);
    for(i=0;i<length && actual[i]==input[i];i++) {}
    if(out!=length || i!=length) {
        printf("FAIL decompression case=%d length=%d compressed=%d returned=%d first_difference=%d expected=%02x actual=%02x\n",number,length,n,out,i,i<length?(unsigned char)input[i]:0,i<length?(unsigned char)actual[i]:0);
        free(packed); free(actual); return 1;
    }
    for(i=length;i<length+64;i++) if((unsigned char)actual[i]!=0xA5) { printf("FAIL output overrun\n"); return 1; }
    target=length/3;
    memset(actual,0xA5,length+64);
    out=partial(packed,actual,n,target,target);
    if(out!=target || memcmp(input,actual,target)) { printf("FAIL partial case=%d length=%d target=%d returned=%d\n",number,length,target,out); return 1; }
    for(i=target;i<length+64;i++) if((unsigned char)actual[i]!=0xA5) { printf("FAIL partial output overrun\n"); return 1; }
    free(packed); free(actual); return 0;
}
int main(int argc,char **argv) {
    HMODULE encoder, decoder; Compress compress; Decompress decompress; Partial partial;
    char *data=malloc(131072), *fixture; FILE *f; long size; int i,j,n,pattern;
    if(argc!=4) { fprintf(stderr,"usage: lz4-roundtrip compressor.dll decoder.dll expression.txt\n"); return 2; }
    encoder=LoadLibraryA(argv[1]); decoder=LoadLibraryA(argv[2]);
    if(!encoder||!decoder) { fprintf(stderr,"DLL load failed: %lu\n",GetLastError()); return 2; }
    compress=(Compress)GetProcAddress(encoder,"LZ4_compress_default");
    decompress=(Decompress)GetProcAddress(decoder,"LZ4_decompress_safe");
    partial=(Partial)GetProcAddress(decoder,"LZ4_decompress_safe_partial");
    if(!compress||!decompress||!partial) return 2;
    printf("compressor=%s\ndecoder=%s\n",argv[1],argv[2]);
    if(fopen_s(&f,argv[3],"rb") || !f) return 2;
    fseek(f,0,SEEK_END); size=ftell(f); rewind(f); fixture=malloc(size);
    if(fread(fixture,1,size,f)!=(size_t)size) return 2; fclose(f);
    if(check(compress,decompress,partial,fixture,(int)size,0)) return 1;
    for(i=1;i<=10000;i++) {
        n=i<2048?i:(int)(next()%131072); pattern=i%5;
        for(j=0;j<n;j++) {
            if(pattern==0) data[j]=(char)next();
            else if(pattern==1) data[j]=(char)(j%17);
            else if(pattern==2) data[j]=fixture[j%size];
            else if(pattern==3) data[j]=(j%97==0)?(char)next():'A';
            else data[j]=(char)(next()%8);
        }
        if(check(compress,decompress,partial,data,n,i)) return 1;
    }
    printf("PASS 10001 cases: exact full and partial output; output bounds intact\n");
    free(data); free(fixture); FreeLibrary(encoder); FreeLibrary(decoder); return 0;
}
