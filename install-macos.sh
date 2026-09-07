#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# wine-platypus :: macOS installer (Apple Silicon and Intel, macOS 12+)
#
#   ./install-macos.sh                 # interactive, sensible defaults
#   ./install-macos.sh --yes           # accept all defaults, no questions
#   ./install-macos.sh --server sql.example.com --database Platypus
#   ./install-macos.sh --fresh         # throw away the existing Wine prefix and start over
#
# Installs Wine (WineHQ stable via Homebrew) and cabextract, then builds a
# self-contained Wine prefix in ~/Library/Application Support/Platypus and a
# "Platypus Billing.app" in ~/Applications (shows up in Launchpad/Spotlight).
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"
REPO_DIR="$(pwd)"
. "$REPO_DIR/lib/common.sh"

PLATYPUS_HOME="${PLATYPUS_HOME:-$HOME/Library/Application Support/Platypus}"
FRESH=0; LAUNCH=ask; SKIP_PKGS=0; VERIFY_ONLY=0

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)        PLATYPUS_NONINTERACTIVE=1 ;;
    --fresh)         FRESH=1 ;;
    --server)        PLATYPUS_SQL_SERVER="$2"; shift ;;
    --database)      PLATYPUS_SQL_DATABASE="$2"; shift ;;
    --dsn)           PLATYPUS_DSN_NAME="$2"; shift ;;
    --wine)          PLATYPUS_WINE="$2"; shift ;;
    --theme)         PLATYPUS_THEME="$2"; shift ;;   # light (default) | classic
    --no-launch)     LAUNCH=no ;;
    --skip-packages) SKIP_PKGS=1 ;;
    --verify)        VERIFY_ONLY=1 ;;
    -h|--help)       usage ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac; shift
done

[ "$(uname -s)" = "Darwin" ] || die "This script is for macOS. On Linux run ./install.sh"

brew_bin() {
  if need_cmd brew; then command -v brew; return; fi
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && { echo "$b"; return; }; done
  return 1
}

ensure_packages() {
  if find_wine 2>/dev/null && need_cmd cabextract; then return; fi
  [ "$SKIP_PKGS" = "1" ] && die "Wine and/or cabextract missing and --skip-packages given"
  local brew; brew="$(brew_bin)" || die "Homebrew is required. Install it from https://brew.sh then re-run this script."
  if [ "$(uname -m)" = "arm64" ] && ! /usr/bin/pgrep -q oahd; then
    say "Installing Rosetta 2 (needed to run Wine on Apple Silicon)"
    softwareupdate --install-rosetta --agree-to-license || warn "Rosetta install returned non-zero; continuing"
  fi
  say "Installing Wine (WineHQ stable) and cabextract with Homebrew"
  "$brew" install cabextract
  need_cmd wine || "$brew" install --cask --no-quarantine wine-stable
  hash -r
  find_wine || die "Wine still not found after Homebrew install (try: brew reinstall --cask wine-stable)"
  need_cmd cabextract || die "cabextract still not found"
}

say "wine-platypus macOS installer"
init_paths
check_vendor_files
if [ "$VERIFY_ONLY" = "1" ]; then
  load_config; find_wine || die "Wine not found"; [ -f "$PREFIX/system.reg" ] || die "No Platypus prefix at $PREFIX - run the installer first"
  [ -d "$PREFIX/drive_c/windows/syswow64" ] && PREFIX_ARCH=win64 || PREFIX_ARCH=win32
  self_check; exit 0
fi
require_sql_settings
ensure_packages
find_wine >/dev/null || die "Wine not found"
ask PLATYPUS_SQL_SERVER   "SQL Server host or IP (ask your Platypus administrator)" "$PLATYPUS_SQL_SERVER"
ask PLATYPUS_SQL_DATABASE "Platypus database name" "$PLATYPUS_SQL_DATABASE"

# macOS Wine is 64-bit only (new WoW64); a win32 prefix is impossible there.
PLATYPUS_WINEARCH="${PLATYPUS_WINEARCH:-win64}"
create_prefix "$FRESH"
install_platypus
extract_app_icon
install_sqlserver_odbc
install_vb6_mfc_runtimes
install_native_ado
install_native_msxml
install_patched_oleaut32
register_com_servers
configure_dsn
set_theme
install_launcher_macos
save_config
self_check
print_first_run_help

if [ "$LAUNCH" != "no" ] && confirm "Launch Platypus now?"; then
  open "$HOME/Applications/Platypus Billing.app" || "$BIN_DIR/platypus" &
  ok "Platypus is starting (first start takes ~10-20 s)"
fi
