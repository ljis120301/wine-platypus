#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ---------------------------------------------------------------------------
# wine-platypus :: Linux installer
#
# Works out of the box on Debian/Ubuntu, Fedora/RHEL, Arch, and openSUSE (and
# nearly all of their derivatives - Mint, Pop!_OS, Rocky, Manjaro, Tumbleweed,
# etc.); any other distro gets a package-install hint instead of installing.
#
#   ./install.sh                        # interactive, sensible defaults
#   ./install.sh --yes                  # accept every default, ask nothing
#   ./install.sh --server sql.example.com --database Platypus
#   ./install.sh --dsn MyDSN --theme classic
#   ./install.sh --fresh                # wipe the existing Wine prefix and start over
#   ./install.sh --wine /path/to/wine   # use a specific Wine binary (portable builds)
#   ./install.sh --system-wine          # use the distro's Wine instead of the pinned one
#   ./install.sh --skip-packages        # don't touch system packages at all
#   ./install.sh --verify               # re-run just the self-check, install nothing
#
# Everything lands in ~/.local/share/platypus - nothing outside your home is
# touched except the distro packages this script asks apt/dnf/pacman/zypper to
# install (skip that too with --skip-packages).
# ---------------------------------------------------------------------------
set -Eeuo pipefail
cd "$(dirname "$0")"
REPO_DIR="$(pwd)"
. "$REPO_DIR/lib/common.sh"
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND" "${BASH_SOURCE[0]}"' ERR
trap on_interrupt INT

PLATYPUS_HOME="${PLATYPUS_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/platypus}"
FRESH=0; LAUNCH=ask; SKIP_PKGS=0; VERIFY_ONLY=0; WINE_MODE=portable
WINE_MODE_SET=0; THEME_SET=0

usage() { sed -n '3,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)        PLATYPUS_NONINTERACTIVE=1 ;;
    --fresh)         FRESH=1 ;;
    --server)        PLATYPUS_SQL_SERVER="$2"; shift ;;
    --database)      PLATYPUS_SQL_DATABASE="$2"; shift ;;
    --dsn)           PLATYPUS_DSN_NAME="$2"; shift ;;
    --wine)          PLATYPUS_WINE="$2"; WINE_MODE_SET=1; shift ;;
    --theme)         PLATYPUS_THEME="$2"; THEME_SET=1; shift ;;   # light (default) | classic
    --no-launch)     LAUNCH=no ;;
    --skip-packages) SKIP_PKGS=1 ;;
    --system-wine)   WINE_MODE=system; WINE_MODE_SET=1 ;;   # use the distro's wine instead of the pinned portable one
    --portable)      WINE_MODE=portable; WINE_MODE_SET=1 ;;
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
  # Matched against "$ID $ID_LIKE", so a well-behaved derivative is usually already
  # caught by the generic debian/fedora/rhel/arch token even if its own name isn't
  # listed below; the explicit names are belt-and-suspenders for the ones that
  # don't set ID_LIKE correctly.
  case " $DISTRO_ID $DISTRO_LIKE " in
    # Debian/Ubuntu family (apt)
    *" debian "*|*" ubuntu "*|*" linuxmint "*|*" lmde "*|*" pop "*|*" neon "*| \
    *" elementary "*|*" zorin "*|*" kali "*|*" parrot "*|*" mx "*|*" deepin "*| \
    *" devuan "*|*" raspbian "*|*" peppermint "*|*" antix "*)
      DISTRO_FAMILY=debian ;;
    # Fedora/RHEL family (dnf)
    *" fedora "*|*" rhel "*|*" centos "*|*" nobara "*|*" rocky "*|*" almalinux "*| \
    *" alma "*|*" ol "*|*" oracle "*|*" amzn "*|*" bazzite "*|*" ultramarine "*)
      DISTRO_FAMILY=fedora ;;
    # Arch family (pacman)
    *" arch "*|*" cachyos "*|*" manjaro "*|*" endeavouros "*|*" garuda "*|*" artix "*| \
    *" arcolinux "*|*" rebornos "*|*" blackarch "*|*" parabola "*|*" archcraft "*)
      DISTRO_FAMILY=arch ;;
    # openSUSE / SUSE Linux Enterprise (zypper)
    *" suse "*|*" opensuse "*|*" sles "*|*" sled "*)
      DISTRO_FAMILY=suse ;;
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
    suse)
      say "Installing packages with zypper (sudo will ask for your password)"
      if [ "$need_wine" = 1 ]; then sudo_run zypper --non-interactive install wine cabextract; else sudo_run zypper --non-interactive install cabextract; fi ;;
    *)
      local pkgs="cabextract"; [ "$need_wine" = 1 ] && pkgs="wine cabextract"
      local mgr="" hint=""
      if need_cmd zypper;       then mgr=zypper; hint="sudo zypper install $pkgs"
      elif need_cmd apk;        then mgr=apk;     hint="sudo apk add $pkgs"
      elif need_cmd xbps-install; then mgr=xbps;  hint="sudo xbps-install -Sy $pkgs"
      elif need_cmd emerge;     then mgr=portage; hint="sudo emerge $pkgs"
      elif need_cmd eopkg;      then mgr=eopkg;   hint="sudo eopkg install $pkgs"
      elif need_cmd slackpkg;   then mgr=slackpkg; hint="sudo slackpkg install $pkgs"
      elif need_cmd nix-env;    then mgr=nix;     hint="nix-shell -p ${pkgs// / -p }"
      fi
      warn "Distro not recognized automatically (ID=${DISTRO_ID:-unknown})."
      if [ -n "$hint" ]; then warn "Detected $mgr - install the missing package(s) yourself:  $hint"
      else warn "Install these package(s) with whatever tool this system uses:  $pkgs"; fi
      [ "$need_wine" = 1 ] || warn "(only cabextract is needed here - the default install downloads its own private Wine, it does not use the system one)"
      die "Then re-run this installer with --skip-packages" ;;
  esac
  hash -r
  need_cmd cabextract || die "cabextract still not found"
  [ "$need_wine" = 1 ] && { need_cmd wine || die "wine still not found"; }
  return 0
}

