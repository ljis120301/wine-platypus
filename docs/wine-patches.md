# Rebuilding the patched oleaut32.dll

`vendor/wine-patches/oleaut32-wine11.14-i386-builtin.dll` is Wine 11.14's 32-bit builtin
`oleaut32.dll` rebuilt with `0001-oleaut32-object-arg-and-default-property-put.patch`
(two fixes: NULL-for-object-parameter, and default-property write-through for an indexed
get-only property). It keeps the "Wine builtin DLL" marker and is dropped into the Wine
install dir in place of the stock builtin (a `.wine-platypus.orig` backup is kept).

**Rebuild it whenever the pinned Wine changes.** The installer matches the Wine version
*exactly* (`PLATYPUS_OLEAUT32_WINE_VERSION` in `lib/common.sh`), not as `wine-11.*`: a
builtin built from one 11.x and dropped into another's tree loads without complaint and
then misbehaves subtly, which is far worse than skipping the patch with a warning.

**The fix is still not upstream.** Both defects are present in Wine 11.17, so re-check at
each Wine bump before assuming it is still needed.

The fix belongs upstream. Until it is merged, this is how the DLL was produced on Fedora,
without root (the same steps work on Ubuntu with `apt install gcc-mingw-w64 flex bison`):

```bash
# 1. MinGW-w64 cross compilers (Fedora: mingw32-gcc mingw64-gcc + their headers/crt)
sudo dnf install mingw32-gcc mingw32-headers mingw32-crt flex bison gcc make

# 2. Wine source, patched
curl -LO https://dl.winehq.org/wine/source/11.x/wine-11.14.tar.xz
tar xf wine-11.14.tar.xz && cd wine-11.14
patch -p1 < /path/to/wine-platypus/vendor/wine-patches/0001-oleaut32-object-arg-and-default-property-put.patch

# 3. Configure a PE-only cross build (no X11/audio/etc. needed for one DLL)
mkdir ../build && cd ../build
../wine-11.14/configure --enable-archs=i386 --disable-tests \
   --without-x --without-freetype --without-fontconfig --without-gnutls --without-gstreamer \
   --without-alsa --without-pulse --without-opengl --without-vulkan --without-wayland \
   --without-dbus --without-cups --without-krb5 --without-sdl --without-udev --without-usb \
   --without-v4l2 --without-unwind --without-capi --without-ffmpeg --without-netapi \
   --without-opencl --without-oss --without-pcap --without-pcsclite --without-gphoto \
   --without-sane --without-osmesa --without-inotify --without-xkbcommon --without-xkbregistry
make -j"$(nproc)" tools/winebuild/winebuild tools/wrc/wrc tools/widl/widl
make -j"$(nproc)" dlls/oleaut32/i386-windows/oleaut32.dll      # ~2 minutes

# 4. Strip (keep the builtin marker; it replaces the stock builtin in place)
i686-w64-mingw32-strip --strip-unneeded dlls/oleaut32/i386-windows/oleaut32.dll
cp dlls/oleaut32/i386-windows/oleaut32.dll /path/to/wine-platypus/vendor/wine-patches/oleaut32-wine11.14-i386-builtin.dll
cd /path/to/wine-platypus/vendor && sha256sum wine-patches/oleaut32-wine11.14-i386-builtin.dll tools/comcheck.exe tools/fixprogids.exe tools/ico2png.exe tools/comcheck-list.txt > SHA256SUMS
```

Where it goes: `oleaut32` is a `\KnownDlls` section, and the loader builds it from the
**Wine installation tree** (`<wine>/lib*/wine/i386-windows/`), not from the copy `wineboot`
leaves in the prefix - `WINEDEBUG=+module` says `open_known_dll loaded ... from known dlls`.
Patching only the prefix copy is therefore inert: the app keeps running stock `oleaut32`.
(That mistake shipped once. It looked like it worked because the Wine tree was already
patched by hand from an earlier attempt; a fresh Wine download exposed it.) The installer
writes the rebuilt DLL (builtin marker intact) to both the install dir (backup kept as
`.wine-platypus.orig`, recorded in the config so `uninstall.sh` restores it) and the
existing prefix's system directory. Do not delete the prefix copy: with it missing, every
import of oleaut32 fails and Platypus cannot start.

Verification used during development: a small C program that late-binds
`MSXML2.DOMDocument.appendChild(NULL)`. Stock Wine returns `0x80020005` (type mismatch) and
logs `err:ole:ITypeInfo_fnInvoke failed to convert param 0 to VT_DISPATCH from {VT_NULL}`;
with the patch the NULL reaches the method (`0x80020009`, the method's own exception).
