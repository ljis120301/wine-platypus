# Rebuilding the patched oleaut32.dll

`vendor/wine-patches/oleaut32-wine11.0-i386-builtin.dll` is Wine 11.0's 32-bit builtin
`oleaut32.dll` rebuilt with `0001-oleaut32-object-arg-and-default-property-put.patch`
(two fixes: NULL-for-object-parameter, and default-property write-through for an indexed
get-only property). It keeps the "Wine builtin DLL" marker and is dropped into the Wine
install dir in place of the stock builtin (a `.wine-platypus.orig` backup is kept). Rebuild it when the
Wine version in use changes (the installer only installs it on Wine 11.x).

The fix belongs upstream. Until it is merged, this is how the DLL was produced on Fedora,
without root (the same steps work on Ubuntu with `apt install gcc-mingw-w64 flex bison`):

```bash
# 1. MinGW-w64 cross compilers (Fedora: mingw32-gcc mingw64-gcc + their headers/crt)
sudo dnf install mingw32-gcc mingw64-gcc mingw32-headers mingw64-headers \
                 mingw32-crt mingw64-crt flex bison gcc make

# 2. Wine source, patched
curl -LO https://dl.winehq.org/wine/source/11.0/wine-11.0.tar.xz
tar xf wine-11.0.tar.xz && cd wine-11.0
patch -p1 < /path/to/wine-platypus/vendor/wine-patches/0001-oleaut32-object-arg-and-default-property-put.patch

# 3. Configure a PE-only cross build (no X11/audio/etc. needed for one DLL)
mkdir ../build && cd ../build
../wine-11.0/configure --enable-archs=x86_64,i386 --disable-tests \
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
cp dlls/oleaut32/i386-windows/oleaut32.dll /path/to/wine-platypus/vendor/wine-patches/oleaut32-wine11.0-i386-builtin.dll
cd /path/to/wine-platypus/vendor && sha256sum wine-patches/oleaut32-wine11.0-i386-builtin.dll tools/comcheck.exe tools/fixprogids.exe tools/ico2png.exe tools/comcheck-list.txt > SHA256SUMS
```

Where it goes: Wine 11 loads a builtin from the prefix's `system32`/`syswow64` copy, which
`wineboot` populates from `<wine>/lib*/wine/i386-windows/`. The installer therefore writes
the rebuilt DLL (builtin marker intact) to both the install dir (backup kept as
`.wine-platypus.orig`) and the existing prefix's system directory. Do not delete the
prefix copy: with it missing, every import of oleaut32 fails and Platypus cannot start.

Verification used during development: a small C program that late-binds
`MSXML2.DOMDocument.appendChild(NULL)`. Stock Wine returns `0x80020005` (type mismatch) and
logs `err:ole:ITypeInfo_fnInvoke failed to convert param 0 to VT_DISPATCH from {VT_NULL}`;
with the patch the NULL reaches the method (`0x80020009`, the method's own exception).
