#!/bin/bash
# Native Apple-Silicon Kleopatra builder/installer using KDE Craft.
# Target: Kleopatra 26.08.1 / Qt 6 / KDE Frameworks 6 / macOS arm64.

set -euo pipefail
trap 'status=$?; printf "\nBuild stopped (exit %s). No completed installation was confirmed.\nLog: %s\n" "$status" "${LOG_FILE:-not created}" >&2; exit "$status"' ERR

KLEO_VERSION="26.08.1"
CRAFT_ROOT="${CRAFT_ROOT:-$HOME/CraftRoot-Kleopatra}"
PACKAGE="kde/pim/kleopatra"
LOG_DIR="$HOME/Library/Logs/KleopatraCraft"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/build-$STAMP.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

info() { printf '\n==> %s\n' "$*"; }
warn() { printf '\nWARNING: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\nLog: %s\n' "$*" "$LOG_FILE" >&2; exit 1; }

info "Kleopatra $KLEO_VERSION native Apple-Silicon installer"
echo "Log: $LOG_FILE"

# ---- Native macOS / Apple Silicon checks ----
[[ "$(uname -s)" == "Darwin" ]] || die "This installer is macOS-only."
[[ "$(uname -m)" == "arm64" ]] || die "This must run natively on Apple Silicon. 'uname -m' returned: $(uname -m)"

translated="$(sysctl -in sysctl.proc_translated 2>/dev/null || echo 0)"
[[ "$translated" != "1" ]] || die "Terminal is running under Rosetta. Open a native arm64 Terminal/iTerm window and run this installer again."

info "Architecture verified: arm64 (not Rosetta)"

# ---- Xcode command line tools ----
if ! xcode-select -p >/dev/null 2>&1; then
  warn "Apple Command Line Tools are required. macOS will open the installer now."
  xcode-select --install || true
  echo
  echo "After Command Line Tools finish installing, run this installer again."
  exit 2
fi

# ---- Homebrew prerequisites for the GnuPG engine used by Kleopatra ----
if ! command -v brew >/dev/null 2>&1; then
  die "Homebrew is required for GnuPG/pinentry-mac. Install Homebrew from https://brew.sh and run this installer again."
fi

BREW_PREFIX="$(brew --prefix)"
if [[ "$BREW_PREFIX" != "/opt/homebrew" ]]; then
  warn "Homebrew prefix is '$BREW_PREFIX', not the normal Apple-Silicon prefix /opt/homebrew. Continuing because this shell itself is native arm64."
fi

info "Installing/updating runtime prerequisites"
brew update
for pkg in python gnupg pinentry-mac; do
  if brew list --versions "$pkg" >/dev/null 2>&1; then
    echo "$pkg is already installed: $(brew list --versions "$pkg" | head -1)"
  else
    brew install "$pkg"
  fi
done

PYTHON_BIN="$(command -v python3 || true)"
[[ -n "$PYTHON_BIN" ]] || die "python3 was not found after installing Homebrew Python."

# ---- Configure pinentry without clobbering the rest of gpg-agent.conf ----
info "Configuring GnuPG to use pinentry-mac"
GNUPG_HOME="$HOME/.gnupg"
AGENT_CONF="$GNUPG_HOME/gpg-agent.conf"
PINENTRY_BIN="$(brew --prefix pinentry-mac)/bin/pinentry-mac"
mkdir -p "$GNUPG_HOME"
chmod 700 "$GNUPG_HOME"
touch "$AGENT_CONF"
chmod 600 "$AGENT_CONF"

if grep -q '^[[:space:]]*pinentry-program[[:space:]]' "$AGENT_CONF"; then
  /usr/bin/sed -i '' "s|^[[:space:]]*pinentry-program[[:space:]].*$|pinentry-program $PINENTRY_BIN|" "$AGENT_CONF"
else
  printf '\npinentry-program %s\n' "$PINENTRY_BIN" >> "$AGENT_CONF"
fi

gpgconf --kill gpg-agent >/dev/null 2>&1 || true

# ---- Install/reuse KDE Craft ----
if [[ -e "$CRAFT_ROOT" && ! -f "$CRAFT_ROOT/craft/craftenv.sh" ]]; then
  die "'$CRAFT_ROOT' exists but is not a complete Craft installation. Rename/remove that directory or set CRAFT_ROOT to another empty path."
fi

