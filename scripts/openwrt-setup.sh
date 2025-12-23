#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (ssh root@openwrt)." >&2
  exit 1
fi

say() { printf '%s\n' "$*" >&2; }

ask() {
  _var="$1"
  _prompt="$2"
  _default="${3-}"
  while :; do
    if [ -n "$_default" ]; then
      printf "%s [%s]: " "$_prompt" "$_default" >&2
    else
      printf "%s: " "$_prompt" >&2
    fi
    read -r _input
    if [ -z "$_input" ]; then
      _input="$_default"
    fi
    if [ -n "$_input" ]; then
      eval "$_var=\$_input"
      return 0
    fi
  done
}

ask_yn() {
  _var="$1"
  _prompt="$2"
  _default="$3"
  while :; do
    if [ "$_default" = "y" ]; then
      printf "%s [Y/n]: " "$_prompt" >&2
    else
      printf "%s [y/N]: " "$_prompt" >&2
    fi
    read -r _input
    [ -n "$_input" ] || _input="$_default"
    case "$_input" in
      y|Y) eval "$_var=y"; return 0 ;;
      n|N) eval "$_var=n"; return 0 ;;
    esac
  done
}

RADIOS_AVAILABLE="$(uci show wireless 2>/dev/null | sed -n 's/^wireless\.\([^.=]*\)=wifi-device.*/\1/p' | tr '\n' ' ')"
RADIOS_AVAILABLE="$(echo "$RADIOS_AVAILABLE" | awk '{$1=$1;print}')"

say "OpenWrt KidsNetwork setup"
ask_yn CONT "Continue with setup" n
[ "$CONT" = "y" ] || exit 0

ask_yn INSTALL_PKGS "Install required packages (luci luci-ssl qrencode)" y
if [ "$INSTALL_PKGS" = "y" ]; then
  opkg update
  opkg install luci luci-ssl qrencode
fi

ask KIDS_SSID "Kids Wi-Fi SSID" "Area51"
ask WIFI_ENCRYPTION "Wi-Fi encryption (e.g. sae-mixed, psk2)" "sae-mixed"
ask WIFI_KEY "Initial Wi-Fi password (leave blank to auto-generate)" ""
if [ -z "$WIFI_KEY" ]; then
  WIFI_KEY="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 14)"
  say "Generated initial Wi-Fi password: $WIFI_KEY"
fi
ask ISOLATE "Enable client isolation (1=yes, 0=no)" "1"

ask KIDS_IP "Kids router IP" "192.168.23.1"
ask KIDS_NETMASK "Kids netmask" "255.255.255.0"
ask DHCP_START "DHCP start" "100"
ask DHCP_LIMIT "DHCP limit" "150"
ask DHCP_LEASE "DHCP lease time" "4h"

DEFAULT_RADIOS="$RADIOS_AVAILABLE"
while :; do
  ask RADIO_LIST "Wi-Fi radios to use (space-separated)" "$DEFAULT_RADIOS"
  ok="y"
  for r in $RADIO_LIST; do
    if ! uci -q get wireless."$r".type >/dev/null; then
      say "Radio '$r' not found."
      ok="n"
    fi
  done
  [ "$ok" = "y" ] && break
done

ask ADMIN_PIN "Admin panel PIN (numbers recommended)" ""
ask ADMIN_ALLOW_PREFIX "Allowed admin LAN prefix (e.g. 192.168.178.)" "192.168.178."
case "$ADMIN_ALLOW_PREFIX" in
  *.) : ;;
  *) ADMIN_ALLOW_PREFIX="${ADMIN_ALLOW_PREFIX}." ;;
esac

ask_yn WAN_ADMIN "Enable admin panel access from upstream LAN via WAN firewall rule" n
if [ "$WAN_ADMIN" = "y" ]; then
  ask ADMIN_PC_IP "Admin PC IP on upstream LAN" ""
  ask_yn WAN_SSH "Also allow SSH from that PC" n
fi

ask_yn SET_WAN_DHCP "Ensure WAN uses DHCP" y
ask_yn RUN_ROTATE "Run first password rotation now" y

say ""
say "Summary:"
say "  SSID: $KIDS_SSID"
say "  Kids IP: $KIDS_IP/$KIDS_NETMASK"
say "  DHCP: start $DHCP_START, limit $DHCP_LIMIT, lease $DHCP_LEASE"
say "  Radios: $RADIO_LIST"
say "  Admin LAN prefix: ${ADMIN_ALLOW_PREFIX}*"
if [ "$WAN_ADMIN" = "y" ]; then
  say "  Admin PC IP: $ADMIN_PC_IP"
  say "  Allow SSH: $WAN_SSH"
fi
ask_yn APPLY "Apply these changes" y
[ "$APPLY" = "y" ] || exit 0

