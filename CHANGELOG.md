# Changelog

## v2.0.2 - 2026-09-10

Bug fix: the OLE DB cursor engine was never installed, which killed the app outright on
any screen that builds a client-side recordset (the customer ticket list / Rates).

ADO keeps its client-side cursor in a separate DLL, `msadce.dll`, created as CLSID
`{3FF292B6-B204-11CF-8D23-00AA005FFE58}`. We installed ADO but not that, so *opening* a
disconnected recordset - what the app's DBF-to-Recordset conversion (`dbf2rs`) does -
failed. The failure is not graceful: ADO's error path hands `SetErrorInfo` an
uninitialised `IErrorInfo`, Wine's combase dereferences it, and the process dies with
`C0000005`. Because the crash lands in the *error handler*, the VFP traceback blames
`logger.log` / `sferrormgr` and hides the real cause.

- `msadce.dll` and `msadcer.dll` are now installed and registered alongside ADO. They
  come from the MDAC package already vendored/downloaded, so nothing new is shipped.
- The self-check now instantiates the cursor engine's CLSID directly. It previously
  reported `fail=0` on a broken install because `ADODB.Recordset` creates fine without
  the cursor engine - only *opening* a client-side recordset needs it.
- Upgrading an existing install works: the ADO step no longer short-circuits just
  because `msado15.dll` is already present.

Still outstanding: Wine's `SetErrorInfo` dereferences whatever pointer it is handed, so a
*different* missing/failing COM class inside ADO could still turn a catchable error into a
crash. Installing the cursor engine removes the known trigger, not that sharp edge.

## v2.0.1 - 2026-09-09

Bug fix: the patched `oleaut32` was being installed somewhere Wine never reads.

`oleaut32` is a `\KnownDlls` section, which the loader builds from the Wine installation
tree (`<wine>/lib*/wine/i386-windows/`) - not from the copy `wineboot` leaves in the
prefix. v1.0.0 and v2.0.0 wrote the patched DLL only into the prefix *and actively
restored the stock one* in the Wine tree, so the two COM fixes were inert: the
"Handle E-mails" screen could still raise `OLE error 0x8002000e` and the log showed the
stock `failed to convert param 0 to VT_DISPATCH from {VT_NULL}`. This went unnoticed
because the Wine tree on the development machine was already patched by hand from an
earlier approach; a fresh `uninstall.sh` + `install.sh` (which re-downloads a pristine
Wine) exposed it.

- The installer now patches **both** the Wine tree and the prefix copy, keeps a
  `.wine-platypus.orig` backup, and records it in the config so `uninstall.sh` puts the
  original back. It no longer reverts the Wine tree.
- The launcher's self-heal restores the patched DLL in both places after a Wine update.
- If the Wine tree cannot be written (a shared system Wine without permission), the
  installer now says so loudly instead of silently leaving the fix inactive.

## v2.0.0 - 2026-09-09

Same install behavior and flags as v1.0.0 - this release is about the installer holding
your hand better, not about changing what gets installed.

- **Friendlier UI**: a title banner, colored step headers, and a config recap ("Ready to
  install") before the heavy lifting starts.
- **Crashes nicely**: a real error trap now reports which command failed, where, and the
  tail of the install log, and reassures you that every step is safe to re-run - nothing
  is left half-installed. Ctrl-C during a prompt or a long step now exits cleanly instead
  of an abrupt abort. Added a disk-space preflight and specific messages for the two most
  common real-world failures (the Wine download and its extraction).
- **A light interactive menu** for choosing the Wine source (pinned portable vs. this
  system's package) and the look (Light vs. Classic), shown only on a real terminal and
  only when you haven't already answered with a flag - `--yes` and scripted installs are
  unaffected.
- **Broader distro support**: many more Debian/Ubuntu, Fedora/RHEL and Arch derivatives
  are now recognized directly, openSUSE/SLES is now installed via `zypper`, and any other
  distro gets a tailored "here's the exact command to run" hint (detecting whichever
  package manager is actually present) instead of a flat "unsupported distro" error.

## v1.0.0 - 2026-09-06

First release: Tucows Platypus Billing System client 7.0 (build 2292) running under Wine
11.0 on Linux and macOS, installed by one script per platform, with a real application-menu
entry / .app bundle and an end-of-install self-check.

What the installer puts into a dedicated Wine prefix (identical on both platforms):

- Platypus client (silent NSIS install)
- Microsoft ODBC driver manager + "SQL Server" ODBC driver (MDAC 2.8 SP1) and the `Platypus`
  System DSN pointing at your SQL Server - Wine's own ODBC cannot be used by FoxPro
- Microsoft ADO 2.8 (the app's error logger uses `ADODB.Stream`)
- Microsoft MSXML 3.0 SP7 / 4.0 SP3 / 6.0 SP2 (User Manager replies, FoxPro XML functions)
- VB6 runtime and MFC42 for the bundled ActiveX controls, which are then (re-)registered
- A rebuilt Wine 11.0 `oleaut32.dll` with two COM fixes (NULL object argument; indexed
  default-property write-through) that the e-mail list needs
- Registry repairs (`fixprogids`): CLSIDs for CurVer-only ProgIDs of `Platypus.COM.dll`
- Self-check (`comcheck`): every COM class the app creates is instantiated, one process each

Linux: pinned portable Wine 11.0 by default (`--system-wine` to use the distro package;
Debian/Ubuntu, Fedora, Arch/CachyOS handled). macOS: Homebrew `wine-stable`, single Dock
tile via a bundle that reaches the Wine loader through itself.

Known limitations: the Windows Vista/7 "Aero" look is not available (Wine's Light or Classic
style only); the patched oleaut32 is built for Wine 11.x and is skipped on other versions
(the launcher restores it after Wine updates, and the installer re-run re-applies everything).