if [[ ! -f "$CRAFT_ROOT/craft/craftenv.sh" ]]; then
  info "Bootstrapping KDE Craft for native macOS arm64"
  TMPDIR_CRAFT="$(mktemp -d "${TMPDIR:-/tmp}/kleopatra-craft.XXXXXX")"
  trap 'rm -rf "${TMPDIR_CRAFT:-}"' EXIT
  curl --fail --location --proto '=https' --tlsv1.2 \
    https://raw.githubusercontent.com/KDE/craft/master/setup/CraftBootstrap.py \
    -o "$TMPDIR_CRAFT/CraftBootstrap.py"
  "$PYTHON_BIN" "$TMPDIR_CRAFT/CraftBootstrap.py" --prefix "$CRAFT_ROOT" --use-defaults
else
  info "Reusing existing Craft installation at $CRAFT_ROOT"
fi

# Craft expects optional variables to be readable with nounset disabled.
export CRAFT_PYTHON_BIN="${CRAFT_PYTHON_BIN:-/opt/homebrew/bin/python3}"
set +u
# shellcheck disable=SC1090
source "$CRAFT_ROOT/craft/craftenv.sh"
set -u

CRAFT_SETTINGS="$CRAFT_ROOT/etc/CraftSettings.ini"
if [[ -f "$CRAFT_SETTINGS" ]]; then
  ABI_LINE="$(grep -Ei '^[[:space:]]*ABI[[:space:]]*=' "$CRAFT_SETTINGS" | tail -1 || true)"
  echo "Craft $ABI_LINE"
  echo "$ABI_LINE" | grep -Eqi 'macos.*arm64|arm64.*macos' || die "Craft is not configured for macOS arm64. Use a fresh CRAFT_ROOT and rerun."
fi

# ---- Refresh official KDE build recipes ----
info "Updating KDE Craft and official KDE blueprints"
craft -i craft
craft -i craft-blueprints-kde

# Pin the PIM pieces to the same KDE Gear release as Kleopatra.
info "Selecting Kleopatra/Libkleo/MimeTreeParser $KLEO_VERSION"
craft --set version="$KLEO_VERSION" kde/pim/kleopatra
craft --set version="$KLEO_VERSION" kde/pim/libkleo
craft --set version="$KLEO_VERSION" kde/pim/mimetreeparser

# libvpx 1.16 auto-detection does not recognize Darwin 27.
# Its Darwin 25 target selects native arm64 macOS flags with the current SDK.
# Keep this override scoped to libvpx; do not change the global Craft ABI.
LIBVPX_OPTION="libs/libvpx.args=--target=arm64-darwin25-gcc"

# MimeTreeParser 26.08.1 requires KIO and KService when Qt Quick is present.
# Its current Craft recipe omits these dependencies; install KIO first.
# KIO's recipe also installs KService.
info "Installing KIO before MimeTreeParser"
craft --options "[CodeSigning]Enabled=False" --options "$LIBVPX_OPTION" kde/frameworks/tier3/kio

# Dependencies may be satisfied from KDE's *native macOS-arm64* Craft cache.
# Kleopatra itself is explicitly rebuilt from source with --no-cache.
info "Installing the native arm64 Qt6/KF6 dependency stack"
craft --install-deps --options "[CodeSigning]Enabled=False" --options "$LIBVPX_OPTION" "$PACKAGE"

info "Building Kleopatra $KLEO_VERSION from source for Apple Silicon"
craft --no-cache --options "[CodeSigning]Enabled=False" --options "$LIBVPX_OPTION" "$PACKAGE"

# ---- Verify the executable really is arm64 ----
info "Verifying the built executable architecture"
KLEO_BIN="$(find "$CRAFT_ROOT" -type f \( \
    -path '*/kleopatra.app/Contents/MacOS/kleopatra' -o \
    -path '*/bin/kleopatra' \
  \) -print 2>/dev/null | head -n 1 || true)"

if [[ -n "$KLEO_BIN" ]]; then
  echo "Executable: $KLEO_BIN"
  /usr/bin/file "$KLEO_BIN"
  if /usr/bin/lipo -archs "$KLEO_BIN" >/tmp/kleopatra-archs.$$ 2>/dev/null; then
    ARCHS="$(cat /tmp/kleopatra-archs.$$)"
    rm -f /tmp/kleopatra-archs.$$
    echo "Mach-O architectures: $ARCHS"
    echo "$ARCHS" | grep -qw arm64 || die "The resulting Kleopatra executable is not arm64."
  fi
else
  warn "Could not locate the merged Kleopatra executable for an early architecture check; packaging will continue."
