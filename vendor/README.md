# vendor/

Binary payloads the installer needs. Nothing proprietary is committed here.

| File | What | Where it comes from |
|---|---|---|
| `Platypus7.Client.exe` | Tucows Platypus Billing System (Client) installer | **You supply it** (your licensed copy from Tucows). Not in the repo; `.gitignore`d. |
| `MDAC_TYP.EXE` | MDAC 2.8 SP1: ODBC driver manager, "SQL Server" ODBC driver, ADO | downloaded on first install (sha256 verified) |
| `VC6RedistSetup_deu.exe` | Visual C++ 6.0 runtime (only `mfc42.dll`/`mfc42u.dll` are used) | downloaded on first install |
| `VB6.0-KB290887-X86.exe` | Visual Basic 6.0 SP6 runtime (only `msvbvm60.dll` is used) | downloaded on first install |
| `msvbvm60.dll`, `mfc42.dll`, `mfc42u.dll` *(optional)* | **newer** VB6/MFC runtimes, preferred over the SP6/VC6 copies above | **You supply them** from a Windows `SysWOW64`. Not in the repo; `.gitignore`d. See below. |
| `msxml3.msi`, `msxml.msi`, `msxml6-KB2957482-enu-amd64.exe` | MSXML 3.0 SP7 / 4.0 SP3 / 6.0 SP2 | downloaded on first install |
| `wine-patches/oleaut32-wine11.0-i386-builtin.dll` + `.patch` | Wine 11.0 `oleaut32.dll` rebuilt with two COM fixes | built by us, see `docs/wine-patches.md` |
| `tools/comcheck.exe`, `tools/fixprogids.exe`, `tools/ico2png.exe`, `tools/comcheck-list.txt` | our helpers (sources in `tools/src/`) | built by us |

Offline installs: put the downloaded files in this folder beforehand; the installer only
downloads what is missing and always verifies checksums (`SHA256SUMS` covers the committed
files; the download URLs and sums are in `lib/common.sh`).

## Where the Microsoft packages come from

`install.sh` / `install-macos.sh` download these automatically and verify the SHA‑256. To
install offline, download them yourself, check the sums, and drop them into `vendor/`.
They are the same files and checksums the `winetricks` verbs `mdac28`, `mfc42`/`vcrun6`,
`vbrun60sp6`(*), `msxml3`, `msxml4` and `msxml6` use. Microsoft has retired three of the
direct links; those come from the Internet Archive (`id_` = original bytes, no wrapper).
The installer verifies each download and falls back to other snapshots when archive.org
serves a truncated file, which it does now and then; if every source fails, wait and re-run.

| File | SHA‑256 | URL |
|---|---|---|
| `MDAC_TYP.EXE` | `157ebae46932cb9047b58aa849ac1885e8cbd2f218810cb83e57613b49c679d6` | https://web.archive.org/web/20070127061938id_/https://download.microsoft.com/download/4/a/a/4aafff19-9d21-4d35-ae81-02c48dcbbbff/MDAC_TYP.EXE |
| `VC6RedistSetup_deu.exe` | `c2eb91d9c4448d50e46a32fecbcc3b418706d002beab9b5f4981de552098cee7` | https://download.microsoft.com/download/vc60pro/Update/2/W9XNT4/EN-US/VC6RedistSetup_deu.exe |
| `VB6.0-KB290887-X86.exe` | `467b5a10c369865f2021d379fc0933cb382146b702bbca4bcb703fc86f4322bb` | https://web.archive.org/web/20210125001711id_/http://download.microsoft.com/download/5/a/d/5ad868a0-8ecd-4bb0-a882-fe53eb7ef348/VB6.0-KB290887-X86.exe |
| `msxml3.msi` | `f9c678f8217e9d4f9647e8a1f6d89a7c26a57b9e9e00d39f7487493dd7b4e36c` | https://media.codeweavers.com/pub/other/msxml3.msi |
| `msxml.msi` | `47c2ae679c37815da9267c81fc3777de900ad2551c11c19c2840938b346d70bb` | https://web.archive.org/web/20210506101448id_/http://download.microsoft.com/download/A/2/D/A2D8587D-0027-4217-9DAD-38AFDB0A177E/msxml.msi |
| `msxml6-KB2957482-enu-amd64.exe` | `260cd870851ffc3c6d10b71691f134e20d8d03ac26073bb36951eacb7aa85897` | https://download.microsoft.com/download/2/7/7/277681BE-4048-4A58-ABBA-259C465B1699/msxml6-KB2957482-enu-amd64.exe |

(*) winetricks' `vbrun60sp6` verb points at the same KB290887 package.

The downloaded packages, and your Platypus installer, are ignored by git (`.gitignore`),
so they never end up in a fork or pull request by accident.

## Optional: newer VB6 / MFC runtimes

The redistributables above are the newest Microsoft ever shipped standalone, and the VB6
one has a defect that matters here: `msvbvm60.dll` **6.00.9782** dereferences a NULL object
pointer when Platypus opens the e-mail editor, killing the app with `C0000005` inside
msvbvm60 (the VFP traceback only says `platmain`, so it looks like it comes from nowhere).
Windows carries a newer serviced build, **6.00.9848**, which does not. `mfc42.dll` /
`mfc42u.dll` differ the same way - **6.00.8665** from the VC6 redist versus **6.06.8063**
in Windows - and back the `ct*` calendar controls.

Those newer builds are serviced through Windows Update, not published as a download (the
VB6 SP6 Cumulative Update, KB2708437, only refreshes the VB6 *controls*), so they can be
neither fetched nor redistributed by this project. If you have a Windows machine you are
licensed to use, copy these out of its `C:\Windows\SysWOW64` into `vendor/`:

```
vendor/msvbvm60.dll     6.00.9848
vendor/mfc42.dll        6.06.8063.0
vendor/mfc42u.dll       6.06.8063.0
```

The installer prefers them automatically and says so; without them it uses the SP6/VC6
copies and prints a warning that opening an e-mail may crash.
