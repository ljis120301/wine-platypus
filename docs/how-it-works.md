# How it works

Platypus 7 is a **Visual FoxPro 9** application (`plat.exe`) that bundles the VFP9 SP2
runtime, Crystal Reports XI runtime, Chilkat/MailBee ActiveX controls and a few
classic OCX controls. All of that runs fine under Wine out of the box. The only piece
that does not is the database layer.

## The database problem, and the fix

* Platypus talks to SQL Server through **ODBC** (VFP `SQLCONNECT()` -> `odbc32.dll`),
  using a *System DSN* called **`Platypus`**. The installer creates that DSN pointing at
  Windows' built-in "SQL Server" driver (`sqlsrv32.dll`) with `Server=(local)`; on
  Windows an admin then edits the DSN to point at the real server.
* Wine ships its own `odbc32.dll` that forwards to unixODBC on the host. Visual FoxPro
  cannot use it: VFP calls the ODBC 2.x function `SQLSetConnectOption()` *before*
  `SQLConnect()`, and Wine's driver manager (up to and including Wine 11.x) returns an
  error for any option set before the connection exists. VFP then gives up with
  *"Unable to retrieve specific error information. Driver is probably out of resources"*.
* The fix is to give the prefix the real Microsoft driver manager and the real
  "SQL Server" driver. Both are in Microsoft's freely redistributable **MDAC 2.8 SP1**
  package (`vendor/MDAC_TYP.EXE`). We do **not** run MDAC's installer (it hangs under
  Wine); we extract the 13 files we need with `cabextract`, drop them into the 32-bit
  system directory of the prefix, register the driver in the registry and mark
  `odbc32`/`odbccp32` as *native* in Wine's DLL overrides. The launcher additionally
  passes the same overrides through `WINEDLLOVERRIDES`, because Wine 11 was observed to
  ignore registry DLL overrides on the very first start of a freshly installed prefix
  (reproducible: first launch logs `get_load_order got hardcoded default`, every later
  launch `got standard key n,b`). The environment form is honoured every time.
* The DSN is then rewritten to point at your SQL Server (`Server`, `Database`), and the
  same first-run "ODBC Connection Editor" the Windows client shows lets each user store
  their SQL login. Verified: the driver reaches the server over TCP/1433 (TDS 7.1, login
  encryption negotiated by the server), and a wrong password yields the genuine
  `[Microsoft][ODBC SQL Server Driver][SQL Server]Login failed for user ...` message.

## Bundled ActiveX controls that need extra runtimes

The installer registers several OCX controls with `regsvr32`. Three of them cannot load
under a bare Wine prefix, so their registration silently fails and the app later
throws OLE errors when a screen that uses them opens:

| Control | Used for | Needs |
|---|---|---|
| `ChadoSpellText.ocx` | spell checking in notes/tickets | VB6 runtime `msvbvm60.dll` |
| `IEPostWrapper.ocx` | web posting (Customer "Qualification Step") | VB6 runtime `msvbvm60.dll` |
| `ctalarm.ocx` | calendar alarms | `mfc42.dll` |

`install_vb6_mfc_runtimes` (lib/common.sh) extracts those DLLs from Microsoft's VB6 SP6
and VC6 redistributables in `vendor/` and re-registers the three controls.

## Two more Wine gaps, and how they are closed

**ADODB.Stream (error logger).** Every Platypus error is written to a log through
`ADODB.Stream.WriteText(text, adWriteLine)` with charset UTF-8. Wine's own ADO supports
only `adWriteChar` and the "Unicode" charset, so the *logger itself* failed with
`OLE error code 0x80004001: Not implemented` (dialog shows *Method: log, Object:
sferrormgr*), hiding the real error behind it. Microsoft's ADO 2.8 from the MDAC package in `vendor/`
package is installed instead (`install_native_ado`), exactly what winetricks' `mdac28`
verb does.

**Two `oleaut32` COM defects behind the *Handle E-mails* screen.** The mscomctl ListView
that screen uses exercises two automation behaviours Wine 11 gets wrong:

