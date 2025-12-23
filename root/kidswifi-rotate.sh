#!/bin/sh
set -eu

OUT_SVG="/www/admin/qr.svg"
META="/root/kidswifi-meta"
PASSFILE="/root/kidswifi-current.txt"

PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 14)"

SECTIONS=""
for s in $(uci show wireless | sed -n 's/^wireless\.\([^.=]*\)=wifi-iface.*/\1/p'); do
  NET="$(uci -q get wireless."$s".network || true)"
  echo " $NET " | grep -q " kids " && SECTIONS="${SECTIONS}${SECTIONS:+ }$s"
done

[ -n "$SECTIONS" ] || { echo "ERROR: No wifi-iface attached to network 'kids'." >&2; exit 1; }

FIRST="$(echo "$SECTIONS" | awk '{print $1}')"
SSID="$(uci -q get wireless."$FIRST".ssid || true)"
[ -n "${SSID:-}" ] || { echo "ERROR: Could not read SSID from kids wifi-iface." >&2; exit 1; }

for s in $SECTIONS; do
  uci set wireless."$s".key="$PASS"
  uci set wireless."$s".disabled='0'
done

uci commit wireless
wifi reload

QR="WIFI:T:WPA;S:${SSID};P:${PASS};;"
qrencode -t SVG -o "$OUT_SVG" "$QR"

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf "SSID=%s\nPASS=%s\nTS=%s\n" "$SSID" "$PASS" "$TS" > "$META"
chmod 600 "$META"

printf "SSID: %s\nPASS: %s\n" "$SSID" "$PASS" > "$PASSFILE"
chmod 600 "$PASSFILE"

echo "OK: rotated SSID=$SSID at $TS"
