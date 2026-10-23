#!/usr/bin/env bash
#
# update-cloudflare-ips (installed in /usr/local/sbin, run weekly as root by
# cloudflareIps.timer)
#
# Keeps Cloudflare's published IP ranges in fail2ban's whitelist so fail2ban can
# never ban Cloudflare itself (which would take down every proxied site).
# The list lives in its own generated file, jail.d/00-cloudflare.local, which
# jail.local pulls in with %(cloudflare_ips)s - nothing else is touched.
#
# Real visitor IPs behind Cloudflare are restored by NPM itself: it keeps
# Cloudflare's ranges in its built-in ip_ranges.conf, and server_proxy.conf sets
# real_ip_header CF-Connecting-IP. So no nginx changes are needed here.

set -Eeuo pipefail

CONF=/etc/server-setup.conf
# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"
USERNAME="${USERNAME:?USERNAME is not set in $CONF}"
OUT="/home/$USERNAME/server/fail2ban/data/jail.d/00-cloudflare.local"

fetch() { curl -fsS --max-time 20 --retry 3 "$1"; }

# Cloudflare's lists have no trailing newline, so join them explicitly
ranges=$(printf '%s\n%s\n' "$(fetch https://www.cloudflare.com/ips-v4)" "$(fetch https://www.cloudflare.com/ips-v6)" |
  tr -d '\r' | sed '/^[[:space:]]*$/d')

# refuse to write anything that is not a list of CIDR ranges
count=0
while read -r cidr; do
  if ! [[ $cidr =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ || $cidr =~ ^[0-9a-fA-F:]+/[0-9]{1,3}$ ]]; then
    echo "$(date '+%F %T') ERROR: unexpected line from Cloudflare: '$cidr'. Nothing changed." >&2
    exit 1
  fi
  count=$((count + 1))
done <<<"$ranges"

if [ "$count" -lt 10 ]; then
  echo "$(date '+%F %T') ERROR: only $count ranges received. Nothing changed." >&2
  exit 1
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
{
  echo "# Managed by update-cloudflare-ips (weekly via cloudflareIps.timer). Do not edit:"
  echo "# this file is rewritten from https://www.cloudflare.com/ips-v4 and /ips-v6."
  echo "# Whitelisted so a broken real-IP setup can never get Cloudflare itself banned."
  echo
  echo "[DEFAULT]"
  echo "cloudflare_ips = $(echo "$ranges" | paste -sd' ' -)"
} >"$tmp"

if [ -f "$OUT" ] && cmp -s "$tmp" "$OUT"; then
  echo "$(date '+%F %T') Cloudflare ranges unchanged ($count)."
  exit 0
fi

install -m 644 "$tmp" "$OUT"
docker exec fail2ban fail2ban-client reload >/dev/null
echo "$(date '+%F %T') Updated $count Cloudflare ranges and reloaded fail2ban."