uci -q delete network.br_kids
uci -q delete network.kids
uci set network.br_kids=device
uci set network.br_kids.name='br-kids'
uci set network.br_kids.type='bridge'

uci set network.kids=interface
uci set network.kids.proto='static'
uci set network.kids.device='br-kids'
uci set network.kids.ipaddr="$KIDS_IP"
uci set network.kids.netmask="$KIDS_NETMASK"

uci -q delete dhcp.kids
uci set dhcp.kids=dhcp
uci set dhcp.kids.interface='kids'
uci set dhcp.kids.start="$DHCP_START"
uci set dhcp.kids.limit="$DHCP_LIMIT"
uci set dhcp.kids.leasetime="$DHCP_LEASE"

uci -q delete firewall.kids
uci set firewall.kids=zone
uci set firewall.kids.name='kids'
uci set firewall.kids.input='REJECT'
uci set firewall.kids.output='ACCEPT'
uci set firewall.kids.forward='REJECT'
uci add_list firewall.kids.network='kids'

uci -q delete firewall.kids_wan
uci set firewall.kids_wan=forwarding
uci set firewall.kids_wan.src='kids'
uci set firewall.kids_wan.dest='wan'

uci -q delete firewall.allow_dhcp_kids
uci set firewall.allow_dhcp_kids=rule
uci set firewall.allow_dhcp_kids.name='Allow-DHCP-Kids'
uci set firewall.allow_dhcp_kids.src='kids'
uci set firewall.allow_dhcp_kids.proto='udp'
uci set firewall.allow_dhcp_kids.dest_port='67-68'
uci set firewall.allow_dhcp_kids.target='ACCEPT'

uci -q delete firewall.allow_dns_kids
uci set firewall.allow_dns_kids=rule
uci set firewall.allow_dns_kids.name='Allow-DNS-Kids'
uci set firewall.allow_dns_kids.src='kids'
uci set firewall.allow_dns_kids.proto='tcp udp'
uci set firewall.allow_dns_kids.dest_port='53'
uci set firewall.allow_dns_kids.target='ACCEPT'

for r in $RADIO_LIST; do
  section="kids_${r}"
  uci -q delete wireless."$section"
  uci set wireless."$section"=wifi-iface
  uci set wireless."$section".device="$r"
  uci set wireless."$section".mode='ap'
  uci set wireless."$section".ssid="$KIDS_SSID"
  uci set wireless."$section".encryption="$WIFI_ENCRYPTION"
  uci set wireless."$section".key="$WIFI_KEY"
  uci set wireless."$section".network='kids'
  uci set wireless."$section".isolate="$ISOLATE"
  uci set wireless."$section".disabled='0'
done

uci set uhttpd.main.docroot='/www'
uci set uhttpd.main.cgi_prefix='/cgi-bin'
uci -q delete uhttpd.main.interpreter
uci add_list uhttpd.main.interpreter='.sh=/bin/sh'

if [ "$WAN_ADMIN" = "y" ]; then
  uci -q delete uhttpd.main.listen_http
  uci add_list uhttpd.main.listen_http='0.0.0.0:80'
  uci -q delete uhttpd.main.listen_https
  uci add_list uhttpd.main.listen_https='0.0.0.0:443'

  uci -q delete firewall.allow_admin_from_pc
  uci set firewall.allow_admin_from_pc=rule
  uci set firewall.allow_admin_from_pc.name='Allow-Admin-From-My-PC'
  uci set firewall.allow_admin_from_pc.src='wan'
  uci set firewall.allow_admin_from_pc.proto='tcp'
  uci set firewall.allow_admin_from_pc.src_ip="$ADMIN_PC_IP"
  uci set firewall.allow_admin_from_pc.dest_port='80 443'
  uci set firewall.allow_admin_from_pc.target='ACCEPT'

  if [ "$WAN_SSH" = "y" ]; then
    uci -q delete firewall.allow_ssh_from_pc
    uci set firewall.allow_ssh_from_pc=rule
    uci set firewall.allow_ssh_from_pc.name='Allow-SSH-From-My-PC'
    uci set firewall.allow_ssh_from_pc.src='wan'
    uci set firewall.allow_ssh_from_pc.proto='tcp'
    uci set firewall.allow_ssh_from_pc.src_ip="$ADMIN_PC_IP"
    uci set firewall.allow_ssh_from_pc.dest_port='22'
    uci set firewall.allow_ssh_from_pc.target='ACCEPT'
  else
    uci -q delete firewall.allow_ssh_from_pc
  fi
else
  uci -q delete firewall.allow_admin_from_pc
  uci -q delete firewall.allow_ssh_from_pc
fi

if [ "$SET_WAN_DHCP" = "y" ]; then
  uci set network.wan.proto='dhcp'
fi

mkdir -p /www/admin /www/cgi-bin /root
chmod 755 /www/admin /www/cgi-bin

