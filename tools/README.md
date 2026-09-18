# tools/

Sources for the small Windows helpers in `vendor/tools/` (built with MinGW-w64, see
`docs/wine-patches.md` for the toolchain; `i686-w64-mingw32-gcc -O1 -o X.exe X.c -lole32 -loleaut32 -luuid -ladvapi32`).

* `fixprogids.c` -> `fixprogids.exe`: Windows' `CLSIDFromProgID` follows a ProgID's `CurVer`
  to its versioned ProgID; Wine's does not. Platypus' own COM library registers most of
  its version-independent ProgIDs (`Platypus.COM.TCPSocket`, `.DNS`, `.curl`, ...) with
  only `CurVer`, so `CREATEOBJECT()` on them fails under Wine ("Class definition ... is not
  found"; e.g. saving a MAC address). The tool adds the missing `CLSID` value to every
  such ProgID in the prefix.
* `comcheck.c` -> `comcheck.exe`: instantiates each ProgID from a list, each in its own
  process with a timeout, and reports OK / LICENSED / NOTREG / FAIL / CRASH / TIMEOUT.
  The installer runs it against `vendor/tools/comcheck-list.txt` as a self-check.
* `xmltest.c`: late-bound MSXML harness (loadXML, selectNodes().item(), createElement, ...);
  fails on Wine's msxml3, passes with Microsoft's - used to validate `install_native_msxml`.
* `ico2png.c` -> `ico2png.exe`: writes the largest PNG entry of a .ico to a .png; used at install
  time to take the app icon from the installed client instead of shipping it.
* `blackbox.c` -> `blackbox.exe`: demonstrates Wine's *deliberate* "delayed unmapping"
  behaviour - it is **not** a regression test for winehq bug 59378, despite looking like one.
  It hides a window by clearing `WS_VISIBLE` without `SWP_HIDEWINDOW`; the window stays
  mapped and Wine logs `not yet hidden, delaying unmapping` on the `x11drv` channel,
  identically on Wine 11.0 and 11.14 (measured on both). The 59378 fix changed only which
  state field gates that condition, which matters in a race, so this cannot tell the
  versions apart. Kept because mistaking it for a reproduction cost real debugging time.