# ---- go ----------------------------------------------------------------------------
banner "Linux installer"
init_paths
check_disk_space
check_vendor_files
if [ "$VERIFY_ONLY" = "1" ]; then
  load_config; find_wine || die "Wine not found"; [ -f "$PREFIX/system.reg" ] || die "No Platypus prefix at $PREFIX - run the installer first"
  [ -d "$PREFIX/drive_c/windows/syswow64" ] && PREFIX_ARCH=win64 || PREFIX_ARCH=win32
  self_check; exit 0
fi
require_sql_settings

# Ask about the two "which build/look do you want" choices only when the user
# didn't already answer them with a flag, and only when there's a real
# terminal to ask on (menu() falls back to option 1 - today's defaults -
# otherwise, e.g. under --yes or a piped/CI run).
if [ "$WINE_MODE_SET" = "0" ]; then
  menu WINE_CHOICE "How should Platypus run Wine?" \
    "Pinned portable Wine - recommended (a known-good build, isolated from the rest of the system, ~70 MB download)" \
    "This system's installed Wine package"
  [ "$WINE_CHOICE" = "2" ] && WINE_MODE=system
fi
if [ "$THEME_SET" = "0" ]; then
  menu THEME_CHOICE "Look and feel:" \
    "Light - Wine's modern default (recommended)" \
    "Classic - the plain Windows 2000 look"
  [ "$THEME_CHOICE" = "2" ] && PLATYPUS_THEME=classic || PLATYPUS_THEME=light
fi

# Wine: pinned portable by default (identical everywhere, immune to distro upgrades);
# --wine PATH or --system-wine to use another one. cabextract is always needed.
if [ -n "$PLATYPUS_WINE" ]; then WINE_MODE=explicit
elif [ "$WINE_MODE" = "portable" ]; then ensure_portable_wine
fi
ensure_packages
find_wine >/dev/null || die "Wine not found"

say "Database connection"
ask PLATYPUS_SQL_SERVER   "SQL Server host or IP (ask your Platypus administrator)" "$PLATYPUS_SQL_SERVER"
ask PLATYPUS_SQL_DATABASE "Platypus database name" "$PLATYPUS_SQL_DATABASE"

say "Ready to install"
case "$WINE_MODE" in
  system)   wine_desc="this system's package ($WINE)" ;;
  explicit) wine_desc="$WINE (--wine)" ;;
  *)        wine_desc="pinned portable build ($WINE_VERSION)" ;;
esac
ok "Wine     : $wine_desc"
ok "Theme    : $PLATYPUS_THEME"
ok "Server   : $PLATYPUS_SQL_SERVER"
ok "Database : $PLATYPUS_SQL_DATABASE"

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
