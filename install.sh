#!/bin/sh
set -eu

REPO_RAW_BASE="https://raw.githubusercontent.com/pabumake/openwrt-kidsnetwork/main"
SETUP_PATH="scripts/openwrt-setup.sh"

if [ -f "./$SETUP_PATH" ]; then
  sh "./$SETUP_PATH"
  exit 0
fi

TMP="${TMPDIR:-/tmp}/openwrt-kidsnetwork-setup.sh"

if command -v wget >/dev/null 2>&1; then
  wget -O "$TMP" "$REPO_RAW_BASE/$SETUP_PATH"
elif command -v curl >/dev/null 2>&1; then
  curl -fsSL "$REPO_RAW_BASE/$SETUP_PATH" -o "$TMP"
else
  echo "ERROR: wget or curl required to download setup script." >&2
  exit 1
fi

chmod +x "$TMP"
sh "$TMP"
