#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ---------------------------------------------------------------------------
# wine-platypus :: shared installer logic (Linux + macOS)
#
# Sourced by install.sh / install-macos.sh / uninstall.sh. Requires bash 3.2+
# (macOS ships bash 3.2, so: no associative arrays, no ${var,,}, no mapfile).
#
# What the full install does, in order:
#   1. create a dedicated Wine prefix       ($PLATYPUS_HOME/prefix)
#   2. run the Platypus NSIS installer silently (/S)
#   3. install Microsoft's ODBC driver manager + "SQL Server" ODBC driver
#      (from the MDAC 2.8 SP1 redistributable) into the prefix, and register a
#      System DSN called "Platypus" that points at your SQL Server
#   4. install a launcher + application-menu entry (Linux) or a .app bundle (macOS)
#
# Why step 3 exists: Platypus is a Visual FoxPro 9 app that talks to SQL Server
# through ODBC (SQLCONNECT). Wine's own odbc32 cannot be used by FoxPro (it
# rejects SQLSetConnectOption() before connect), so the real Microsoft driver
# manager and driver are dropped into the prefix instead. See docs/how-it-works.md
# ---------------------------------------------------------------------------

set -Eeuo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
VENDOR_DIR="$REPO_DIR/vendor"
ASSETS_DIR="$REPO_DIR/assets"
PLATYPUS_INSTALLER="$VENDOR_DIR/Platypus7.Client.exe"
MDAC_PACKAGE="$VENDOR_DIR/MDAC_TYP.EXE"
VC6_PACKAGE="$VENDOR_DIR/VC6RedistSetup_deu.exe"
VB6_PACKAGE="$VENDOR_DIR/VB6.0-KB290887-X86.exe"
OLEAUT32_PATCHED="$VENDOR_DIR/wine-patches/oleaut32-wine11.0-i386-builtin.dll"
TOOLS_DIR="$VENDOR_DIR/tools"
MSXML3_PACKAGE="$VENDOR_DIR/msxml3.msi"
MSXML4_PACKAGE="$VENDOR_DIR/msxml.msi"
MSXML6_PACKAGE="$VENDOR_DIR/msxml6-KB2957482-enu-amd64.exe"

# Defaults (override with env vars or CLI flags)
: "${PLATYPUS_SQL_SERVER:=}"       # your SQL Server host/IP - asked for, no default
: "${PLATYPUS_SQL_DATABASE:=}"     # your Platypus database name - asked for, no default
: "${PLATYPUS_DSN_NAME:=Platypus}"
: "${PLATYPUS_NONINTERACTIVE:=0}"
: "${PLATYPUS_WINEARCH:=}"        # empty = auto (win32 when the Wine build supports it, else win64)
: "${PLATYPUS_WINE:=}"            # path to a specific `wine` binary (portable builds, testing)
: "${PLATYPUS_THEME:=light}"      # light (Wine default since 10.0) or classic (Windows 2000 look)
# Pinned portable Wine for Linux (vanilla WineHQ 11.0 sources, Kron4ek build, WoW64 flavour:
# runs 32-bit apps without any 32-bit host libraries). Changing Wine = re-validate + bump here.
: "${PLATYPUS_WINE_PIN_VERSION:=wine-11.0}"
: "${PLATYPUS_WINE_PIN_URL:=https://github.com/Kron4ek/Wine-Builds/releases/download/11.0/wine-11.0-amd64-wow64.tar.xz}"
: "${PLATYPUS_WINE_PIN_SHA256:=39574efa1132c3ca0d5c77dd2eddbe4a49cca0d6cc2c290ff4924493a1c40314}"
: "${PLATYPUS_WINE_TARBALL:=}"    # optional: local copy of the tarball (offline installs / tests)

# ---- output helpers --------------------------------------------------------
if [ -t 1 ]; then
  C_B=$'\033[1m'; C_DIM=$'\033[2m'
  C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_C=$'\033[36m'
  C_0=$'\033[0m'
else
  C_B=""; C_DIM=""; C_G=""; C_Y=""; C_R=""; C_C=""; C_0=""
fi
say()  { printf '\n%s▸%s %s\n' "$C_C$C_B" "$C_0" "$*"; }
ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '  %s⚠%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '\n%s✘%s %s\n\n' "$C_R$C_B" "$C_0" "$*" >&2; exit 1; }

hr() { printf '%s%s%s\n' "$C_DIM" "----------------------------------------------------------------" "$C_0"; }
banner() {  # banner "Linux installer"
  hr
  printf '%s%swine-platypus%s %s· %s%s\n' "$C_B" "$C_C" "$C_0" "$C_DIM" "$1" "$C_0"
  hr
}

# ask VAR "Prompt" "default"  -> sets VAR. With an empty default the answer is required:
# it re-prompts interactively and fails in non-interactive mode (pass --server/--database).
ask() {
  local _var="$1" _prompt="$2" _def="$3" _ans=""
  if [ "$PLATYPUS_NONINTERACTIVE" = "1" ] || [ ! -t 0 ]; then
    [ -n "$_def" ] || die "'$_prompt' is required in non-interactive mode (use the matching --option)"
    eval "$_var=\"\$_def\""; return
  fi
  while :; do
    if [ -n "$_def" ]; then printf '  %s%s%s [%s]: ' "$C_B" "$_prompt" "$C_0" "$_def"; else printf '  %s%s%s: ' "$C_B" "$_prompt" "$C_0"; fi
    read -r _ans || true
    [ -n "$_ans" ] || _ans="$_def"
    [ -n "$_ans" ] && break
    echo "  (required)"
  done
  eval "$_var=\"\$_ans\""
}

confirm() {  # confirm "question" -> 0 = yes
  local _ans=""
  if [ "$PLATYPUS_NONINTERACTIVE" = "1" ] || [ ! -t 0 ]; then return 0; fi
  printf '  %s%s%s [Y/n]: ' "$C_B" "$1" "$C_0"; read -r _ans || true
  case "$_ans" in n|N|no|NO|No) return 1 ;; *) return 0 ;; esac
}