1. *NULL for an object parameter.* Clearing the selection (`oListView.SelectedItem =
   .NULL.`) passes a `VT_NULL` variant for an object-typed parameter. Windows treats it as
   "no object"; Wine's `ITypeInfo::Invoke` runs `VariantChangeType` and fails with a type
   mismatch, so rows could not be selected.
2. *Default-property write-through on an indexed get-only property.* Repopulating the list
   after a delete runs `ListSubItems(n) = text`, which the Visual FoxPro runtime compiles
   to a `PROPERTYPUT` on the collection's get-only `Item` member. Windows fetches the
   sub-item object and writes the value into its default member; Wine returned
   `DISP_E_BADPARAMCOUNT` (`0x8002000e`), so *Delete Message* failed with an OLE error.

Both were root-caused with a synthetic reproduction (a hand-built typelib + object, no
database) and fixed in
`vendor/wine-patches/0001-oleaut32-object-arg-and-default-property-put.patch`.

*Delivery differs from the other native DLLs.* Wine 11 loads a builtin DLL from the copy
`wineboot` places in the prefix's `system32` (or `syswow64`), sourced from the Wine install
dir. A per-prefix `native` override is not used for this one: the rebuilt DLL keeps the
"Wine builtin DLL" marker and simply takes the stock builtin's place. The installer writes
it to **both** locations: the Wine install dir (so new prefixes and `wineboot -u` refreshes
pick it up; a `.wine-platypus.orig` backup is kept and restored on uninstall) and the
existing prefix's system directory (which is what an already-created prefix actually
loads). Built from Wine 11.0 sources, so it installs only when the detected Wine is 11.x;
see `docs/wine-patches.md` to rebuild for another version. The patch is additive, so other
Wine apps on the machine are unaffected.

## COM registration repairs and the self-check

Three more things the NSIS installer's own `regsvr32` pass gets wrong under Wine, all
found by instantiating every one of the ~900 COM classes the install registers
(`vendor/tools/comcheck.exe`, run headless, no database needed):

* Controls whose runtime was missing at install time never registered: the VB6 ones
  (ChadoSpellText, IEPostWrapper) and every MFC42-based DBI calendar control (ctAlarm,
  ctDate, ctDays, ctMonth) - fixed by installing the runtimes and re-registering them.
* `Platypus.COM.dll` registers most of its **version-independent** ProgIDs
  (`Platypus.COM.TCPSocket`, `.DNS`, `.curl`, `.json`, ...) with only a `CurVer` pointer to
  the versioned ProgID. Windows' `CLSIDFromProgID` follows `CurVer`; Wine's does not, so
  `CREATEOBJECT("Platypus.COM.TCPSocket")` raised *Class definition ... is not found* (this
  is what broke saving a MAC address / any User Manager event). `vendor/tools/fixprogids.exe`
  adds the missing `CLSID` value to every such ProgID (18 in this install). Re-running
  `regsvr32 Platypus.COM.dll` is deliberately avoided: it hangs under Wine.
* Two ADO helper DLLs and the Crystal viewer controls are registered by long path for good
  measure; the tool also rewrites any server path registered under an unresolvable 8.3 name.

At the end of every install (and with `./install.sh --verify` at any time) the installer
runs the self-check: it instantiates each class in `vendor/tools/comcheck-list.txt` - the
classes Platypus' own code creates plus the ActiveX controls it hosts - in a separate
process each, and prints a summary. `LICENSED` is the expected result for licensed
ActiveX controls (their factory loaded; only a form can supply the license key).
Anything else means a broken install; the report is saved next to the logs.

For the record, the full sweep also instantiated all 550 Crystal Reports XI classes: the
runtime the app uses (`CrystalRuntime.Application`, `CrystalRuntime.Report`, the viewer)
works; 91 helper/data classes (`ExportModeller.*FieldInfo`, `*EventProperties`, ...)
return `REGDB_E_KEYMISSING` because they are engine-internal and not directly creatable,
which is the same on Windows.

