/* SPDX-License-Identifier: GPL-3.0-or-later */
/* comcheck: instantiate COM ProgIDs, each in its own child process, with a timeout.
 *   comcheck.exe list.txt [report.txt]    -> one line per ProgID: OK / LICENSED / NOTREG / FAIL / CRASH / TIMEOUT
 *   comcheck.exe --one ProgID             -> (internal) exit code encodes the result */
#define COBJMACROS
#include <windows.h>
#include <ole2.h>
#include <stdio.h>
#include <string.h>
enum { R_OK=0, R_LIC=10, R_NOTREG=11, R_FAIL=12 };
static void trim(char*s){char*h=strstr(s," #");if(h)*h=0;h=strstr(s,"\t#");if(h)*h=0;size_t n=strlen(s);while(n&&(s[n-1]=='\r'||s[n-1]=='\n'||s[n-1]==' '||s[n-1]=='\t'))s[--n]=0;}
static int one(const char*progid, char*detail, size_t dsz){
    wchar_t wp[512]; MultiByteToWideChar(CP_ACP,0,progid,-1,wp,512);
    CLSID clsid; HRESULT hr = (wp[0]==L'{') ? CLSIDFromString(wp,&clsid) : CLSIDFromProgID(wp,&clsid);
    if(FAILED(hr)){snprintf(detail,dsz,"%s=%08lx",wp[0]==L'{'?"CLSIDFromString":"CLSIDFromProgID",(unsigned long)hr);return R_NOTREG;}
    if(wp[0]==L'{'){ /* a bare CLSID: make sure it is actually registered */ wchar_t kk[128]; wsprintfW(kk,L"CLSID\\%s",wp); HKEY t; if(RegOpenKeyExW(HKEY_CLASSES_ROOT,kk,0,KEY_READ,&t)!=0){snprintf(detail,dsz,"CLSID key not registered");return R_NOTREG;} RegCloseKey(t);}
    wchar_t cs[64]; StringFromGUID2(&clsid,cs,64);
    wchar_t key[256],path[MAX_PATH]=L""; DWORD sz=sizeof path; HKEY k;
    wsprintfW(key,L"CLSID\\%s\\InprocServer32",cs);
    if(RegOpenKeyExW(HKEY_CLASSES_ROOT,key,0,KEY_READ,&k)==0){RegQueryValueExW(k,NULL,NULL,NULL,(BYTE*)path,&sz);RegCloseKey(k);}
    IUnknown*u=NULL; hr=CoCreateInstance(&clsid,NULL,CLSCTX_INPROC_SERVER|CLSCTX_LOCAL_SERVER,&IID_IUnknown,(void**)&u);
    if(SUCCEEDED(hr)){IUnknown_Release(u);snprintf(detail,dsz,"%ls",path[0]?path:L"");return R_OK;}
    if(hr==0x80040112){snprintf(detail,dsz,"%ls (licensed control; factory reached)",path[0]?path:L"");return R_LIC;}
    DWORD attr=path[0]?GetFileAttributesW(path):INVALID_FILE_ATTRIBUTES;
    snprintf(detail,dsz,"hr=%08lx server=%ls file=%s",(unsigned long)hr,path[0]?path:L"(none)",path[0]?(attr==INVALID_FILE_ATTRIBUTES?"MISSING":"present"):"n/a");
    return R_FAIL;
}
int main(int argc,char**argv){
    if(argc>=3&&!strcmp(argv[1],"--one")){
        CoInitialize(NULL); char d[600]; int r=one(argv[2],d,sizeof d); FILE*f=fopen("comcheck.detail","w"); if(f){fputs(d,f);fclose(f);} CoUninitialize(); return r;
    }
    if(argc<2){printf("usage: comcheck list.txt [report.txt]\n");return 1;}
    FILE*in=fopen(argv[1],"r"); if(!in){printf("cannot open %s\n",argv[1]);return 1;}
    FILE*out=fopen(argc>2?argv[2]:"comcheck.txt","w"); if(!out)out=stdout; setvbuf(out,0,_IONBF,0);
    char self[MAX_PATH]; GetModuleFileNameA(NULL,self,MAX_PATH);
    int n_ok=0,n_lic=0,n_notreg=0,n_fail=0,n_crash=0,n_to=0; char line[512];
    while(fgets(line,sizeof line,in)){
        trim(line); if(!line[0]||line[0]=='#')continue;
        char cmd[1200]; snprintf(cmd,sizeof cmd,"\"%s\" --one \"%s\"",self,line);
        STARTUPINFOA si={sizeof si}; PROCESS_INFORMATION pi; DeleteFileA("comcheck.detail");
        if(!CreateProcessA(NULL,cmd,NULL,NULL,FALSE,CREATE_NO_WINDOW,NULL,NULL,&si,&pi)){fprintf(out,"CRASH    %-48s (spawn failed)\n",line);n_crash++;continue;}
        DWORD w=WaitForSingleObject(pi.hProcess,25000), code=0;
        if(w==WAIT_TIMEOUT){TerminateProcess(pi.hProcess,99);fprintf(out,"TIMEOUT  %-48s\n",line);n_to++;}
        else{ GetExitCodeProcess(pi.hProcess,&code); char d[600]="";FILE*f=fopen("comcheck.detail","r");if(f){if(!fgets(d,sizeof d,f))d[0]=0;fclose(f);}
            switch(code){case R_OK:fprintf(out,"OK       %-48s %s\n",line,d);n_ok++;break;
                         case R_LIC:fprintf(out,"LICENSED %-48s %s\n",line,d);n_lic++;break;
                         case R_NOTREG:fprintf(out,"NOTREG   %-48s %s\n",line,d);n_notreg++;break;
                         case R_FAIL:fprintf(out,"FAIL     %-48s %s\n",line,d);n_fail++;break;
                         default:fprintf(out,"CRASH    %-48s exit=0x%08lx\n",line,(unsigned long)code);n_crash++;} }
        CloseHandle(pi.hProcess);CloseHandle(pi.hThread);
    }
    fprintf(out,"SUMMARY  ok=%d licensed=%d notreg=%d fail=%d crash=%d timeout=%d\n",n_ok,n_lic,n_notreg,n_fail,n_crash,n_to);
    fclose(out); return (n_fail||n_notreg||n_crash||n_to)?2:0;
}
