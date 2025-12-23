#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (ssh root@openwrt)." >&2
  exit 1
fi

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

ask_yn CONT "Remove kids network, firewall rules, and admin panel files" n
[ "$CONT" = "y" ] || exit 0

for s in $(uci show wireless 2>/dev/null | sed -n 's/^wireless\.\([^.=]*\)=wifi-iface.*/\1/p'); do
  NET="$(uci -q get wireless."$s".network || true)"
  case " $NET " in
    *" kids "*) uci -q delete wireless."$s" ;;
  esac
done

uci -q delete network.br_kids
uci -q delete network.kids

uci -q delete dhcp.kids

uci -q delete firewall.kids
uci -q delete firewall.kids_wan
uci -q delete firewall.allow_dhcp_kids
uci -q delete firewall.allow_dns_kids
uci -q delete firewall.allow_admin_from_pc
uci -q delete firewall.allow_ssh_from_pc

rm -f \
  /www/admin/index.html \
  /www/admin/mocha.css \
  /www/admin/qr.svg \
  /www/cgi-bin/kidsadmin.sh \
  /root/kidswifi-rotate.sh \
  /root/kidswifi-pin \
  /root/kidswifi-meta \
  /root/kidswifi-current.txt

rmdir /www/admin 2>/dev/null || true
rmdir /www/cgi-bin 2>/dev/null || true

uci commit network
uci commit dhcp
uci commit firewall
uci commit wireless

/etc/init.d/network restart
/etc/init.d/dnsmasq restart
/etc/init.d/firewall restart
wifi reload

echo "Done."