## WMI at login

Platypus's error handler reads `Win32_ComputerSystem` and `Win32_OperatingSystem` through
WMI (`GETOBJECT("winmgmts:")`) when it builds an error report.
Wine implements this through `wbemdisp`/`wbemprox`; Wine 11.0 still lacks a few
`SWbemProperty`/`SWbemPropertySet` methods (`Properties_` enumeration, `Name`, `CIMType`)
that were added to Wine in 2026. See the README's troubleshooting table for the status.


## The launcher

`bin/platypus` (Linux) and `Platypus Billing.app/Contents/MacOS/platypus` (macOS) are the
same generated script. It takes a single-instance lock, stops a stale Wine server left by a
previous session, self-heals the patched `oleaut32.dll` in the prefix if a Wine update
re-created it (only while Wine is 11.x), then
**`exec`s** Wine so the launcher and Wine are one process: on macOS that means a single
Dock tile with our name and icon (a spawned child would get its own tile next to the
launcher's). Because nothing survives the `exec`, a small detached watcher waits for that
process to end and then runs `wineserver -k`, so no helper process (dllhost.exe COM
surrogate, services.exe, explorer.exe) lingers after Platypus closes.


## The macOS app bundle

macOS identifies a GUI process by the bundle its executable lives in. A `.app` whose shell
script merely runs `/Applications/Wine Stable.app/.../wine` gets two Dock tiles - its own,
bouncing forever because that process never becomes a GUI app, and Wine's with the real
windows. `Platypus Billing.app` therefore contains symlinks to every Wine binary in
`Contents/MacOS/` plus `Contents/lib` and `Contents/share` mirroring Wine's layout, and the
launcher execs `Contents/MacOS/wine`: the running process belongs to our bundle, so there is
one tile with our name and icon. The installer verifies that loader path works (`wine
--version` through the bundle); if it cannot, it falls back to the real path and marks the
bundle `LSUIElement` so it never bounces.

## Layout on disk

| Linux | macOS |
|-------|-------|
| `~/.local/share/platypus/prefix` (Wine prefix) | `~/Library/Application Support/Platypus/prefix` |
| `~/.local/share/platypus/bin/platypus` (launcher) | `~/Applications/Platypus Billing.app` |
| `~/.local/share/platypus/logs/` | `~/Library/Application Support/Platypus/logs/` |
| `~/.local/share/applications/platypus-billing.desktop` | - |
| `~/.local/share/icons/hicolor/*/apps/platypus-billing.png` | - |
| `~/.local/share/platypus/config` (server, db, wine path/version/mode) | same, under Application Support |
| `~/.local/share/platypus/wine` (pinned portable Wine 11.0, Linux default) | - (Homebrew cask) |
| `~/.local/share/platypus/payload/oleaut32.dll` (copy the launcher restores after Wine updates) | same |
| `~/.local/share/platypus/run.lock` (single-instance lock while running) | same |

Inside the prefix the client lives at `C:\Program Files\Platypus` (32-bit prefix) or
`C:\Program Files (x86)\Platypus` (64-bit prefix). The launcher finds either.

## Prefix architecture

* Linux default: the pinned portable Wine is a WoW64 build, so the prefix is **win64** and
  32-bit code runs through Wine's WoW64 layer - no 32-bit host libraries needed. With
  `--system-wine` on a distro Wine that has 32-bit support, a pure **win32** prefix is made.
* macOS (and Wine builds without 32-bit libraries): Wine can only make **win64**
  prefixes and runs 32-bit code through its WoW64 layer. The installer detects this
  automatically. The ODBC files go to `syswow64` and the registry entries to the
  32-bit view, so the app sees exactly the same thing. Both variants were tested.

## What the installer does not do

* No `winetricks`, no Mono, no Gecko, no fonts. If a screen ever needs Wine's HTML
  engine (Gecko), Wine will offer to download it on the spot; say yes.
* No changes outside your home directory except installing Wine/cabextract with the
  system package manager (`apt`/`dnf`/`brew`).