cat > /www/admin/mocha.css <<'CSS'
:root{
  --rosewater:#f5e0dc; --flamingo:#f2cdcd; --pink:#f5c2e7; --mauve:#cba6f7;
  --red:#f38ba8; --maroon:#eba0ac; --peach:#fab387; --yellow:#f9e2af;
  --green:#a6e3a1; --teal:#94e2d5; --sky:#89dceb; --sapphire:#74c7ec;
  --blue:#89b4fa; --lavender:#b4befe;
  --text:#cdd6f4; --subtext1:#bac2de; --subtext0:#a6adc8;
  --overlay2:#9399b2; --overlay1:#7f849c; --overlay0:#6c7086;
  --surface2:#585b70; --surface1:#45475a; --surface0:#313244;
  --base:#1e1e2e; --mantle:#181825; --crust:#11111b;
}

*{box-sizing:border-box}
html,body{height:100%}
body{
  margin:0;
  font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Ubuntu,Cantarell,Noto Sans,Arial;
  background:linear-gradient(180deg,var(--crust),var(--base));
  color:var(--text);
}
a{color:var(--blue); text-decoration:none}
a:hover{text-decoration:underline}
.wrap{max-width:980px;margin:40px auto;padding:0 16px}
.card{
  background:rgba(49,50,68,.85);
  border:1px solid rgba(127,132,156,.45);
  border-radius:18px;
  box-shadow:0 12px 40px rgba(0,0,0,.35);
  overflow:hidden;
}
.header{
  padding:20px 22px;
  display:flex;align-items:center;justify-content:space-between;gap:12px;
  background:rgba(24,24,37,.9);
  border-bottom:1px solid rgba(127,132,156,.35);
}
.title{font-size:18px;font-weight:700;letter-spacing:.2px}
.badge{
  font-size:12px;
  color:var(--subtext1);
  border:1px solid rgba(127,132,156,.45);
  background:rgba(17,17,27,.35);
  padding:6px 10px;border-radius:999px;
}
.grid{
  display:grid;
  grid-template-columns: 1.15fr .85fr;
  gap:18px;
  padding:18px;
}
@media (max-width:900px){.grid{grid-template-columns:1fr}}
.panel{
  background:rgba(69,71,90,.55);
  border:1px solid rgba(127,132,156,.35);
  border-radius:16px;
  padding:16px;
}
.row{display:flex;gap:10px;align-items:center;flex-wrap:wrap}
label{font-size:13px;color:var(--subtext1)}
input{
  background:rgba(17,17,27,.55);
  border:1px solid rgba(127,132,156,.45);
  color:var(--text);
  padding:10px 12px;
  border-radius:12px;
  outline:none;
  min-width:220px;
}
input:focus{border-color:rgba(137,180,250,.9); box-shadow:0 0 0 3px rgba(137,180,250,.15)}
.btn{
  border:1px solid rgba(127,132,156,.45);
  border-radius:12px;
  padding:10px 12px;
  background:rgba(24,24,37,.55);
  color:var(--text);
  cursor:pointer;
}
.btn:hover{border-color:rgba(180,190,254,.7)}
.btn-primary{
  background:linear-gradient(180deg, rgba(203,166,247,.35), rgba(203,166,247,.18));
  border-color:rgba(203,166,247,.65);
}
.btn-warn{
  background:linear-gradient(180deg, rgba(250,179,135,.28), rgba(250,179,135,.12));
  border-color:rgba(250,179,135,.55);
}
.kv{display:grid;grid-template-columns:140px 1fr;gap:8px 12px;margin-top:10px}
.k{color:var(--subtext1);font-size:13px}
.v{color:var(--text);font-size:13px;word-break:break-word}
.qrbox{display:flex;flex-direction:column;gap:10px;align-items:center;justify-content:center}
.qr{
  width:min(360px,100%);
  background:rgba(17,17,27,.35);
  border:1px solid rgba(127,132,156,.35);
  border-radius:16px;
  padding:14px;
}
.note{color:var(--subtext1);font-size:12px;line-height:1.35}
.status{margin-top:10px;color:var(--subtext1);font-size:12px}
.mono{font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace}
CSS

cat > /www/admin/index.html <<'HTML'
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Kids WiFi Admin</title>
  <link rel="stylesheet" href="/admin/mocha.css">
