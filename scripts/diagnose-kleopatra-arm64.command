#!/bin/bash
set -u
CRAFT_ROOT="${CRAFT_ROOT:-$HOME/CraftRoot-Kleopatra}"

echo "=== Kleopatra Apple-Silicon diagnostics ==="
echo "Date: $(date)"
echo "macOS: $(sw_vers -productVersion 2>/dev/null || true)"
echo "Machine: $(uname -m)"
echo "Rosetta translated: $(sysctl -in sysctl.proc_translated 2>/dev/null || echo 0)"
echo "Homebrew: $(command -v brew 2>/dev/null || echo missing)"
if command -v brew >/dev/null 2>&1; then
  echo "Brew prefix: $(brew --prefix)"
  brew list --versions gnupg pinentry-mac python 2>/dev/null || true
fi

echo
echo "GnuPG:"
gpg --version 2>/dev/null | head -3 || echo "gpg not found"

echo
echo "Craft root: $CRAFT_ROOT"
if [[ -f "$CRAFT_ROOT/etc/CraftSettings.ini" ]]; then
  grep -Ei '^[[:space:]]*ABI[[:space:]]*=' "$CRAFT_ROOT/etc/CraftSettings.ini" || true
fi
if [[ -f "$CRAFT_ROOT/craft/craftenv.sh" ]]; then
  # Craft expects optional variables to be readable with nounset disabled.
  export CRAFT_PYTHON_BIN="${CRAFT_PYTHON_BIN:-/opt/homebrew/bin/python3}"
  set +u
  # shellcheck disable=SC1090
  source "$CRAFT_ROOT/craft/craftenv.sh"
  set -u
  echo
echo "Installed Craft packages related to Kleopatra:"
  craft --print-installed 2>/dev/null | grep -Ei 'kleopatra|libkleo|mimetree|gpgme|qgpgme|kmime' || true
fi

echo
echo "Kleopatra executables:"
find "$CRAFT_ROOT" /Applications "$HOME/Applications" -type f -path '*/Kleopatra*.app/Contents/MacOS/kleopatra' -print 2>/dev/null | while IFS= read -r f; do
  echo "-- $f"
  /usr/bin/file "$f"
  /usr/bin/lipo -archs "$f" 2>/dev/null || true
done

echo
echo "Recent build logs:"
ls -1t "$HOME/Library/Logs/KleopatraCraft"/*.log 2>/dev/null | head -5 || echo "No logs yet."
