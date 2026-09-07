#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# wine-platypus :: remove everything the installer created (Linux + macOS).
# Wine itself (the distro/Homebrew package) is left alone.
set -euo pipefail
cd "$(dirname "$0")"
REPO_DIR="$(pwd)"
. "$REPO_DIR/lib/common.sh"

if [ "$(uname -s)" = "Darwin" ]; then
  PLATYPUS_HOME="${PLATYPUS_HOME:-$HOME/Library/Application Support/Platypus}"
else
  PLATYPUS_HOME="${PLATYPUS_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/platypus}"
fi
[ "${1:-}" = "--yes" ] && PLATYPUS_NONINTERACTIVE=1

say "This removes the Platypus Wine prefix and launcher at: $PLATYPUS_HOME"
confirm "Continue?" || exit 0

if [ -f "$PLATYPUS_HOME/config" ]; then
  . "$PLATYPUS_HOME/config"
  [ -n "${WINE_BIN_DIR:-}" ] && [ -x "$WINE_BIN_DIR/wineserver" ] && WINEPREFIX="$PLATYPUS_HOME/prefix" "$WINE_BIN_DIR/wineserver" -k 2>/dev/null || true
fi
# restore any Wine oleaut32.dll we replaced (config lists the patched files)
if [ -n "${OLEAUT32_BACKUPS:-}" ]; then
  printf '%s\n' "$OLEAUT32_BACKUPS" | while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -f "$f.wine-platypus.orig" ]; then
      cp -f "$f.wine-platypus.orig" "$f" 2>/dev/null && rm -f "$f.wine-platypus.orig" && ok "Restored $f"
    fi
  done
fi
rm -rf "$PLATYPUS_HOME"
if [ "$(uname -s)" = "Darwin" ]; then
  rm -rf "$HOME/Applications/Platypus Billing.app"
else
  rm -f "$HOME/.local/bin/platypus" "$HOME/.local/share/applications/platypus-billing.desktop"
  for s in 16 32 48 256; do rm -f "$HOME/.local/share/icons/hicolor/${s}x${s}/apps/platypus-billing.png"; done
  need_cmd update-desktop-database && update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
fi
ok "Platypus removed. (Wine itself was not uninstalled.)"
