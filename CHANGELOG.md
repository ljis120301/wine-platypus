# Changelog

## v2.3.0 - 2026-09-19

Pins Wine **11.17**, fixing a hang that wedged Platypus after a few hours.

**The hang.** After hours of ordinary use the app stopped responding - window still on
screen, sometimes frozen mid-paint, sometimes black - with one CPU core pinned at 100%
indefinitely. It looked like a crash but was not: nothing appeared in `vfp9rerr.log` or
Platypus' own error log, because nothing crashed. Measured: main thread in `state=R`, zero
syscalls, zero page faults, instruction pointer parked in `win32u.so` at
`get_shared_queue+0x2d`, identical across two separate occurrences.

Cause: commit `08f7b746b00c` ("winex11: Send raw mouse motion frames from XI2 RawEvents"),
new in **11.13**, overruns a 64-entry raw-mouse frame buffer and corrupts wineserver-side
shared memory. The shared object's seqlock is left permanently odd, so
`shared_object_acquire_seqlock()`'s `while ((seq = ReadNoFence64(&object->seq)) & 1)
YieldProcessor();` never exits - a pure userspace spin. The tell just before it wedges is a
burst of `err:msg:process_hardware_message unknown message type 1/2/3`, which are
`WM_CREATE`/`WM_DESTROY`/`WM_MOVE` arriving on the hardware-message path.

Fixed upstream by `a1bae27f21b5` ("win32u: Don't ignore raw mouse input"), first shipped in
**11.15** - winehq [59986](https://bugs.winehq.org/show_bug.cgi?id=59986),
[59998](https://bugs.winehq.org/show_bug.cgi?id=59998),
[59999](https://bugs.winehq.org/show_bug.cgi?id=59999),
[60005](https://bugs.winehq.org/show_bug.cgi?id=60005) and
[60051](https://bugs.winehq.org/show_bug.cgi?id=60051), all CLOSED FIXED.

**11.13 and 11.14 are the only affected releases**, and v2.2.0 pinned 11.14 - so this
project shipped the bug for one release. Anyone on v2.2.x should upgrade.

- Pin moves 11.14 -> **11.17** (Kron4ek's newest; carries this fix plus the 11.0 window
  fixes v2.2.0 was after).
- `oleaut32` rebuilt from 11.17 sources; the patch still applies cleanly and is still not
  upstream (both defects remain in 11.17).
- `docs/how-it-works.md` now documents both defects and how each was identified.

A note on method, since it cost time: the first diagnosis of this hang compared
`get_shared_queue` across 11.14, 11.17 and master, found it byte-identical, and concluded
upgrading would not help. That was wrong - `get_shared_queue` is where the spin *shows up*,
not where the bug *is*. The fix is one line in `dlls/win32u/input.c`, upstream of it.

## v2.2.1 - 2026-09-17

Fixes the v2.2.0 upgrade path.

`ensure_portable_wine` only downloaded the pinned Wine when no tarball was cached, then
checksummed whatever was there against the expected hash and gave up on a mismatch. So every
machine upgrading from v2.1.0 - which has the **11.0** tarball sitting in
`$PLATYPUS_HOME/wine-pinned.tar.xz` - stopped with *"Wine tarball checksum mismatch ... delete
it and re-run"* before installing anything. The message said what to do, but requiring each
user to delete a file by hand defeats the point of a one-command installer.

A cached tarball whose checksum does not match the current pin is now treated as stale:
it is discarded and re-downloaded automatically. A tarball the user supplied explicitly via
`PLATYPUS_WINE_TARBALL` is never deleted - that one still reports the mismatch, since
silently removing a file someone pointed at would be wrong.

## v2.2.0 - 2026-09-17

Moves the pinned Wine to 11.14, which fixes the "black rectangle", and stops the launcher
destroying crash evidence.

**The black rectangle.** An opaque leftover window - sometimes solid black, sometimes an
empty outline, sometimes a translucent ghost of stale text - floated over the app after one
of its own windows closed. All three appearances are one mechanism: a window left mapped,
still holding whatever was last drawn into it, never repainted. Confirmed gone after moving
the pinned Wine 11.0 -> 11.14. The cause is almost certainly winehq
[bug 59378](https://bugs.winehq.org/show_bug.cgi?id=59378) (a `winex11` race leaving a
properly hidden window mapped; fix `2b05f63811f0` shipped in 11.13), though the jump spans
11.1-11.14 so it is not a bisected certainty.

Ruled out along the way, recorded so it is not re-investigated: it is **not** an MDI
painting bug (MDI children are drawn into the frame's own window surface and are not X11
windows at all - only one X11 toplevel exists with several forms open); **not**
compositor-specific; **not** transparency or an ARGB visual (every Wine window uses a
depth-24 visual); and **not** Wine Gecko. `tools/src/blackbox.c` is included but does *not*
reproduce 59378 - read its header before drawing conclusions from it.

**The launcher no longer truncates its log on every start.** Wine writes unhandled-exception
backtraces to stderr, which land in `platypus.log` - and truncating erased the previous
crash the moment the user relaunched. It now keeps the last ten runs as
`platypus.log.YYYYmmdd-HHMMSS`.

**The `oleaut32` version gate is now exact.** It matched `wine-11.*`, so it would have
dropped an 11.0-built builtin into an 11.14 tree - a mismatch that loads without complaint
and misbehaves subtly. It now matches `PLATYPUS_OLEAUT32_WINE_VERSION` exactly and skips the
patch loudly otherwise. The vendored DLL is rebuilt from Wine 11.14 sources; neither fix is
upstream yet (both defects are still present in 11.17), so the patch stays. The rebuild now
needs only the 32-bit MinGW toolchain - `--enable-archs=i386` builds the one DLL required.

**The installer and launcher now disable `mscoree`.** Bumping the pinned Wine changes
`wine.inf`'s mtime, so `wineboot` re-runs its prefix update and Wine opens a modal "could
not find a wine-mono package" dialog that blocks an unattended install. Platypus is Visual
FoxPro, never .NET. Gecko is deliberately left alone.

## v2.1.0 - 2026-09-11

Fixes the crash when opening an e-mail, and lets newer VB6/MFC runtimes be supplied.

The VB6 SP6 redistributable ships `msvbvm60.dll` 6.00.9782, and that build dereferences a
NULL object pointer as the e-mail editor opens: `movl 0x28(%edi)` with `edi=0`, a hard
`C0000005` inside msvbvm60 called straight from `vfp9r`. The VFP traceback shows only
`platmain`, so there is nothing in the app to point at. Windows carries a newer serviced
build, 6.00.9848, where the same screen works; MFC42 differs the same way (6.00.8665 vs
6.06.8063) and backs the `ct*` calendar controls.

Microsoft never shipped those builds standalone - they are serviced through Windows - so
they are neither downloadable nor redistributable. The installer now prefers
`vendor/msvbvm60.dll`, `vendor/mfc42.dll` and `vendor/mfc42u.dll` when present, falling
back to the SP6/VC6 copies with a warning when they are not. Copy them from a Windows
machine's `SysWOW64`.

Ruled out along the way, recorded so it is not re-investigated:

- The patched `oleaut32` is **not** responsible - the crash reproduces identically with the
  stock DLL. (That test also re-confirmed the oleaut32 patch is doing its job: the old
  `MSGASSIGN` / `0x8002000e` failure reappears without it.)
- 65 Crystal/BusinessObjects classes that a working Windows install registers cannot be
  instantiated here, but not because of a registration gap: they register fine and their
  `DllGetClassObject` then returns `CLASS_E_CLASSNOTAVAILABLE` (COM reports the misleading
  `REGDB_E_CLASSNOTREG` afterwards). These are report-export and Enterprise-server classes
  that most likely refuse on Windows too, so nothing is registered speculatively.
- Wine Gecko is genuinely absent from the prefix (only a stub `npmshtml.dll`), but
  installing 2.47.4 did not change the black rectangle seen when opening an e-mail, so it
  is not shipped as a fix for that.

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