</head>
<body>
  <div class="wrap">
    <div class="card">
      <div class="header">
        <div class="title">OPENWRT-KIDSNETWORK</div>
        <div class="badge">Catppuccin Mocha</div>
      </div>

      <div class="grid">
        <div class="panel">
          <div class="kv">
            <div class="k">SSID</div><div class="v mono" id="ssid">-</div>
            <div class="k">Last rotated</div><div class="v mono" id="last">-</div>
          </div>

          <hr style="border:none;border-top:1px solid rgba(127,132,156,.25);margin:14px 0">

          <div class="row">
            <label for="pin">PIN</label>
            <input id="pin" type="password" inputmode="numeric" pattern="[0-9]*" placeholder="Enter PIN">
            <button class="btn btn-primary" id="btnRotate">Rotate now</button>
            <button class="btn btn-warn" id="btnReveal">Reveal password</button>
          </div>

          <div class="status" id="status">Ready.</div>
          <div class="note" style="margin-top:10px">
            This page is intended for LAN / Fritz LAN only. Keep WAN firewall rules tight.
          </div>
        </div>

        <div class="panel qrbox">
          <div class="note">Scan to join kids Wi-Fi</div>
          <div class="qr">
            <img id="qr" src="/admin/qr.svg" alt="Wi-Fi QR">
          </div>
          <div class="note mono" id="pw" style="display:none"></div>
        </div>
      </div>
    </div>
  </div>

<script>
const $ = (id) => document.getElementById(id);
const statusEl = $("status");
const pwEl = $("pw");
const qrEl = $("qr");

function setStatus(msg) { statusEl.textContent = msg; }

async function loadStatus() {
  try {
    const r = await fetch("/cgi-bin/kidsadmin.sh?action=status", {cache:"no-store"});
    const j = await r.json();
    if (!j.ok) throw new Error(j.error || "status_failed");
    $("ssid").textContent = j.ssid || "-";
    $("last").textContent = j.last_rotated || "-";
    qrEl.src = j.qr_url || "/admin/qr.svg";
  } catch (e) {
    setStatus("Status error: " + e.message);
  }
}

async function postAction(action) {
  const pin = $("pin").value.trim();
  if (!pin) { setStatus("Enter PIN first."); return; }

  setStatus("Working...");
  pwEl.style.display = "none";
  try {
    const body = new URLSearchParams({action, pin}).toString();
    const r = await fetch("/cgi-bin/kidsadmin.sh", {
      method: "POST",
      headers: {"Content-Type":"application/x-www-form-urlencoded"},
      body
    });
    const j = await r.json();
    if (!j.ok) { setStatus("Error: " + (j.error || "failed")); return; }

    if (action === "reveal") {
      pwEl.textContent = `Password: ${j.password || "-"}`;
      pwEl.style.display = "block";
      setStatus("Password revealed.");
    } else {
      $("ssid").textContent = j.ssid || "-";
      $("last").textContent = j.last_rotated || "-";
      qrEl.src = j.qr_url || ("/admin/qr.svg?v=" + Date.now());
      setStatus("Rotated.");
    }
  } catch (e) {
    setStatus("Request error: " + e.message);
  }
}

$("btnRotate").addEventListener("click", () => postAction("rotate"));
$("btnReveal").addEventListener("click", () => postAction("reveal"));

loadStatus();
</script>
</body>
</html>
HTML

cat > /root/kidswifi-rotate.sh <<'EOF'
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
EOF
chmod 700 /root/kidswifi-rotate.sh

cat > /www/cgi-bin/kidsadmin.sh <<'EOF'
#!/bin/sh
set -eu

# Fritz LAN guard (only allow requests from your admin LAN prefix)
ALLOW_PREFIX="__ALLOW_PREFIX__"

REMOTE="${REMOTE_ADDR:-}"
case "$REMOTE" in
  __ALLOW_PREFIX__*) : ;;
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
    PASS="$( [ -f "$META" ] && sed -n 's/^PASS=//p' "$META" | head -n1 || true )"
    SSID="$( [ -f "$META" ] && sed -n 's/^SSID=//p' "$META" | head -n1 || true )"
    TS="$(   [ -f "$META" ] && sed -n 's/^TS=//p' "$META"   | head -n1 || true )"
    send_json "{\"ok\":true,\"ssid\":\"$(json_escape "$SSID")\",\"last_rotated\":\"$(json_escape "$TS")\",\"password\":\"$(json_escape "$PASS")\"}"
    ;;
  *)
    send_json '{"ok":false,"error":"bad_action"}'
    ;;
esac
EOF
sed -i "s/__ALLOW_PREFIX__/${ADMIN_ALLOW_PREFIX}/g" /www/cgi-bin/kidsadmin.sh
chmod 755 /www/cgi-bin/kidsadmin.sh

echo "$ADMIN_PIN" > /root/kidswifi-pin
chmod 600 /root/kidswifi-pin

uci commit network
uci commit dhcp
uci commit firewall
uci commit wireless
uci commit uhttpd

/etc/init.d/network restart
/etc/init.d/dnsmasq restart
/etc/init.d/firewall restart
wifi reload
/etc/init.d/uhttpd enable
/etc/init.d/uhttpd restart

if [ "$RUN_ROTATE" = "y" ]; then
  /root/kidswifi-rotate.sh || true
fi

say "Done."
