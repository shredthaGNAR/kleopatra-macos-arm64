#!/bin/bash
set -euo pipefail
APP="${1:-/Applications/Kleopatra 26.08.1.app}"
HERE="$(cd "$(dirname "$0")" && pwd)"
[[ "$(uname -m)" == arm64 ]] || { echo "Requires Apple Silicon"; exit 1; }
[[ -x /opt/homebrew/bin/gpgconf ]] || { echo "Run: brew install gnupg pinentry-mac"; exit 1; }
[[ -f "$APP/Contents/MacOS/gpgconf" && -f "$APP/Contents/MacOS/kleopatra" ]] || { echo "App not found: $APP"; exit 1; }
BACKUP="$(mktemp -d "$HOME/Library/Application Support/kleopatra-backup.XXXXXX")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
for rel in Contents/MacOS/gpgconf Contents/MacOS/kleopatra Contents/_CodeSignature/CodeResources; do
 mkdir -p "$BACKUP/$(dirname "$rel")"
 cp -p "$APP/$rel" "$BACKUP/$rel"
done
restore() {
 for rel in Contents/MacOS/gpgconf Contents/MacOS/kleopatra Contents/_CodeSignature/CodeResources; do
  cp -p "$BACKUP/$rel" "$APP/$rel"
 done
 echo "Repair failed; restored original files. Backup: $BACKUP" >&2
}
/usr/bin/clang -arch arm64 -O2 "$HERE/gpgconf-forward.c" -o "$TMP/gpgconf"
/usr/bin/codesign --force --sign - "$TMP/gpgconf"
trap 'restore' ERR
cp -p "$TMP/gpgconf" "$APP/Contents/MacOS/gpgconf"
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify "$APP"
trap - ERR
echo "Repair complete. Restart Kleopatra and run Tools > Perform Self-Test."
echo "Backup: $BACKUP"
