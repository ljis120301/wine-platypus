/* Exercise MSXML the way Platypus' framework does (late-bound IDispatch):
 * DOMDocument: loadXML, documentElement, createElement, appendChild, createTextNode,
 * selectNodes(...).length/item, selectSingleNode, .text, .xml ; plus XMLHTTP creation. */
#define COBJMACROS
#include <windows.h>
#include <ole2.h>
#include <oleauto.h>
#include <stdio.h>
static FILE *out;
static IDispatch *create(const wchar_t *progid){ CLSID c; IDispatch *d=NULL; if(FAILED(CLSIDFromProgID(progid,&c))){fprintf(out,"  %ls: not registered\n",progid);return NULL;} HRESULT hr=CoCreateInstance(&c,NULL,CLSCTX_INPROC_SERVER,&IID_IDispatch,(void**)&d); if(FAILED(hr))fprintf(out,"  %ls: create failed %08lx\n",progid,(unsigned long)hr); return d; }
static HRESULT inv(IDispatch *d,const wchar_t *name,WORD flags,VARIANT *args,int n,VARIANT *res){ DISPID id,putid=DISPID_PROPERTYPUT; DISPPARAMS dp={args,NULL,n,0}; EXCEPINFO ei={0}; UINT ae=0; HRESULT hr=IDispatch_GetIDsOfNames(d,&IID_NULL,(LPOLESTR*)&name,1,0,&id); if(FAILED(hr)){fprintf(out,"  GetIDsOfNames(%ls)=%08lx\n",name,(unsigned long)hr);return hr;} if(flags&DISPATCH_PROPERTYPUT){dp.rgdispidNamedArgs=&putid;dp.cNamedArgs=1;} hr=IDispatch_Invoke(d,id,&IID_NULL,0,flags,&dp,res,&ei,&ae); if(FAILED(hr))fprintf(out,"  %ls -> %08lx %ls\n",name,(unsigned long)hr,ei.bstrDescription?ei.bstrDescription:L""); return hr; }
static IDispatch *getd(IDispatch *d,const wchar_t *p){ VARIANT r; VariantInit(&r); if(FAILED(inv(d,p,DISPATCH_PROPERTYGET,NULL,0,&r))||V_VT(&r)!=VT_DISPATCH||!V_DISPATCH(&r)) return NULL; return V_DISPATCH(&r); }
int main(void){
    out=fopen("xmltest.out","w"); if(!out)out=stdout; setvbuf(out,0,_IONBF,0); CoInitialize(NULL);
    /* which msxml3 is loaded? */
    HMODULE h=LoadLibraryW(L"msxml3.dll"); wchar_t path[MAX_PATH]=L"?"; if(h)GetModuleFileNameW(h,path,MAX_PATH);
    fprintf(out,"msxml3.dll: %ls\n",path);
    IDispatch *doc=create(L"MSXML2.DOMDocument"); if(!doc){fprintf(out,"FAIL no DOMDocument\n");return 2;}
    VARIANT a[1],r; VariantInit(&a[0]); VariantInit(&r);
    V_VT(&a[0])=VT_BOOL; V_BOOL(&a[0])=VARIANT_FALSE; inv(doc,L"async",DISPATCH_PROPERTYPUT,a,1,NULL);
    V_VT(&a[0])=VT_BSTR; V_BSTR(&a[0])=SysAllocString(L"<response><status code=\"0\">ok</status><row><id>7808</id><mac>E4:38:83:B4:24:42</mac></row><row><id>7809</id><mac>AA:BB</mac></row></response>");
    if(FAILED(inv(doc,L"loadXML",DISPATCH_METHOD,a,1,&r))||V_VT(&r)!=VT_BOOL||V_BOOL(&r)!=VARIANT_TRUE){fprintf(out,"FAIL loadXML\n");return 2;}
    IDispatch *root=getd(doc,L"documentElement"); if(!root){fprintf(out,"FAIL documentElement\n");return 2;}
    VariantInit(&r); inv(root,L"nodeName",DISPATCH_PROPERTYGET,NULL,0,&r); fprintf(out,"root: %ls\n",V_VT(&r)==VT_BSTR?V_BSTR(&r):L"?");
    V_VT(&a[0])=VT_BSTR; V_BSTR(&a[0])=SysAllocString(L"row"); VariantInit(&r);
    if(FAILED(inv(root,L"selectNodes",DISPATCH_METHOD,a,1,&r))||V_VT(&r)!=VT_DISPATCH){fprintf(out,"FAIL selectNodes\n");return 2;}
    IDispatch *rows=V_DISPATCH(&r); VariantInit(&r); inv(rows,L"length",DISPATCH_PROPERTYGET,NULL,0,&r); long n=V_VT(&r)==VT_I4?V_I4(&r):-1; fprintf(out,"rows: %ld\n",n);
    for(long i=0;i<n;i++){ V_VT(&a[0])=VT_I4; V_I4(&a[0])=i; VariantInit(&r); if(FAILED(inv(rows,L"item",DISPATCH_METHOD,a,1,&r)))continue; IDispatch *row=V_DISPATCH(&r);
        V_VT(&a[0])=VT_BSTR; V_BSTR(&a[0])=SysAllocString(L"mac"); VariantInit(&r); inv(row,L"selectSingleNode",DISPATCH_METHOD,a,1,&r); IDispatch *mac=V_VT(&r)==VT_DISPATCH?V_DISPATCH(&r):NULL;
        VariantInit(&r); if(mac) inv(mac,L"text",DISPATCH_PROPERTYGET,NULL,0,&r); fprintf(out,"  row %ld mac=%ls\n",i,(mac&&V_VT(&r)==VT_BSTR)?V_BSTR(&r):L"?"); }
    /* build: createElement + createTextNode + appendChild + .xml */
    V_VT(&a[0])=VT_BSTR; V_BSTR(&a[0])=SysAllocString(L"note"); VariantInit(&r); inv(doc,L"createElement",DISPATCH_METHOD,a,1,&r); IDispatch *el=V_VT(&r)==VT_DISPATCH?V_DISPATCH(&r):NULL;
    V_VT(&a[0])=VT_BSTR; V_BSTR(&a[0])=SysAllocString(L"hello"); VariantInit(&r); inv(doc,L"createTextNode",DISPATCH_METHOD,a,1,&r); IDispatch *tx=V_VT(&r)==VT_DISPATCH?V_DISPATCH(&r):NULL;
    if(el&&tx){ V_VT(&a[0])=VT_DISPATCH; V_DISPATCH(&a[0])=tx; VariantInit(&r); inv(el,L"appendChild",DISPATCH_METHOD,a,1,&r); V_VT(&a[0])=VT_DISPATCH; V_DISPATCH(&a[0])=el; VariantInit(&r); inv(root,L"appendChild",DISPATCH_METHOD,a,1,&r); }
    VariantInit(&r); inv(doc,L"xml",DISPATCH_PROPERTYGET,NULL,0,&r); fprintf(out,"xml: %ls\n",V_VT(&r)==VT_BSTR?V_BSTR(&r):L"?");
    IDispatch *x=create(L"Msxml2.XMLHTTP"); fprintf(out,"XMLHTTP: %s\n",x?"ok":"FAIL"); x=create(L"Msxml2.ServerXMLHTTP"); fprintf(out,"ServerXMLHTTP: %s\n",x?"ok":"FAIL");
    fprintf(out,"RESULT OK\n"); return 0;
}