# menu VAR "Title" "option 1" "option 2" ...  -> sets VAR to the chosen number
# (as text). Non-interactive/piped runs always get option 1, same as before
# this existed - it only shows up when there is a real terminal to answer it.
menu() {
  local _var="$1" _title="$2"; shift 2
  if [ "$PLATYPUS_NONINTERACTIVE" = "1" ] || [ ! -t 0 ]; then eval "$_var=1"; return; fi
  printf '\n  %s%s%s\n' "$C_B" "$_title" "$C_0"
  local _i=1 _opt
  for _opt in "$@"; do printf '    %s%d)%s %s\n' "$C_C" "$_i" "$C_0" "$_opt"; _i=$((_i + 1)); done
  local _ans=""
  printf '  Choice [1]: '; read -r _ans || true
  case "$_ans" in ''|*[!0-9]*) _ans=1 ;; esac
  { [ "$_ans" -ge 1 ] && [ "$_ans" -le $(($# )) ]; } || _ans=1
  eval "$_var=\"\$_ans\""
}

need_cmd() { command -v "$1" >/dev/null 2>&1; }

# ---- crash handling ---------------------------------------------------------
# Every install step below checks whether its own work is already done before
# doing it, so if something fails here, re-running the installer picks up
# where it left off - nothing needs to be cleaned up by hand first.
on_error() {
  local code="$1" line="$2" cmd="$3" src="$4"
  trap - ERR
  printf '\n%s%s✘ Something went wrong%s\n\n' "$C_R" "$C_B" "$C_0" >&2
  printf '  command : %s\n' "$cmd" >&2
  printf '  where   : %s, line %s (exit code %s)\n' "${src##*/}" "$line" "$code" >&2
  if [ -n "${LOG_DIR:-}" ] && [ -s "$LOG_DIR/install.log" ]; then
    printf '  log     : %s\n\n' "$LOG_DIR/install.log" >&2
    printf '  last lines of the log:\n' >&2
    tail -n 8 "$LOG_DIR/install.log" | sed 's/^/    /' >&2
    printf '\n' >&2
  else
    printf '\n' >&2
  fi
  printf '  Nothing is left half-installed - every step checks its own work first,\n' >&2
  printf '  so fix the problem above and just run the installer again.\n\n' >&2
  exit "$code"
}
on_interrupt() {
  trap - INT
  printf '\n%s⚠  Cancelled - nothing further was changed.%s\n\n' "$C_Y" "$C_0" >&2
  exit 130
}

# ---- preflight: disk space ---------------------------------------------------
# A run that dies halfway through unpacking a ~300 MB Wine prefix because the
# disk filled up is a bad first impression - catch it up front instead.
check_disk_space() {
  local dir="$PLATYPUS_HOME" need_kb=800000   # ~800 MB: Wine download + unpack + prefix
  while [ ! -d "$dir" ]; do dir="$(dirname "$dir")"; done
  need_cmd df || return 0
  local avail_kb; avail_kb="$(df -Pk "$dir" 2>/dev/null | awk 'NR==2 {print $4}')"
  case "$avail_kb" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$avail_kb" -lt "$need_kb" ]; then
    warn "Only $((avail_kb / 1024)) MB free where $PLATYPUS_HOME lives - this install needs roughly 800 MB"
    confirm "Continue anyway?" || die "Free up some disk space and re-run the installer"
  fi
}

# ---- paths -----------------------------------------------------------------
init_paths() {
  # PLATYPUS_HOME must be set by the caller (differs between Linux/macOS)
  [ -n "${PLATYPUS_HOME:-}" ] || die "PLATYPUS_HOME is not set"
  PREFIX="$PLATYPUS_HOME/prefix"
  CONFIG_FILE="$PLATYPUS_HOME/config"
  LOG_DIR="$PLATYPUS_HOME/logs"
  BIN_DIR="$PLATYPUS_HOME/bin"
  mkdir -p "$PLATYPUS_HOME" "$LOG_DIR" "$BIN_DIR"
}

load_config() { [ -f "${CONFIG_FILE:-/nonexistent}" ] && . "$CONFIG_FILE" || true; }

save_config() {
  cat >"$CONFIG_FILE" <<CFG
# generated by wine-platypus install script on $(date)
WINE="$WINE"
WINE_BIN_DIR="$WINE_BIN_DIR"
WINE_VERSION="$WINE_VERSION"
WINE_MODE="${WINE_MODE:-unknown}"
PREFIX_ARCH="$PREFIX_ARCH"
APP_DIR="$APP_DIR"
PLATYPUS_SQL_SERVER="$PLATYPUS_SQL_SERVER"
PLATYPUS_SQL_DATABASE="$PLATYPUS_SQL_DATABASE"
PLATYPUS_DSN_NAME="$PLATYPUS_DSN_NAME"
PLATYPUS_THEME="$PLATYPUS_THEME"
OLEAUT32_BACKUPS="$OLEAUT32_BACKUPS"
CFG
}

# ---- vendor files ------------------------------------------------------------
# * Platypus7.Client.exe is Tucows' licensed software and is NOT part of this repository:
#   copy your own installer into vendor/ first.
# * The Microsoft redistributables are downloaded on first use (pinned URLs, sha256
#   verified - the same files the winetricks project uses) or can be dropped into vendor/.
vendor_sha256() { if need_cmd sha256sum; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
vendor_fetch() {  # vendor_fetch <file> <sha256> <url> [fallback-url ...]  (per-URL checksum; moves to the next source on any failure)
  local name="$1" f="$VENDOR_DIR/$1" sum="$2" url got; shift 2
  if [ -f "$f" ]; then
    got="$(vendor_sha256 "$f")"
    [ "$got" = "$sum" ] || die "$name in vendor/ does not match its known checksum ($got). Delete it and re-run, or replace it with a good copy (sources in vendor/README.md)."
    return 0
  fi
  need_cmd curl || need_cmd wget || die "Need curl or wget to download $name (or place it in vendor/ yourself, see vendor/README.md)"
  for url in "$@"; do
    say "Downloading $name"
    rm -f "$f.part"
    if need_cmd curl; then curl -fL --progress-bar --retry 2 -o "$f.part" "$url" || { warn "download failed: $url"; continue; }
    else wget -q --show-progress -O "$f.part" "$url" || { warn "download failed: $url"; continue; }; fi
    got="$(vendor_sha256 "$f.part")"
    if [ "$got" = "$sum" ]; then mv -f "$f.part" "$f"; return 0; fi
    warn "incomplete or wrong download ($(wc -c <"$f.part" | tr -d ' ') bytes) from $url; trying the next source"
  done
  rm -f "$f.part"
  die "Could not get a good copy of $name from any known location (archive.org may be busy; re-run later). Or download it yourself (sources and checksums in vendor/README.md), put it in vendor/, and re-run."
}
check_vendor_files() {
  if [ ! -f "$PLATYPUS_INSTALLER" ]; then
    die "Platypus installer not found. Copy your Platypus 7 client installer from Tucows to:
     $PLATYPUS_INSTALLER
   (this project does not ship Tucows' software). Then re-run."
  fi
  vendor_fetch MDAC_TYP.EXE 157ebae46932cb9047b58aa849ac1885e8cbd2f218810cb83e57613b49c679d6 \
    "https://web.archive.org/web/20070127061938id_/https://download.microsoft.com/download/4/a/a/4aafff19-9d21-4d35-ae81-02c48dcbbbff/MDAC_TYP.EXE" \
    "https://web.archive.org/web/20200803205618id_/https://download.microsoft.com/download/4/a/a/4aafff19-9d21-4d35-ae81-02c48dcbbbff/MDAC_TYP.EXE" \
    "https://web.archive.org/web/2000id_/https://download.microsoft.com/download/4/a/a/4aafff19-9d21-4d35-ae81-02c48dcbbbff/MDAC_TYP.EXE"
  vendor_fetch VC6RedistSetup_deu.exe c2eb91d9c4448d50e46a32fecbcc3b418706d002beab9b5f4981de552098cee7 \
    "https://download.microsoft.com/download/vc60pro/Update/2/W9XNT4/EN-US/VC6RedistSetup_deu.exe" \
    "https://web.archive.org/web/2000id_/https://download.microsoft.com/download/vc60pro/Update/2/W9XNT4/EN-US/VC6RedistSetup_deu.exe"
  vendor_fetch VB6.0-KB290887-X86.exe 467b5a10c369865f2021d379fc0933cb382146b702bbca4bcb703fc86f4322bb \
    "https://web.archive.org/web/20210125001711id_/http://download.microsoft.com/download/5/a/d/5ad868a0-8ecd-4bb0-a882-fe53eb7ef348/VB6.0-KB290887-X86.exe" \
    "https://web.archive.org/web/20200803205221id_/https://download.microsoft.com/download/5/a/d/5ad868a0-8ecd-4bb0-a882-fe53eb7ef348/VB6.0-KB290887-X86.exe" \
    "https://web.archive.org/web/2000id_/http://download.microsoft.com/download/5/a/d/5ad868a0-8ecd-4bb0-a882-fe53eb7ef348/VB6.0-KB290887-X86.exe"
  vendor_fetch msxml3.msi f9c678f8217e9d4f9647e8a1f6d89a7c26a57b9e9e00d39f7487493dd7b4e36c \
    "https://media.codeweavers.com/pub/other/msxml3.msi" \
    "https://web.archive.org/web/2000id_/https://media.codeweavers.com/pub/other/msxml3.msi"
  vendor_fetch msxml.msi 47c2ae679c37815da9267c81fc3777de900ad2551c11c19c2840938b346d70bb \
    "https://web.archive.org/web/20210506101448id_/http://download.microsoft.com/download/A/2/D/A2D8587D-0027-4217-9DAD-38AFDB0A177E/msxml.msi" \
    "https://web.archive.org/web/2000id_/http://download.microsoft.com/download/A/2/D/A2D8587D-0027-4217-9DAD-38AFDB0A177E/msxml.msi"
  vendor_fetch msxml6-KB2957482-enu-amd64.exe 260cd870851ffc3c6d10b71691f134e20d8d03ac26073bb36951eacb7aa85897 \
    "https://download.microsoft.com/download/2/7/7/277681BE-4048-4A58-ABBA-259C465B1699/msxml6-KB2957482-enu-amd64.exe" \
    "https://web.archive.org/web/2000id_/https://download.microsoft.com/download/2/7/7/277681BE-4048-4A58-ABBA-259C465B1699/msxml6-KB2957482-enu-amd64.exe"
  [ -f "$OLEAUT32_PATCHED" ]  || die "Missing $OLEAUT32_PATCHED (did you clone the whole repo?)"
  [ -f "$TOOLS_DIR/comcheck.exe" ] && [ -f "$TOOLS_DIR/fixprogids.exe" ] && [ -f "$TOOLS_DIR/ico2png.exe" ] || die "Missing vendor/tools (did you clone the whole repo?)"
  if need_cmd sha256sum; then (cd "$VENDOR_DIR" && sha256sum --quiet -c SHA256SUMS) || die "vendor/ files failed checksum verification"
  elif need_cmd shasum; then (cd "$VENDOR_DIR" && shasum -a 256 --quiet -c SHA256SUMS) || die "vendor/ files failed checksum verification"; fi
  ok "Vendor files present and verified"
}

# ---- wine discovery --------------------------------------------------------
# ---- 0. pinned portable Wine (Linux default) ---------------------------------------------
# Puts a checksummed Wine 11.0 into $PLATYPUS_HOME/wine so the install does not depend on -
# and cannot be broken by - the distro's Wine package or its upgrades. Re-used if already
# present with the pinned version. Needs curl or wget, tar, xz.
ensure_portable_wine() {
  local dest="$PLATYPUS_HOME/wine"
  if [ -x "$dest/bin/wine" ]; then
    local v; v="$("$dest/bin/wine" --version 2>/dev/null || true)"
    case "$v" in "$PLATYPUS_WINE_PIN_VERSION"*) PLATYPUS_WINE="$dest/bin/wine"; ok "Pinned Wine present ($v)"; return 0 ;; esac
    warn "$dest holds $v, not $PLATYPUS_WINE_PIN_VERSION - replacing it"
  fi
  local tb="${PLATYPUS_WINE_TARBALL:-$PLATYPUS_HOME/wine-pinned.tar.xz}"
  local dl_fail="Could not download Wine from $PLATYPUS_WINE_PIN_URL - check your internet connection and try again (or download it yourself and re-run with PLATYPUS_WINE_TARBALL=/path/to/file.tar.xz)"
  if [ ! -f "$tb" ]; then
    say "Downloading pinned Wine ($PLATYPUS_WINE_PIN_VERSION, ~70 MB)"
    if need_cmd curl; then curl -fL --progress-bar -o "$tb.part" "$PLATYPUS_WINE_PIN_URL" || { rm -f "$tb.part"; die "$dl_fail"; }
    elif need_cmd wget; then wget -q --show-progress -O "$tb.part" "$PLATYPUS_WINE_PIN_URL" || { rm -f "$tb.part"; die "$dl_fail"; }
    else die "Need curl or wget to download Wine (or set PLATYPUS_WINE_TARBALL to a local copy)"; fi
    mv -f "$tb.part" "$tb"
  fi
  local sum; if need_cmd sha256sum; then sum="$(sha256sum "$tb" | cut -d' ' -f1)"; else sum="$(shasum -a 256 "$tb" | cut -d' ' -f1)"; fi
  [ "$sum" = "$PLATYPUS_WINE_PIN_SHA256" ] || die "Wine tarball checksum mismatch (got $sum) - delete $tb and re-run to download it again"
  say "Unpacking pinned Wine into $dest"
  rm -rf "$dest.new"; mkdir -p "$dest.new"
  tar -xJf "$tb" -C "$dest.new" --strip-components=1 || die "The Wine archive at $tb looks corrupt - delete it and re-run the installer to download it again"
  rm -rf "$dest"; mv "$dest.new" "$dest"
  [ -x "$dest/bin/wine" ] || die "Unpacked Wine has no bin/wine"
  PLATYPUS_WINE="$dest/bin/wine"; ok "Pinned Wine installed ($("$dest/bin/wine" --version))"
}
# SQL settings: a previous install's values are the defaults (there are no built-in ones);
# non-interactive runs must have both before anything slow happens.
require_sql_settings() {
  if [ -f "$CONFIG_FILE" ]; then
    [ -n "$PLATYPUS_SQL_SERVER" ]   || PLATYPUS_SQL_SERVER="$(sed -n 's/^PLATYPUS_SQL_SERVER="\(.*\)"$/\1/p' "$CONFIG_FILE")"
    [ -n "$PLATYPUS_SQL_DATABASE" ] || PLATYPUS_SQL_DATABASE="$(sed -n 's/^PLATYPUS_SQL_DATABASE="\(.*\)"$/\1/p' "$CONFIG_FILE")"
  fi
  if [ "$PLATYPUS_NONINTERACTIVE" = "1" ] || [ ! -t 0 ]; then
    { [ -n "$PLATYPUS_SQL_SERVER" ] && [ -n "$PLATYPUS_SQL_DATABASE" ]; } \
      || die "Non-interactive install needs --server <host> and --database <name> (no built-in defaults; ask your Platypus administrator)"
  fi
}
find_wine() {
  local cand
  if [ -n "$PLATYPUS_WINE" ]; then
    [ -x "$PLATYPUS_WINE" ] || die "PLATYPUS_WINE=$PLATYPUS_WINE is not executable"
    WINE="$PLATYPUS_WINE"
  else
    WINE=""
    # The pinned portable Wine inside the install folder wins whenever that mode is in effect
    # (Linux default; re-runs and --verify read WINE_MODE back from the saved config).
    if [ "${WINE_MODE:-portable}" = "portable" ] && [ -x "$PLATYPUS_HOME/wine/bin/wine" ]; then WINE="$PLATYPUS_HOME/wine/bin/wine"; fi
    [ -n "$WINE" ] || for cand in "$(command -v wine 2>/dev/null || true)" \
                "/Applications/Wine Stable.app/Contents/Resources/wine/bin/wine" \
                "$HOME/Applications/Wine Stable.app/Contents/Resources/wine/bin/wine" \
                /opt/homebrew/bin/wine /usr/local/bin/wine /usr/bin/wine; do
      if [ -n "$cand" ] && [ -x "$cand" ]; then WINE="$cand"; break; fi
    done
    [ -n "$WINE" ] || return 1
  fi
  # resolve symlinks so WINE_BIN_DIR points at the real bin/ (needed for wineserver)
  local real="$WINE"
  while [ -L "$real" ]; do
    local target; target="$(readlink "$real")"
    case "$target" in /*) real="$target" ;; *) real="$(dirname "$real")/$target" ;; esac
  done
  WINE_BIN_DIR="$(cd "$(dirname "$real")" && pwd)"
  WINESERVER="$WINE_BIN_DIR/wineserver"
  [ -x "$WINESERVER" ] || WINESERVER="$(command -v wineserver 2>/dev/null || true)"
  WINE_VERSION="$("$WINE" --version 2>/dev/null || echo unknown)"
  ok "Using $WINE ($WINE_VERSION)"
}

wine_wait() { [ -n "${WINESERVER:-}" ] && [ -x "$WINESERVER" ] && WINEPREFIX="$PREFIX" "$WINESERVER" -w || true; }
wine_kill() { [ -n "${WINESERVER:-}" ] && [ -x "$WINESERVER" ] && WINEPREFIX="$PREFIX" "$WINESERVER" -k 2>/dev/null || true; }

# run wine quietly inside the prefix; logs go to $LOG_DIR/install.log
wine_run() {
  WINEPREFIX="$PREFIX" WINEDEBUG="${WINEDEBUG:--all}" \
    "$WINE" "$@" >>"$LOG_DIR/install.log" 2>&1
}

# ---- 1. prefix ---------------------------------------------------------------
create_prefix() {
  local fresh="${1:-0}"
  if [ "$fresh" = "1" ] && [ -d "$PREFIX" ]; then
    say "Removing existing prefix (--fresh)"; wine_kill; rm -rf "$PREFIX"
  fi
  if [ -f "$PREFIX/system.reg" ]; then
    ok "Reusing existing Wine prefix at $PREFIX"
  else
    say "Creating Wine prefix at $PREFIX (this takes ~30 s)"
    rm -rf "$PREFIX"
    # mscoree/mshtml disabled only during creation: avoids the Mono/Gecko download
    # prompts. winemenubuilder disabled so Wine does not litter your app menu.
    local boot_overrides="mscoree=d;mshtml=d;winemenubuilder.exe=d"
    local arch="$PLATYPUS_WINEARCH"
    if [ -z "$arch" ]; then
      # Prefer a pure 32-bit prefix (the app is 32-bit). WoW64-only Wine builds
      # (macOS, some distros) cannot create one -> fall back to win64.
      if WINEARCH=win32 WINEPREFIX="$PREFIX" WINEDEBUG=-all WINEDLLOVERRIDES="$boot_overrides" \
           "$WINE" wineboot -u >>"$LOG_DIR/install.log" 2>&1; then
        arch=win32
      else
        rm -rf "$PREFIX"; arch=win64
      fi
    fi
    if [ "$arch" = "win64" ]; then
      WINEARCH=win64 WINEPREFIX="$PREFIX" WINEDEBUG=-all WINEDLLOVERRIDES="$boot_overrides" \
        "$WINE" wineboot -u >>"$LOG_DIR/install.log" 2>&1 || die "wineboot failed (see $LOG_DIR/install.log)"
    fi
    wine_wait
    [ -f "$PREFIX/system.reg" ] || die "Prefix creation failed (see $LOG_DIR/install.log)"
  fi
  if [ -d "$PREFIX/drive_c/windows/syswow64" ]; then PREFIX_ARCH=win64; else PREFIX_ARCH=win32; fi
  # permanently keep Wine's menu builder off for this prefix
  wine_run reg add 'HKCU\Software\Wine\DllOverrides' /v 'winemenubuilder.exe' /t REG_SZ /d '' /f
  ok "Prefix ready ($PREFIX_ARCH)"
}

# 32-bit system dir + the regedit that writes the 32-bit registry view
prefix_sysdir() {
  if [ "$PREFIX_ARCH" = "win64" ]; then echo "$PREFIX/drive_c/windows/syswow64"; else echo "$PREFIX/drive_c/windows/system32"; fi
}
prefix_regedit() {
  if [ "$PREFIX_ARCH" = "win64" ]; then echo 'C:\windows\syswow64\regedit.exe'; else echo 'C:\windows\regedit.exe'; fi
}
prefix_regsvr32() {
  if [ "$PREFIX_ARCH" = "win64" ]; then echo 'C:\windows\syswow64\regsvr32.exe'; else echo 'C:\windows\system32\regsvr32.exe'; fi
}
# Windows path of the 32-bit Program Files dir (where the Platypus installer put things)
prefix_pf32_win() {
  if [ "$PREFIX_ARCH" = "win64" ]; then echo 'C:\Program Files (x86)'; else echo 'C:\Program Files'; fi
}

# ---- 2. Platypus client ------------------------------------------------------
find_app_dir() {
  local d
  for d in "$PREFIX/drive_c/Program Files (x86)/Platypus" "$PREFIX/drive_c/Program Files/Platypus"; do
    if [ -f "$d/plat.exe" ]; then APP_DIR="$d"; return 0; fi
  done
  return 1
}

install_platypus() {
  if find_app_dir; then
    ok "Platypus client already installed in prefix ($APP_DIR)"; return
  fi
  say "Installing Platypus client (silent NSIS install, ~1 min)"
  WINEPREFIX="$PREFIX" WINEDEBUG=-all WINEDLLOVERRIDES="winemenubuilder.exe=d" \
    "$WINE" "$PLATYPUS_INSTALLER" /S >>"$LOG_DIR/install.log" 2>&1 || true
  wine_wait
  find_app_dir || die "Platypus installer did not produce plat.exe (see $LOG_DIR/install.log)"
  ok "Platypus client installed ($APP_DIR)"
}


# ---- 2b. application icon ------------------------------------------------------------
# The icon is Tucows' artwork, so it is not shipped here; it is pulled out of the installed
# client's base.ico (256x256 PNG entry) with vendor/tools/ico2png.exe running under Wine.
extract_app_icon() {
  mkdir -p "$PLATYPUS_HOME/icon"; ICON_PNG="$PLATYPUS_HOME/icon/platypus-256.png"
  [ -f "$ICON_PNG" ] && { ok "Application icon present"; return 0; }
  cp -f "$TOOLS_DIR/ico2png.exe" "$PREFIX/drive_c/windows/temp/ico2png.exe"
  local ico="$(prefix_pf32_win)\\Platypus\\base.ico"
  WINEPREFIX="$PREFIX" WINEDEBUG=-all "$WINE" 'C:\windows\temp\ico2png.exe' "$ico" 'C:\windows\temp\platypus-256.png' >>"$LOG_DIR/install.log" 2>&1 || true
  wine_wait
  if [ -s "$PREFIX/drive_c/windows/temp/platypus-256.png" ]; then mv -f "$PREFIX/drive_c/windows/temp/platypus-256.png" "$ICON_PNG"; ok "Application icon extracted"
  else warn "Could not extract the application icon; the menu entry will use a generic one"; ICON_PNG=""; fi
}

# ---- 3. SQL Server ODBC driver (MDAC 2.8 SP1) --------------------------------
install_sqlserver_odbc() {
  need_cmd cabextract || die "cabextract is required (apt/dnf/brew install cabextract)"
  local sysdir; sysdir="$(prefix_sysdir)"
  if [ -f "$sysdir/sqlsrv32.dll" ] && [ -f "$sysdir/odbc32.dll" ] && ! grep -q "Wine placeholder DLL" "$sysdir/odbc32.dll" 2>/dev/null; then
    ok "SQL Server ODBC driver already present"; return
  fi
  say "Installing Microsoft ODBC driver manager + SQL Server ODBC driver (MDAC 2.8 SP1)"
  local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/mdac.XXXXXX")"
  cabextract -q -d "$tmp" "$MDAC_PACKAGE"
  local cab
  for cab in mdacxpak sqlodbc sqlnet; do
    [ -f "$tmp/$cab.cab" ] || die "MDAC package is missing $cab.cab"
    mkdir -p "$tmp/$cab"; cabextract -q -d "$tmp/$cab" "$tmp/$cab.cab"
  done
  # copy with lower-case names so they replace Wine's built-in placeholders
  local f
  for f in ODBC32.dll ODBCCP32.dll ODBCINT.dll ODBCCR32.dll ODBCCU32.dll ODBCTRAC.dll odbcad32.exe; do
    cp -f "$tmp/mdacxpak/$f" "$sysdir/$(printf '%s' "$f" | tr 'A-Z' 'a-z')"
  done
  for f in sqlsrv32.dll sqlsrv32.rll odbcbcp.dll; do cp -f "$tmp/sqlodbc/$f" "$sysdir/$f"; done
  for f in dbnetlib.dll dbnmpntw.dll sqlunirl.dll; do cp -f "$tmp/sqlnet/$f" "$sysdir/$f"; done
  rm -rf "$tmp"

  # Tell Wine to use the native (Microsoft) ODBC driver manager for this prefix
  local regf="$PREFIX/drive_c/windows/temp/odbc-driver.reg"
  cat >"$regf" <<'REG'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SOFTWARE\ODBC\ODBCINST.INI\ODBC Drivers]
"SQL Server"="Installed"

[HKEY_LOCAL_MACHINE\SOFTWARE\ODBC\ODBCINST.INI\SQL Server]
"APILevel"="2"
"ConnectFunctions"="YYY"
"CPTimeout"="60"
"Driver"="C:\\windows\\system32\\SQLSRV32.dll"
"DriverODBCVer"="03.50"
"FileUsage"="0"
"Setup"="C:\\windows\\system32\\sqlsrv32.dll"
"SQLLevel"="1"
"UsageCount"=dword:00000001

[HKEY_CURRENT_USER\Software\Wine\DllOverrides]
"odbc32"="native,builtin"
"odbccp32"="native,builtin"
"odbccu32"="native,builtin"
"odbccr32"="native,builtin"
"odbcbcp"="native,builtin"
REG
  wine_run "$(prefix_regedit)" /S 'C:\windows\temp\odbc-driver.reg'
  wine_wait
  ok "SQL Server ODBC driver installed"
}


# ---- 3a. VB6 + MFC42 runtimes for the bundled ActiveX controls ----------------------
# ChadoSpellText.ocx (spell checker) and IEPostWrapper.ocx (web posting) are Visual
# Basic 6 controls -> need msvbvm60.dll. ctAlarm.ocx needs mfc42.dll. Wine ships
# neither, so the installer's own regsvr32 of those controls silently fails and the
# app later raises "class not registered" / OLE errors. Both runtimes come from
# Microsoft redistributables (VB6 SP6 runtime, VC6 redist) that we extract with
# cabextract; afterwards the controls are registered again.
install_vb6_mfc_runtimes() {
  local sysdir; sysdir="$(prefix_sysdir)"
  if [ ! -f "$sysdir/msvbvm60.dll" ] || [ ! -f "$sysdir/mfc42.dll" ]; then
    say "Installing VB6 runtime (msvbvm60) and MFC42 for the bundled ActiveX controls"
    local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/vbmfc.XXXXXX")"
    mkdir -p "$tmp/vc6" "$tmp/vc6/in" "$tmp/vb6" "$tmp/vb6/in"
    cabextract -q -d "$tmp/vc6" "$VC6_PACKAGE"
    cabextract -q -d "$tmp/vc6/in" "$tmp/vc6/vcredist.exe"
    cabextract -q -d "$tmp/vb6" "$VB6_PACKAGE"
    cabextract -q -d "$tmp/vb6/in" "$tmp/vb6/vbrun60sp6.exe"
    [ -f "$tmp/vc6/in/mfc42.dll" ]     || die "mfc42.dll not found inside $VC6_PACKAGE"
    [ -f "$tmp/vb6/in/msvbvm60.dll" ]  || die "msvbvm60.dll not found inside $VB6_PACKAGE"
    # Only these three files. The rest of both packages (msvcrt, oleaut32, ...) must
    # NOT be copied: Wine's own versions are newer and required.
    cp -f "$tmp/vc6/in/mfc42.dll" "$tmp/vc6/in/mfc42u.dll" "$tmp/vb6/in/msvbvm60.dll" "$sysdir/"
    rm -rf "$tmp"
  else
    ok "VB6/MFC42 runtimes already present"
  fi
  say "Registering ActiveX controls that depend on those runtimes"
  local regsvr; regsvr="$(prefix_regsvr32)"
  local pf; pf="$(prefix_pf32_win)"
  local o
  # ct* = DBI calendar controls (MFC42-based): none of them registered during the NSIS
  # install because MFC42 was missing then; ChadoSpellText/IEPostWrapper needed VB6.
  for o in 'C:\windows\system32\msvbvm60.dll' \
           'C:\windows\system32\ChadoSpellText.ocx' \
           'C:\windows\system32\ctalarm.ocx' \
           'C:\windows\system32\ctDate.ocx' \
           'C:\windows\system32\ctDays.ocx' \
           'C:\windows\system32\ctMonth.ocx' \
           "$pf\\Common Files\\Platypus\\IEPostWrapper.ocx"; do
    wine_run "$regsvr" /s "$o" || warn "regsvr32 failed for $o (see $LOG_DIR/install.log)"
  done
  wine_wait
  ok "Runtimes installed and controls registered"
}


# ---- 3c. Microsoft ADO (from MDAC) ---------------------------------------------------
# Platypus's error logger writes its log through ADODB.Stream (WriteText in "write line"
# mode, UTF-8). Wine's own ADO only supports one write mode and one charset, so every
# error the app tries to log turns into "OLE error code 0x80004001: Not implemented".
# MDAC 2.8's ADO is installed instead (the same thing winetricks' mdac28 does).
install_native_ado() {
  local sysdir; sysdir="$(prefix_sysdir)"
  local ado; ado="$PREFIX/drive_c/$(prefix_pf32_win | sed 's|^C:\\||; s|\\|/|g')/Common Files/System/ADO"
  mkdir -p "$ado"
  if [ -f "$ado/msado15.dll" ] && ! grep -q "Wine builtin DLL" "$ado/msado15.dll" 2>/dev/null; then
    ok "Microsoft ADO already installed"
  else
    say "Installing Microsoft ADO 2.8 (ADODB.Stream is needed by the Platypus error logger)"
    local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/ado.XXXXXX")"
    cabextract -q -d "$tmp" -F mdacxpak.cab "$MDAC_PACKAGE"
    mkdir -p "$tmp/x"; cabextract -q -d "$tmp/x" "$tmp/mdacxpak.cab"
    local f
    for f in msado15.dll msadrh15.dll msador15.dll msado20.tlb msado21.tlb msado25.tlb msado26.tlb msado27.tlb; do
      cp -f "$tmp/x/$f" "$ado/$f"
    done
    cp -f "$tmp/x/msdart.dll" "$sysdir/msdart.dll"
    rm -rf "$tmp"
  fi
  local regf="$PREFIX/drive_c/windows/temp/ado.reg"
  cat >"$regf" <<'REG'
Windows Registry Editor Version 5.00

[HKEY_CURRENT_USER\Software\Wine\DllOverrides]
"msado15"="native,builtin"
"*msado15"="native,builtin"
REG
  wine_run "$(prefix_regedit)" /S 'C:\windows\temp\ado.reg'
  wine_run "$(prefix_regsvr32)" /s "$(prefix_pf32_win)\\Common Files\\System\\ADO\\msado15.dll" || warn "regsvr32 msado15.dll failed (see $LOG_DIR/install.log)"
  wine_wait
  ok "Microsoft ADO installed and registered"
}

# ---- 3d. Patched oleaut32 (Wine COM bugs that break the e-mail list) -----------------
# Two defects in Wine's oleaut32 ITypeInfo::Invoke break the mscomctl ListView used by
# the "Handle E-mails" screen:
#   * a VT_NULL passed for an object parameter is rejected (clearing a selection:
#     oListView.SelectedItem = .NULL.)  -> rows cannot be selected;
#   * an indexed get-only property assigned a value is not written through to the
#     returned object's default member (repopulating subitems: ListSubItems(n) = text)
#     -> deleting a message raises "OLE error 0x8002000e".
# Windows' oleaut32 handles both. vendor/wine-patches/ holds a source patch against
# Wine 11.0 plus the rebuilt 32-bit builtin oleaut32.dll.
#
# Delivery: oleaut32 is loaded during Wine's own start-up, before a prefix's DLL
# overrides are consulted, so a per-prefix "native" override cannot win for it. The fix
# therefore REPLACES the builtin oleaut32.dll inside the Wine installation (a .orig
# backup is kept and recorded for uninstall). Safe for the private Wine this installer
# sets up; for a shared system Wine it needs write access (apt/dnf ran with sudo, so it
# succeeds) and a Wine upgrade may revert it -- just re-run this installer. The patch is
# additive (it only makes currently-failing calls succeed), so other Wine apps are fine.
OLEAUT32_BACKUPS=""
install_patched_oleaut32() {
  case "$WINE_VERSION" in
    wine-11.*) ;;
    *) warn "Wine is $WINE_VERSION; the patched oleaut32 was built for Wine 11.x and is NOT installed."
       warn "The 'Handle E-mails' screen may misbehave (see docs/how-it-works.md)."; return 0 ;;
  esac
  say "Installing patched oleaut32 into the prefix (object-argument + default-property-put fixes)"
  # Wine 11 loads a builtin from the copy wineboot placed in the prefix's system32/syswow64,
  # so only the prefix is touched - the Wine installation itself is never modified and other
  # prefixes on the machine are unaffected. Keep a payload copy: wineboot re-creates the
  # prefix copy after a Wine upgrade and the launcher then restores ours from it.
  local sysdir; sysdir="$(prefix_sysdir)"
  mkdir -p "$PLATYPUS_HOME/payload"; cp -f "$OLEAUT32_PATCHED" "$PLATYPUS_HOME/payload/oleaut32.dll"
  if cp -f "$OLEAUT32_PATCHED" "$sysdir/oleaut32.dll.wine-platypus.new" 2>/dev/null && mv -f "$sysdir/oleaut32.dll.wine-platypus.new" "$sysdir/oleaut32.dll"; then
    ok "Patched oleaut32 placed in the prefix ($sysdir)"
  else
    rm -f "$sysdir/oleaut32.dll.wine-platypus.new" 2>/dev/null || true
    warn "Could not place patched oleaut32 in $sysdir - the e-mail list will misbehave"
  fi
  # older versions of this installer also replaced the file inside the Wine installation;
  # put the original back if such a backup exists next to it.
  local wine_root t; wine_root="$(cd "$WINE_BIN_DIR/.." && pwd)"
  while IFS= read -r -d '' t; do
    [ -f "${t%.wine-platypus.orig}" ] && mv -f "$t" "${t%.wine-platypus.orig}" 2>/dev/null && ok "Restored original $(basename "${t%.wine-platypus.orig}") in the Wine installation"
  done < <(find "$wine_root" -type f -name 'oleaut32.dll.wine-platypus.orig' -print0 2>/dev/null)
  wine_run reg delete 'HKCU\Software\Wine\DllOverrides' /v oleaut32 /f >/dev/null 2>&1 || true
}

# ---- 3e. COM registration pass + registry repairs --------------------------------------
# The NSIS installer's own regsvr32 calls partly fail or misfire under Wine:
#   * controls whose runtimes were missing at install time (fixed above) never registered;
#   * one Crystal control is registered under a Windows 8.3 path (C:\PROG~FBU\...) that
#     Wine cannot resolve;
#   * Platypus' COM library registers most version-independent ProgIDs with only a CurVer
#     pointer; Windows' CLSIDFromProgID follows it, Wine's does not, so
#     CREATEOBJECT("Platypus.COM.TCPSocket") failed ("Class definition ... not found").
# vendor/tools/fixprogids.exe (source in tools/src) repairs the last two inside the prefix.
register_com_servers() {
  say "Registering COM servers and repairing registrations"
  local regsvr; regsvr="$(prefix_regsvr32)"; local pf; pf="$(prefix_pf32_win)"; local o
  for o in "$pf\\Common Files\\System\\ADO\\msador15.dll" \
           "$pf\\Common Files\\System\\ADO\\msadrh15.dll" \
           "$pf\\Business Objects\\Common\\3.5\\crystalreportviewers115\\ActiveXControls\\CRViewer.dll" \
           "$pf\\Business Objects\\Common\\3.5\\crystalreportviewers115\\ActiveXControls\\CSelExpt.ocx" \
           "$pf\\Business Objects\\Common\\3.5\\crystalreportviewers115\\ActiveXControls\\sviewhlp.dll" \
           "$pf\\Business Objects\\Common\\3.5\\crystalreportviewers115\\ActiveXControls\\swebrs.dll"; do
    wine_run "$regsvr" /s "$o" || warn "regsvr32 failed for $o"
  done
  # NOTE: Platypus.COM.dll is deliberately NOT re-registered (its DllRegisterServer hangs
  # under Wine); the NSIS installer already wrote its classes. fixprogids completes them.
  cp -f "$TOOLS_DIR/fixprogids.exe" "$PREFIX/drive_c/windows/temp/fixprogids.exe"
  WINEPREFIX="$PREFIX" WINEDEBUG=-all "$WINE" 'C:\windows\temp\fixprogids.exe' >>"$LOG_DIR/install.log" 2>&1 \
    && ok "ProgID / short-path repairs applied (see install.log)" || warn "fixprogids failed (see $LOG_DIR/install.log)"
  wine_wait
}

# ---- 6. self-check ------------------------------------------------------------------------
# Instantiates every COM class Platypus is known to create (vendor/tools/comcheck-list.txt),
# each in its own process. Proves "all the required DLLs are there" on this machine
# without opening the application. LICENSED = licensed ActiveX control whose class
# factory loaded, which is the expected result outside a form.
self_check() {
  say "Self-check: instantiating every COM class Platypus uses"
  local tmp="$PREFIX/drive_c/windows/temp"
  cp -f "$TOOLS_DIR/comcheck.exe" "$tmp/comcheck.exe"; cp -f "$TOOLS_DIR/comcheck-list.txt" "$tmp/comcheck-list.txt"
  rm -f "$tmp/comcheck-report.txt"
  (cd "$tmp" && WINEPREFIX="$PREFIX" WINEDEBUG=-all "$WINE" comcheck.exe comcheck-list.txt comcheck-report.txt >/dev/null 2>&1) || true
  wine_wait
  cp -f "$tmp/comcheck-report.txt" "$LOG_DIR/comcheck-report.txt" 2>/dev/null || { warn "self-check produced no report"; return 0; }
  local summary; summary="$(grep '^SUMMARY' "$LOG_DIR/comcheck-report.txt")"
  local bad; bad="$(grep -vE '^(OK|LICENSED|SUMMARY)' "$LOG_DIR/comcheck-report.txt" || true)"
  if [ -z "$bad" ]; then
    ok "Self-check passed: ${summary#SUMMARY }"
  else
    warn "Self-check found problems (${summary#SUMMARY }):"; printf '%s\n' "$bad" | sed 's/^/    /' >&2
    warn "Full report: $LOG_DIR/comcheck-report.txt"
  fi
}


# ---- 5. look and feel --------------------------------------------------------------------
# Wine draws every control itself (comctl32/uxtheme); nothing comes from GTK/Qt or the
# desktop theme, and macOS renders identically (only the outer window frame is native).
# Two built-in looks exist: Wine's "Light" visual style (default since Wine 10) and the
# unthemed Windows Classic look. Windows Vista/7 "Aero" is not available in Wine.
set_theme() {
  case "$PLATYPUS_THEME" in
    classic)
      say "Look: Windows Classic (visual styles off)"
      wine_run reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\ThemeManager' /v ThemeActive /t REG_SZ /d 0 /f
      wine_run reg delete 'HKCU\Software\Microsoft\Windows\CurrentVersion\ThemeManager' /v DllName /f || true ;;
    light|*)
      say "Look: Wine 'Light' visual style"
      wine_run reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\ThemeManager' /v DllName /t REG_SZ /d 'C:\windows\resources\themes\light\light.msstyles' /f
      wine_run reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\ThemeManager' /v ColorName /t REG_SZ /d Blue /f
      wine_run reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\ThemeManager' /v SizeName /t REG_SZ /d NormalSize /f
      wine_run reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\ThemeManager' /v ThemeActive /t REG_SZ /d 1 /f ;;
  esac
  wine_wait; ok "Theme set ($PLATYPUS_THEME)"
}


# ---- 3f. Microsoft MSXML 3 / 4 / 6 ------------------------------------------------------
# Platypus parses the User Manager (provisioning daemon) replies and builds its API
# documents with MSXML2.DOMDocument (selectNodes().item(), createElement, ...), and FoxPro's
# own XMLToCursor/XMLAdapter call MSXML too. Wine's msxml3 does not implement
# IXMLDOMNodeList.item() through late binding (DISP_E_MEMBERNOTFOUND), which breaks that
# parser (Linux: OLE error; macOS: access violation in parse_response_xml). Microsoft's
# redistributables are installed instead - the same on both platforms - and registered.
install_native_msxml() {
  local sysdir; sysdir="$(prefix_sysdir)"
  if [ -f "$sysdir/msxml3.dll" ] && ! head -c 200 "$sysdir/msxml3.dll" | grep -aq "Wine builtin DLL" \
     && [ -f "$sysdir/msxml4.dll" ] && [ -f "$sysdir/msxml6.dll" ] && ! head -c 200 "$sysdir/msxml6.dll" | grep -aq "Wine builtin DLL"; then
    ok "Microsoft MSXML 3/4/6 already installed"
  else
    say "Installing Microsoft MSXML 3.0 SP7, 4.0 SP3 and 6.0 SP2"
    local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/msxml.XXXXXX")"
    mkdir -p "$tmp/3" "$tmp/4" "$tmp/6a" "$tmp/6"
    cabextract -q -d "$tmp/3" "$MSXML3_PACKAGE"
    cabextract -q -d "$tmp/4" "$MSXML4_PACKAGE"
    cabextract -q -d "$tmp/6a" "$MSXML6_PACKAGE"; cabextract -q -d "$tmp/6" "$tmp/6a/msxml6.msi"
    # the cab entries carry a component GUID suffix; the 86F857F6 msxml6 files are the 32-bit ones
    local f
    for f in msxml3.dll msxml3r.dll msxml3a.dll; do cp -f "$tmp/3/$f".C8C0673E_50E5_4AC4_817B_C0E4C4466990 "$sysdir/$f"; done
    for f in msxml4.dll msxml4r.dll; do cp -f "$tmp/4/$f".246EB7AD_459A_4FA8_83D1_41A46D7634B7 "$sysdir/$f"; done
    for f in msxml6.dll msxml6r.dll; do cp -f "$tmp/6/$f".86F857F6_A743_463D_B2FE_98CB5F727E09 "$sysdir/$f"; done
    if [ "$PREFIX_ARCH" = "win64" ]; then   # 64-bit copies for completeness (the app itself is 32-bit)
      for f in msxml6.dll msxml6r.dll; do cp -f "$tmp/6/$f".1ECC0691_D2EB_4A33_9CBF_5487E5CB17DB "$PREFIX/drive_c/windows/system32/$f"; done
    fi
    rm -rf "$tmp"
  fi
  local regf="$PREFIX/drive_c/windows/temp/msxml.reg"
  cat >"$regf" <<'REG'
Windows Registry Editor Version 5.00

[HKEY_CURRENT_USER\Software\Wine\DllOverrides]
"msxml3"="native,builtin"
"msxml4"="native,builtin"
"msxml6"="native,builtin"
REG
  wine_run "$(prefix_regedit)" /S 'C:\windows\temp\msxml.reg'
  local regsvr; regsvr="$(prefix_regsvr32)"
  for f in msxml3.dll msxml4.dll msxml6.dll; do
    WINEPREFIX="$PREFIX" WINEDEBUG=-all WINEDLLOVERRIDES="msxml3,msxml4,msxml6=n,b" "$WINE" "$regsvr" /s "C:\\windows\\system32\\$f" >>"$LOG_DIR/install.log" 2>&1 || warn "regsvr32 $f failed"
  done
  wine_wait
  ok "Microsoft MSXML installed and registered"
}

# ---- 3b. DSN ------------------------------------------------------------------
configure_dsn() {
  say "Configuring ODBC data source \"$PLATYPUS_DSN_NAME\" -> server $PLATYPUS_SQL_SERVER, database $PLATYPUS_SQL_DATABASE"
  local regf="$PREFIX/drive_c/windows/temp/odbc-dsn.reg"
  cat >"$regf" <<REG
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\\SOFTWARE\\ODBC\\ODBC.INI\\ODBC Data Sources]
"$PLATYPUS_DSN_NAME"="SQL Server"

[HKEY_LOCAL_MACHINE\\SOFTWARE\\ODBC\\ODBC.INI\\$PLATYPUS_DSN_NAME]
"Driver"="C:\\\\windows\\\\system32\\\\SQLSRV32.dll"
"Description"="Platypus Billing System"
"Server"="$PLATYPUS_SQL_SERVER"
"Database"="$PLATYPUS_SQL_DATABASE"
"Trusted_Connection"="No"

[-HKEY_CURRENT_USER\\Software\\ODBC\\ODBC.INI\\$PLATYPUS_DSN_NAME]
REG
  wine_run "$(prefix_regedit)" /S 'C:\windows\temp\odbc-dsn.reg'
  wine_wait
  ok "DSN configured"
}

# ---- launcher script (shared) -------------------------------------------------
write_launcher_script() {  # write_launcher_script <path>
  local out="$1"
  cat >"$out" <<LAUNCH
#!/usr/bin/env bash
# Platypus Billing launcher (generated by wine-platypus)
export WINEPREFIX="$PREFIX"
# Quiet by default. PLATYPUS_DEBUG=1 turns on the Wine messages that name unimplemented
# calls (fixme lines, COM type-library dispatch, WMI) - attach the log to a support ticket.
if [ "\${PLATYPUS_DEBUG:-0}" = "1" ]; then
  export WINEDEBUG="\${WINEDEBUG:--hid,+typelib,+wbemdisp,+wbemprox}"
else
  export WINEDEBUG="\${WINEDEBUG:-fixme-all,err-hid}"   # err-hid: silence harmless input-device chatter
fi
# ODBC overrides are ALSO set in the registry; the env form is needed because Wine
# ignores registry DLL overrides on the very first launch of a freshly installed prefix.
export WINEDLLOVERRIDES="odbc32,odbccp32,odbccu32,odbccr32,odbcbcp,msado15,msxml3,msxml4,msxml6=n,b;winemenubuilder.exe=d"
WINE="$WINE"
APP_DIR="$APP_DIR"
LOG="$LOG_DIR/platypus.log"
mkdir -p "\$(dirname "\$LOG")"; : >"\$LOG"   # fresh log for this run
if [ ! -x "\$WINE" ]; then
  msg="Wine was not found at \$WINE. Re-run the wine-platypus installer."
  command -v zenity >/dev/null 2>&1 && zenity --error --text="\$msg" || echo "\$msg" >&2
  exit 1
fi
# Single-instance lock for THIS install (portable: no /proc, no pgrep - a pid file whose
# process must still be alive). If Platypus is already running, just exit quietly.
LOCK="$PLATYPUS_HOME/run.lock"
if [ -f "\$LOCK/pid" ] && kill -0 "\$(cat "\$LOCK/pid" 2>/dev/null)" 2>/dev/null; then
  echo "Platypus is already running." >&2; exit 0
fi
rm -rf "\$LOCK"; mkdir -p "\$LOCK"; echo \$\$ >"\$LOCK/pid"
# Nothing of ours is running: stop any server a previous session left behind (it would
# keep serving the DLL images it already mapped, so updated DLLs would not be loaded).
# wineserver -k acts on this prefix only.
"$WINESERVER" -k >/dev/null 2>&1 || true
# Self-heal: a Wine upgrade makes wineboot re-create the prefix's builtin oleaut32.dll,
# losing our two fixes. Put ours back (only for the Wine 11.x it was built against).
PAYLOAD="$PLATYPUS_HOME/payload/oleaut32.dll"; SYSDLL="$(prefix_sysdir)/oleaut32.dll"
if [ -f "\$PAYLOAD" ] && ! cmp -s "\$PAYLOAD" "\$SYSDLL"; then
  case "\$("\$WINE" --version 2>/dev/null)" in
    wine-11.*) cp -f "\$PAYLOAD" "\$SYSDLL.new" && mv -f "\$SYSDLL.new" "\$SYSDLL" && echo "restored patched oleaut32 after a Wine update" >>"\$LOG" ;;
    *) echo "WARNING: Wine is no longer 11.x; patched oleaut32 not applied (re-run the installer / see docs)" >>"\$LOG" ;;
  esac
fi
cd "\$APP_DIR" || exit 1
# When Platypus exits, shut the (dedicated) prefix down so no helper process (dllhost.exe
# COM surrogate, services.exe, explorer.exe) lingers. Done by a detached watcher because
# we exec Wine below: exec keeps ONE process identity, which on macOS means one Dock tile
# (a spawned child would get its own tile next to this launcher's).
( me=\$\$; while kill -0 "\$me" 2>/dev/null; do sleep 2; done; "$WINESERVER" -k >/dev/null 2>&1; rm -rf "\$LOCK" ) >/dev/null 2>&1 &
exec "\$WINE" plat.exe "\$@" >>"\$LOG" 2>&1
LAUNCH
  chmod +x "$out"
}

# ---- 4a. Linux desktop integration -----------------------------------------------
install_launcher_linux() {
  say "Installing launcher and application-menu entry"
  write_launcher_script "$BIN_DIR/platypus"
  mkdir -p "$HOME/.local/bin"; ln -sf "$BIN_DIR/platypus" "$HOME/.local/bin/platypus"
  if [ -n "${ICON_PNG:-}" ] && [ -f "$ICON_PNG" ]; then
    mkdir -p "$HOME/.local/share/icons/hicolor/256x256/apps"
    cp -f "$ICON_PNG" "$HOME/.local/share/icons/hicolor/256x256/apps/platypus-billing.png"
  fi
  mkdir -p "$HOME/.local/share/applications"
  sed "s|@EXEC@|$BIN_DIR/platypus|g" "$ASSETS_DIR/platypus.desktop" >"$HOME/.local/share/applications/platypus-billing.desktop"
  chmod +x "$HOME/.local/share/applications/platypus-billing.desktop"
  need_cmd update-desktop-database && update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
  need_cmd gtk-update-icon-cache && gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
  need_cmd xdg-desktop-menu && xdg-desktop-menu forceupdate >/dev/null 2>&1 || true
  ok "Menu entry: \"Platypus Billing\"   command: platypus"
}

# ---- 4b. macOS app bundle ----------------------------------------------------------
# macOS identifies a GUI process by the bundle its *executable* lives in. A shell script
# that merely spawns/execs /Applications/Wine Stable.app/.../wine therefore produces two
# Dock tiles (ours bouncing forever, Wine's with the real windows). Fix: reach the Wine
# loader THROUGH our bundle - Contents/MacOS/ holds symlinks to every Wine binary and
# Contents/lib + Contents/share mirror Wine's layout, so the process' bundle is ours, and
# the launcher execs that path. Verified at install time; if the symlinked loader cannot
# start we fall back to the real path and mark the bundle LSUIElement so it never bounces.
install_launcher_macos() {
  say "Creating Platypus Billing.app in ~/Applications"
  local app="$HOME/Applications/Platypus Billing.app"
  rm -rf "$app"; mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  local wine_root; wine_root="$(cd "$WINE_BIN_DIR/.." && pwd)"
  local f
  for f in "$WINE_BIN_DIR"/*; do ln -sfn "$f" "$app/Contents/MacOS/$(basename "$f")"; done
  [ -d "$wine_root/lib" ]   && ln -sfn "$wine_root/lib"   "$app/Contents/lib"
  [ -d "$wine_root/lib64" ] && ln -sfn "$wine_root/lib64" "$app/Contents/lib64"
  [ -d "$wine_root/share" ] && ln -sfn "$wine_root/share" "$app/Contents/share"
  local bundled_wine="$app/Contents/MacOS/wine" ui_element=false launcher_wine="$WINE"
  if [ -x "$bundled_wine" ] && WINEPREFIX="$PREFIX" WINEDEBUG=-all "$bundled_wine" --version >/dev/null 2>&1; then
    launcher_wine="$bundled_wine"; ok "Wine loader reachable through the bundle (single Dock tile)"
  else
    ui_element=true; warn "Wine could not be started through the bundle; using $WINE directly (Wine will show its own Dock tile)"
  fi
  WINE="$launcher_wine" write_launcher_script "$app/Contents/MacOS/platypus"
  cp -f "$app/Contents/MacOS/platypus" "$BIN_DIR/platypus"
  # icon: build an .icns from the extracted 256x256 PNG (sips scales the other sizes)
  local iconset; iconset="$(mktemp -d "${TMPDIR:-/tmp}/platypus.XXXXXX")/platypus.iconset"; mkdir -p "$iconset"
  if [ -n "${ICON_PNG:-}" ] && [ -f "$ICON_PNG" ]; then
    cp "$ICON_PNG" "$iconset/icon_256x256.png"; cp "$ICON_PNG" "$iconset/icon_128x128@2x.png"
    sips -z 128 128 "$ICON_PNG" --out "$iconset/icon_128x128.png" >/dev/null 2>&1 || true
    sips -z 64 64 "$ICON_PNG" --out "$iconset/icon_32x32@2x.png" >/dev/null 2>&1 || true
    sips -z 32 32 "$ICON_PNG" --out "$iconset/icon_32x32.png" >/dev/null 2>&1 || true
    sips -z 32 32 "$ICON_PNG" --out "$iconset/icon_16x16@2x.png" >/dev/null 2>&1 || true
    sips -z 16 16 "$ICON_PNG" --out "$iconset/icon_16x16.png" >/dev/null 2>&1 || true
    iconutil -c icns "$iconset" -o "$app/Contents/Resources/platypus.icns" 2>/dev/null \
      || sips -s format icns "$ICON_PNG" --out "$app/Contents/Resources/platypus.icns" >/dev/null 2>&1 || true
  fi
  rm -rf "$(dirname "$iconset")"
  cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Platypus Billing</string>
  <key>CFBundleDisplayName</key><string>Platypus Billing</string>
  <key>CFBundleIdentifier</key><string>com.tucows.platypus.wine</string>
  <key>CFBundleVersion</key><string>7.0.2292</string>
  <key>CFBundleShortVersionString</key><string>7.0.2292</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>platypus</string>
  <key>CFBundleIconFile</key><string>platypus</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><${ui_element}/>
</dict>
</plist>
PLIST
  touch "$app"
  ok "Created $app"
}

# ---- final message -----------------------------------------------------------------
print_first_run_help() {
  cat <<TXT

${C_B}Platypus is installed.${C_0}

First launch (one time only) - the app asks which database to use:
  1. In the "Choose Connection" window click ${C_B}New${C_0}.
  2. Display Name : anything you like (e.g. "MyISP")
     Data Source  : ${C_B}$PLATYPUS_DSN_NAME${C_0}   (already points at $PLATYPUS_SQL_SERVER / $PLATYPUS_SQL_DATABASE)
     Username     : the SQL Server login your Platypus administrator gave you
     Password     : its password
  3. Click ${C_B}Test${C_0} - you should see "Connection successful".
  4. Click ${C_B}OK${C_0}, tick "Set as default connection", click OK, then log in with
     your normal Platypus staff username and password.

Logs (attach these when asking for help): $LOG_DIR/
TXT
}
