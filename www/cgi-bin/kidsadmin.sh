#!/bin/sh
set -eu

# Fritz LAN guard (only allow requests from 192.168.178.0/24)
REMOTE="${REMOTE_ADDR:-}"
case "$REMOTE" in
  192.168.178.*) : ;;
  127.0.0.1) : ;;   # allow local tests
  *)
    echo "Status: 403 Forbidden"
    echo "Content-Type: application/json"
    echo "Cache-Control: no-store"
    echo ""
    echo '{"ok":false,"error":"forbidden"}'
    exit 0
    ;;
esac

PIN_EXPECTED="$(cat /root/kidswifi-pin 2>/dev/null || true)"
META="/root/kidswifi-meta"

json_escape() { printf "%s" "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

read_post() {
  LEN="${CONTENT_LENGTH:-0}"
  if [ "$LEN" -gt 0 ]; then
    dd bs=1 count="$LEN" 2>/dev/null || true
  else
    true
  fi
}

get_qp() {
  printf "%s" "${QUERY_STRING:-}" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n1
}

get_form() {
  printf "%s" "$POST" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n1
}

send_json() {
  echo "Content-Type: application/json"
  echo "Cache-Control: no-store"
  echo ""
  echo "$1"
}

status_json() {
  SSID=""; TS=""
  if [ -f "$META" ]; then
    SSID="$(sed -n 's/^SSID=//p' "$META" | head -n1 || true)"
    TS="$(sed -n 's/^TS=//p' "$META" | head -n1 || true)"
  fi
  V="$(date -u +%s)"
  send_json "{\"ok\":true,\"ssid\":\"$(json_escape "$SSID")\",\"last_rotated\":\"$(json_escape "$TS")\",\"qr_url\":\"/admin/qr.svg?v=$V\"}"
}

require_pin() {
  PIN="$1"
  if [ -z "${PIN_EXPECTED:-}" ] || [ -z "${PIN:-}" ] || [ "$PIN" != "$PIN_EXPECTED" ]; then
    send_json '{"ok":false,"error":"bad_pin"}'
    exit 0
  fi
}

METHOD="${REQUEST_METHOD:-GET}"

if [ "$METHOD" = "GET" ]; then
  ACTION="$(get_qp action)"
  [ "$ACTION" = "status" ] || ACTION="status"
  status_json
  exit 0
fi

POST="$(read_post)"
ACTION="$(get_form action)"
PIN="$(get_form pin)"

case "$ACTION" in
  rotate)
    require_pin "$PIN"
    /root/kidswifi-rotate.sh >/tmp/kidswifi-rotate-now.log 2>&1 || {
      send_json '{"ok":false,"error":"rotate_failed"}'
      exit 0
    }
    status_json
    ;;
  reveal)
    require_pin "$PIN"
    PASS=""; SSID=""; TS=""
    if [ -f "$META" ]; then
      PASS="$(sed -n 's/^PASS=//p' "$META" | head -n1 || true)"
      SSID="$(sed -n 's/^SSID=//p' "$META" | head -n1 || true)"
      TS="$(sed -n 's/^TS=//p' "$META" | head -n1 || true)"
    fi
    send_json "{\"ok\":true,\"ssid\":\"$(json_escape "$SSID")\",\"last_rotated\":\"$(json_escape "$TS")\",\"password\":\"$(json_escape "$PASS")\"}"
    ;;
  *)
    send_json '{"ok":false,"error":"bad_action"}'
    ;;
esac
