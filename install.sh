#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# wine-platypus :: Linux installer (Ubuntu / Debian / Linux Mint / Pop!_OS / Fedora)
#
#   ./install.sh                # interactive, sensible defaults
#   ./install.sh --yes          # accept all defaults, no questions
#   ./install.sh --server sql.example.com --database Platypus
#   ./install.sh --fresh        # throw away the existing Wine prefix and start over
#   ./install.sh --wine /path/to/wine   # use a specific Wine binary (portable builds)
#
# Everything lands in ~/.local/share/platypus - nothing outside your home is
# touched except the distro packages this script asks apt/dnf to install.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"
REPO_DIR="$(pwd)"
. "$REPO_DIR/lib/common.sh"

PLATYPUS_HOME="${PLATYPUS_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/platypus}"
FRESH=0; LAUNCH=ask; SKIP_PKGS=0; VERIFY_ONLY=0; WINE_MODE=portable

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
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
    --system-wine)   WINE_MODE=system ;;   # use the distro's wine instead of the pinned portable one
    --portable)      WINE_MODE=portable ;;
    --verify)        VERIFY_ONLY=1 ;;
    -h|--help)       usage ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac; shift
done

# ---- distro packages -------------------------------------------------------------
detect_distro() {
  DISTRO_ID=""; DISTRO_LIKE=""; DISTRO_CODENAME=""
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO_ID="${ID:-}"; DISTRO_LIKE="${ID_LIKE:-}"
    DISTRO_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  fi
  DISTRO_FAMILY=other
  case " $DISTRO_ID $DISTRO_LIKE " in
    *" debian "*|*" ubuntu "*|*" linuxmint "*|*" pop "*|*" neon "*|*" elementary "*|*" zorin "*|*" kali "*) DISTRO_FAMILY=debian ;;
    *" fedora "*|*" rhel "*|*" centos "*|*" nobara "*)                                            DISTRO_FAMILY=fedora ;;
    *" arch "*|*" cachyos "*|*" manjaro "*|*" endeavouros "*|*" garuda "*|*" artix "*)             DISTRO_FAMILY=arch ;;
  esac
}

# WineHQ's official apt repository for the running Debian/Ubuntu release (only used with
# --system-wine). Returns non-zero if WineHQ has no repo for this codename.
add_winehq_repo_debian() {
  local base="https://dl.winehq.org/wine-builds"
  local dist; case " $DISTRO_ID $DISTRO_LIKE " in *" ubuntu "*) dist=ubuntu ;; *) dist=debian ;; esac
  [ -n "$DISTRO_CODENAME" ] || return 1
  local src="$base/$dist/dists/$DISTRO_CODENAME/winehq-$DISTRO_CODENAME.sources"
  curl -fsIL "$src" >/dev/null 2>&1 || return 1
  sudo_run mkdir -pm755 /etc/apt/keyrings
  curl -fsSL "$base/winehq.key" | sudo_run gpg --dearmor --yes -o /etc/apt/keyrings/winehq-archive.key || return 1
  sudo_run curl -fsSL -o "/etc/apt/sources.list.d/winehq-$DISTRO_CODENAME.sources" "$src" || return 1
  return 0
}

sudo_run() {
  if [ "$(id -u)" = "0" ]; then "$@"; else sudo "$@"; fi
}



ensure_packages() {
  # cabextract is always required; Wine only when using the distro package (--system-wine)
  local need_wine=0; [ "$WINE_MODE" = "system" ] && ! need_cmd wine && need_wine=1
  need_cmd cabextract || need_cab=1; : "${need_cab:=0}"
  [ "$need_wine" = 0 ] && [ "$need_cab" = 0 ] && return 0
  [ "$SKIP_PKGS" = "1" ] && die "Missing packages (wine=$need_wine cabextract=$need_cab) and --skip-packages given"
  detect_distro
  case "$DISTRO_FAMILY" in
    debian)
      say "Installing packages with apt (sudo will ask for your password)"
      if [ "$need_wine" = 1 ]; then
        sudo_run dpkg --add-architecture i386 || true
        if add_winehq_repo_debian; then sudo_run apt-get update -y; sudo_run apt-get install -y --install-recommends winehq-stable cabextract
        else sudo_run apt-get update -y; sudo_run apt-get install -y wine wine32:i386 cabextract 2>/dev/null || sudo_run apt-get install -y wine cabextract; fi
      else sudo_run apt-get install -y cabextract; fi ;;
    fedora)
      say "Installing packages with dnf (sudo will ask for your password)"
      if [ "$need_wine" = 1 ]; then sudo_run dnf install -y wine cabextract; else sudo_run dnf install -y cabextract; fi ;;
    arch)
      say "Installing packages with pacman (sudo will ask for your password)"
      if [ "$need_wine" = 1 ]; then sudo_run pacman -S --needed --noconfirm wine cabextract; else sudo_run pacman -S --needed --noconfirm cabextract; fi ;;
    *) die "Unsupported distro ($DISTRO_ID). Install 'cabextract' (and 'wine' for --system-wine) yourself and re-run with --skip-packages." ;;
  esac
  hash -r
  need_cmd cabextract || die "cabextract still not found"
  [ "$need_wine" = 1 ] && { need_cmd wine || die "wine still not found"; }
  return 0
}

# ---- go ----------------------------------------------------------------------------
say "wine-platypus Linux installer"
init_paths
check_vendor_files
if [ "$VERIFY_ONLY" = "1" ]; then
  load_config; find_wine || die "Wine not found"; [ -f "$PREFIX/system.reg" ] || die "No Platypus prefix at $PREFIX - run the installer first"
  [ -d "$PREFIX/drive_c/windows/syswow64" ] && PREFIX_ARCH=win64 || PREFIX_ARCH=win32
  self_check; exit 0
fi
require_sql_settings
# Wine: pinned portable by default (identical everywhere, immune to distro upgrades);
# --wine PATH or --system-wine to use another one. cabextract is always needed.
if [ -n "$PLATYPUS_WINE" ]; then WINE_MODE=explicit
elif [ "$WINE_MODE" = "portable" ]; then ensure_portable_wine
fi
ensure_packages
find_wine >/dev/null || die "Wine not found"
ask PLATYPUS_SQL_SERVER   "SQL Server host or IP (ask your Platypus administrator)" "$PLATYPUS_SQL_SERVER"
ask PLATYPUS_SQL_DATABASE "Platypus database name" "$PLATYPUS_SQL_DATABASE"

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
install_launcher_linux
save_config
self_check
print_first_run_help

if [ "$LAUNCH" != "no" ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
  if confirm "Launch Platypus now?"; then
    nohup "$BIN_DIR/platypus" >/dev/null 2>&1 &
    ok "Platypus is starting (it may take ~10 s to show the splash screen)"
  fi
fi
