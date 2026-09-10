# Changelog

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
