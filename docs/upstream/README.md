# Wine bugs found while porting Platypus - candidates for upstream

Everything below was reproduced with small synthetic test programs (`tools/src/`), not with
the application, so each is a self-contained Wine report. Fixing them upstream would let the
installer drop its patched `oleaut32.dll` and (partly) the native MSXML.

1. **oleaut32: `ITypeInfo::Invoke` rejects `VT_NULL`/`VT_EMPTY` for an object parameter.**
   Native treats them as a NULL interface pointer (e.g. `oListView.SelectedItem = .NULL.`
   from Visual FoxPro). Wine returns `DISP_E_TYPEMISMATCH`.
   Patch: first hunk of `0001-oleaut32-object-arg-and-default-property-put.patch`.
2. **oleaut32: no default-property write-through for an indexed get-only property.**
   `obj.Item(1) = value` where `Item` is `[propget]` only and returns an object: native
   calls the getter and does `PROPERTYPUT` of `DISPID_VALUE` on the returned object; Wine
   returns `DISP_E_BADPARAMCOUNT` (`0x8002000e`). Second hunk of the same patch.
3. **combase: `CLSIDFromProgID` does not follow `CurVer`.** A version-independent ProgID
   that only has `CurVer = <ProgID>.1` (as ATL's default registrar script emits) resolves on
   Windows; Wine returns `CO_E_CLASSSTRING`. Worked around by `tools/src/fixprogids.c`.
4. **msxml3: `IXMLDOMNodeList.item()` is not reachable through `IDispatch`**
   (`DISP_E_MEMBERNOTFOUND` from `GetIDsOfNames`/`Invoke`), while `.length` is.
   Repro: `tools/src/xmltest.c` (passes with Microsoft's msxml3).
5. **oleaut32 registry `DllOverrides` are ignored on the very first process in a freshly
   created prefix** (loader logs `got hardcoded default`); the environment form is honoured.
   Observed, not yet minimised.

How to submit: Wine takes merge requests on https://gitlab.winehq.org/wine/wine (see
https://wiki.winehq.org/Submitting_Patches). Each item above should become its own MR
with a test in `dlls/<dll>/tests/`. The patch here is against `wine-11.0`.