fi

# ---- Build a standalone macOS DMG ----
info "Packaging Kleopatra as a standalone macOS DMG"
craft --package --options "[CodeSigning]Enabled=False" --options "$LIBVPX_OPTION" "$PACKAGE"

DMG="$(find "$CRAFT_ROOT/tmp" -type f -iname '*kleopatra*.dmg' -print 2>/dev/null | while IFS= read -r f; do printf '%s\t%s\n' "$(stat -f '%m' "$f")" "$f"; done | sort -nr | head -1 | cut -f2- || true)"
if [[ -z "$DMG" ]]; then
  DMG="$(find "$CRAFT_ROOT/tmp" -type f -iname '*.dmg' -print 2>/dev/null | while IFS= read -r f; do printf '%s\t%s\n' "$(stat -f '%m' "$f")" "$f"; done | sort -nr | head -1 | cut -f2- || true)"
fi

if [[ -z "$DMG" ]]; then
  warn "The source build succeeded but Craft did not leave a DMG under $CRAFT_ROOT/tmp."
  echo "You can inspect the installed Craft build under: $CRAFT_ROOT"
  echo "Log: $LOG_FILE"
  exit 3
fi

OUTPUT_DIR="$HOME/Desktop/Kleopatra-ARM64-$KLEO_VERSION"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DMG="$OUTPUT_DIR/$(basename "$DMG")"
cp -f "$DMG" "$OUTPUT_DMG"

info "Verifying the packaged app and installing alongside your old Kleopatra"
MOUNT_POINT=""
ATTACH_OUTPUT="$(hdiutil attach "$OUTPUT_DMG" -nobrowse -readonly 2>&1)" || {
  warn "Could not mount the DMG automatically. Opening it instead."
  open "$OUTPUT_DMG"
  echo "DMG: $OUTPUT_DMG"
  exit 0
}
echo "$ATTACH_OUTPUT"
MOUNT_POINT="$(echo "$ATTACH_OUTPUT" | awk -F '\t' '/\/Volumes\// {print $NF; exit}')"

if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
  trap '[[ -n "${MOUNT_POINT:-}" ]] && hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true; rm -rf "${TMPDIR_CRAFT:-}"' EXIT
  APP_SOURCE="$(find "$MOUNT_POINT" -maxdepth 4 -type d -iname 'kleopatra*.app' -print | head -1 || true)"
  if [[ -n "$APP_SOURCE" ]]; then
    PACKAGED_BIN="$APP_SOURCE/Contents/MacOS/kleopatra"
    if [[ -f "$PACKAGED_BIN" ]]; then
      echo "Packaged executable: $PACKAGED_BIN"
      /usr/bin/file "$PACKAGED_BIN"
      PACKAGED_ARCHS="$(/usr/bin/lipo -archs "$PACKAGED_BIN" 2>/dev/null || true)"
      echo "Packaged Mach-O architectures: ${PACKAGED_ARCHS:-unknown}"
      [[ -z "$PACKAGED_ARCHS" || "$PACKAGED_ARCHS" == *arm64* ]] || die "Packaged application is not arm64."
    fi

    DEST_APP="/Applications/Kleopatra $KLEO_VERSION.app"
    if /usr/bin/ditto "$APP_SOURCE" "$DEST_APP" 2>/dev/null; then
      echo "Installed: $DEST_APP"
    else
      USER_APPS="$HOME/Applications"
      mkdir -p "$USER_APPS"
      DEST_APP="$USER_APPS/Kleopatra $KLEO_VERSION.app"
      /usr/bin/ditto "$APP_SOURCE" "$DEST_APP"
      echo "Installed for this user: $DEST_APP"
    fi

    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
    MOUNT_POINT=""

    info "Build/install complete"
    echo "New app: $DEST_APP"
    echo "DMG copy: $OUTPUT_DMG"
    echo "Craft root: $CRAFT_ROOT"
    echo "Build log: $LOG_FILE"
    echo
    echo "Your existing Kleopatra.app was NOT overwritten, so you can keep the old build as a fallback."
    echo "The new local source build is installed with its version in the app name."
    open "$DEST_APP"
  else
    warn "No Kleopatra .app was found inside the DMG. The DMG will be opened so you can inspect it manually."
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
    MOUNT_POINT=""
    open "$OUTPUT_DMG"
  fi
else
  warn "Could not determine the mounted DMG path. Opening the DMG instead."
  open "$OUTPUT_DMG"
fi
