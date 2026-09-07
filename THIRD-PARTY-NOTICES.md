# Third-party components

The scripts and tools in this repository are licensed under the GNU General Public License,
version 3 or (at your option) any later version (see `LICENSE`). They install and rely on
software from other parties, which keeps its own licence:

* **Platypus Billing System (Client)** is a product of Tucows Inc. It is **not** included
  here. You need your own licensed installer (`Platypus7.Client.exe`) from Tucows; the
  application's icon is extracted from that installer on your machine, not shipped.
* **Wine** (LGPL-2.1-or-later). `vendor/wine-patches/oleaut32-wine11.0-i386-builtin.dll` is
  Wine 11.0's `oleaut32.dll` rebuilt with the patch in the same folder. In line with the
  LGPL, the complete corresponding source is Wine 11.0
  (https://dl.winehq.org/wine/source/11.0/wine-11.0.tar.xz) plus that patch; build
  instructions are in `docs/wine-patches.md`.
* **Microsoft redistributables** (downloaded on first install, or supplied by you in
  `vendor/`, each verified against a known SHA-256): MDAC 2.8 SP1 (`MDAC_TYP.EXE`),
  Visual C++ 6.0 runtime (`VC6RedistSetup_deu.exe`), Visual Basic 6.0 SP6 runtime
  (`VB6.0-KB290887-X86.exe`), MSXML 3.0 SP7 (`msxml3.msi`), MSXML 4.0 SP3 (`msxml.msi`),
  MSXML 6.0 SP2 (`msxml6-KB2957482-enu-amd64.exe`). They are used under Microsoft's
  redistribution terms for those packages; the URLs are the ones the winetricks project uses.
* The pinned portable Wine build for Linux is downloaded from the Kron4ek/Wine-Builds
  project (vanilla WineHQ 11.0 sources) and verified by SHA-256.
