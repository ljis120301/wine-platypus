/* SPDX-License-Identifier: GPL-3.0-or-later */
/* fixprogids: for every HKCR ProgID that has CurVer but no CLSID value, resolve
 * CurVer -> versioned ProgID -> CLSID and write it under the version-independent ProgID.
 * Windows' CLSIDFromProgID follows CurVer; Wine's does not, so apps using the
 * version-independent ProgID (e.g. CREATEOBJECT("Platypus.COM.TCPSocket")) fail. */
#include <windows.h>
#include <stdio.h>

/* ---- 8.3 short-path repair: Windows installers may register servers with hashed short
 * names (C:\PROG~FBU\...) that Wine cannot resolve. Find the file by basename under
 * Program Files and rewrite the value with the long path. ---- */
static int find_file(const wchar_t*dir,const wchar_t*base,wchar_t*out,int depth){
    if(depth>6)return 0; wchar_t pat[MAX_PATH]; wsprintfW(pat,L"%s\\*",dir); WIN32_FIND_DATAW fd; HANDLE h=FindFirstFileW(pat,&fd); if(h==INVALID_HANDLE_VALUE)return 0;
    int found=0;
    do{ if(!wcscmp(fd.cFileName,L".")||!wcscmp(fd.cFileName,L".."))continue;
        wchar_t full[MAX_PATH]; wsprintfW(full,L"%s\\%s",dir,fd.cFileName);
        if(fd.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY){ if(find_file(full,base,out,depth+1)){found=1;break;} }
        else if(!_wcsicmp(fd.cFileName,base)){ lstrcpyW(out,full); found=1; break; }
    }while(FindNextFileW(h,&fd));
    FindClose(h); return found;
}
static unsigned long fix_short_paths(void){
    unsigned long fixed=0; HKEY clsroot; if(RegOpenKeyExW(HKEY_CLASSES_ROOT,L"CLSID",0,KEY_READ,&clsroot)!=0)return 0;
    const wchar_t*subs[]={L"InprocServer32",L"LocalServer32"}; wchar_t cid[128]; DWORD i=0;
    for(;;){ DWORD n=128; if(RegEnumKeyExW(clsroot,i++,cid,&n,NULL,NULL,NULL,NULL)!=0)break;
        for(int s=0;s<2;s++){ wchar_t kp[256]; wsprintfW(kp,L"%s\\%s",cid,subs[s]); HKEY k; if(RegOpenKeyExW(clsroot,kp,0,KEY_READ|KEY_WRITE,&k)!=0)continue;
            wchar_t val[MAX_PATH]; DWORD sz=sizeof val,type=0;
            if(RegQueryValueExW(k,NULL,NULL,&type,(BYTE*)val,&sz)==0&&wcschr(val,L'~')&&GetFileAttributesW(val)==INVALID_FILE_ATTRIBUTES){
                wchar_t*base=wcsrchr(val,L'\\'); base=base?base+1:val; wchar_t*comma=wcschr(base,L','); if(comma)*comma=0;
                wchar_t found[MAX_PATH]; const wchar_t*roots[]={L"C:\\Program Files",L"C:\\Program Files (x86)"};
                for(int r=0;r<2;r++){ if(find_file(roots[r],base,found,0)){ RegSetValueExW(k,NULL,0,REG_SZ,(const BYTE*)found,(lstrlenW(found)+1)*sizeof(wchar_t)); printf("  %ls\\%ls: %ls -> %ls\n",cid,subs[s],val,found); fixed++; break; } }
            }
            RegCloseKey(k);
        }
    }
    RegCloseKey(clsroot); return fixed;
}

int main(void){
    HKEY root; if(RegOpenKeyExW(HKEY_CLASSES_ROOT,NULL,0,KEY_READ,&root)!=0)return 1;
    DWORD i=0, fixed=0, seen=0; wchar_t name[256];
    for(;;){
        DWORD n=256; if(RegEnumKeyExW(root,i++,name,&n,NULL,NULL,NULL,NULL)!=0)break;
        if(!wcschr(name,L'.')||name[0]==L'.'||name[0]==L'{')continue;   /* ProgIDs contain a dot; skip extensions/CLSIDs */
        HKEY k; if(RegOpenKeyExW(root,name,0,KEY_READ|KEY_WRITE,&k)!=0)continue;
        HKEY t;
        if(RegOpenKeyExW(k,L"CLSID",0,KEY_READ,&t)==0){RegCloseKey(t);RegCloseKey(k);continue;}   /* already has CLSID */
        wchar_t cur[256]; DWORD sz=sizeof cur;
        if(RegOpenKeyExW(k,L"CurVer",0,KEY_READ,&t)!=0){RegCloseKey(k);continue;}
        LONG r=RegQueryValueExW(t,NULL,NULL,NULL,(BYTE*)cur,&sz); RegCloseKey(t);
        if(r!=0||!cur[0]){RegCloseKey(k);continue;}
        seen++;
        wchar_t path[512]; wsprintfW(path,L"%s\\CLSID",cur); wchar_t clsid[128]; sz=sizeof clsid;
        HKEY c; if(RegOpenKeyExW(root,path,0,KEY_READ,&c)!=0||RegQueryValueExW(c,NULL,NULL,NULL,(BYTE*)clsid,&sz)!=0||!clsid[0]){ if(c)RegCloseKey(c); RegCloseKey(k); printf("  %ls: CurVer=%ls has no CLSID, skipped\n",name,cur); continue; }
        RegCloseKey(c);
        HKEY nk; if(RegCreateKeyExW(k,L"CLSID",0,NULL,0,KEY_WRITE,NULL,&nk,NULL)==0){
            RegSetValueExW(nk,NULL,0,REG_SZ,(const BYTE*)clsid,(lstrlenW(clsid)+1)*sizeof(wchar_t)); RegCloseKey(nk); fixed++;
            printf("  %ls -> %ls\n",name,clsid);
        }
        RegCloseKey(k);
    }
    RegCloseKey(root);
    printf("fixprogids: %lu server paths using unresolvable 8.3 names rewritten\n", fix_short_paths());
    printf("fixprogids: %lu version-independent ProgIDs lacked CLSID, %lu fixed\n",(unsigned long)seen,(unsigned long)fixed);
    return 0;
}
