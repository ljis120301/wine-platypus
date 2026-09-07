/* SPDX-License-Identifier: GPL-3.0-or-later */
/* ico2png: write the largest PNG-encoded image inside a .ico to a .png file
 * (modern icons store their 256x256 image as PNG). usage: ico2png in.ico out.png */
#include <windows.h>
#include <stdio.h>
#pragma pack(push,1)
typedef struct { WORD reserved, type, count; } ICONDIR;
typedef struct { BYTE w, h, colors, reserved; WORD planes, bpp; DWORD size, offset; } ICONDIRENTRY;
#pragma pack(pop)
int main(int argc, char **argv){
    if(argc<3){fprintf(stderr,"usage: ico2png in.ico out.png\n");return 2;}
    FILE *f=fopen(argv[1],"rb"); if(!f){fprintf(stderr,"cannot open %s\n",argv[1]);return 1;}
    fseek(f,0,SEEK_END); long n=ftell(f); fseek(f,0,SEEK_SET); BYTE *buf=malloc(n); if(fread(buf,1,n,f)!=(size_t)n){fclose(f);return 1;} fclose(f);
    ICONDIR *d=(ICONDIR*)buf; if(n<6||d->type!=1||d->count==0){fprintf(stderr,"not an ico\n");return 1;}
    ICONDIRENTRY *e=(ICONDIRENTRY*)(buf+6); int best=-1; DWORD bestpix=0;
    for(int i=0;i<d->count;i++){ if(e[i].offset+8>n) continue; if(memcmp(buf+e[i].offset,"\x89PNG",4)) continue;
        DWORD w=e[i].w?e[i].w:256, h=e[i].h?e[i].h:256; if(w*h>bestpix){bestpix=w*h;best=i;} }
    if(best<0){fprintf(stderr,"no PNG entry in ico\n");return 3;}
    FILE *o=fopen(argv[2],"wb"); if(!o){fprintf(stderr,"cannot write %s\n",argv[2]);return 1;}
    fwrite(buf+e[best].offset,1,e[best].size,o); fclose(o); printf("wrote %lux%lu png\n",(unsigned long)(e[best].w?e[best].w:256),(unsigned long)(e[best].h?e[best].h:256)); return 0;
}
