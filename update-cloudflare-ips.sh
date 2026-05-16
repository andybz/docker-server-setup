#!/usr/bin/env bash
#
# update-cloudflare-ips.sh
# Fetches current Cloudflare IP ranges and updates:
#   1. Nginx Proxy Manager real_ip config (http_top.conf)
#   2. Fail2ban ignoreip whitelist (jail.local)
#
# Usage: sudo ./update-cloudflare-ips.sh
# Recommended: run weekly via cron
#   0 3 * * 0 /home/andy/server/update-cloudflare-ips.sh >> /var/log/cloudflare-ip-update.log 2>&1

NGINX_CONF="/home/andy/server/npm/data/nginx/custom/http_top.conf"
JAIL_CONF="/home/andy/server/fail2ban/data/jail.d/jail.local"

# Fetch current Cloudflare IP ranges
CF_IPV4=$(curl -sf https://www.cloudflare.com/ips-v4)
CF_IPV6=$(curl -sf https://www.cloudflare.com/ips-v6)

if [ -z "$CF_IPV4" ] || [ -z "$CF_IPV6" ]; then
    echo "$(date): ERROR - Failed to fetch Cloudflare IP ranges. Aborting." >&2
    exit 1
fi

echo "$(date): Fetched $(echo "$CF_IPV4" | wc -l) IPv4 and $(echo "$CF_IPV6" | wc -l) IPv6 ranges."

# -----------------------------------------------
# 1. Rebuild nginx http_top.conf
# -----------------------------------------------

# Build set_real_ip_from directives
NGINX_CF_BLOCK="# ---------------------------------------------------
# Cloudflare real IP restoration
# Tells nginx to trust these source IPs and use
# CF-Connecting-IP header to get the real visitor IP.
# Auto-maintained by ~/server/update-cloudflare-ips.sh
# Last updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
# ---------------------------------------------------

# Cloudflare IPv4 ranges"

while IFS= read -r ip; do
    [ -n "$ip" ] && NGINX_CF_BLOCK="${NGINX_CF_BLOCK}
set_real_ip_from ${ip};"
done <<< "$CF_IPV4"

NGINX_CF_BLOCK="${NGINX_CF_BLOCK}

# Cloudflare IPv6 ranges"

while IFS= read -r ip; do
    [ -n "$ip" ] && NGINX_CF_BLOCK="${NGINX_CF_BLOCK}
set_real_ip_from ${ip};"
done <<< "$CF_IPV6"

NGINX_CF_BLOCK="${NGINX_CF_BLOCK}

real_ip_recursive on;"

# Preserve everything from the GeoIP2 section onward
GEOIP_BLOCK=$(sed -n '/^# -.*GeoIP2/,$ p' "$NGINX_CONF")

if [ -z "$GEOIP_BLOCK" ]; then
    echo "$(date): WARNING - Could not find GeoIP2 block in $NGINX_CONF. Writing CF block only."
    echo "$NGINX_CF_BLOCK" > "$NGINX_CONF"
else
    printf '%s\n\n%s\n' "$NGINX_CF_BLOCK" "$GEOIP_BLOCK" > "$NGINX_CONF"
fi

echo "$(date): Updated $NGINX_CONF"

# -----------------------------------------------
# 2. Update Fail2ban ignoreip in jail.local
# -----------------------------------------------

# Build the Cloudflare portion of ignoreip (IPv4 only — Fail2ban iptables works on IPv4)
CF_IGNORE=$(echo "$CF_IPV4" | tr '\n' ' ' | sed 's/ *$//')

# Read existing ignoreip line, strip old Cloudflare ranges (anything after the user's custom IPs)
# We detect the boundary by finding the last IP before the first Cloudflare range (103.x, 104.x, etc.)
# Strategy: preserve everything up to and including the original user IPs, then append new CF ranges.

# Extract the user's original (non-Cloudflare) IPs from the current ignoreip
CURRENT_IGNORE=$(grep -A5 '^ignoreip' "$JAIL_CONF" | tr -d '\n' | sed 's/ignoreip *= *//' | tr -s ' ')
USER_IPS=""
for ip in $CURRENT_IGNORE; do
    # Keep IPs that are NOT in Cloudflare's range list
    if ! echo "$CF_IPV4" | grep -qF "$ip"; then
        USER_IPS="$USER_IPS $ip"
    fi
done
USER_IPS=$(echo "$USER_IPS" | sed 's/^ //')

# Build new ignoreip value
NEW_IGNORE="ignoreip = ${USER_IPS} ${CF_IGNORE}"

# Replace the ignoreip block in jail.local (may span multiple lines with continuation)
# First, collapse the multi-line ignoreip into one marker, then replace
TMPFILE=$(mktemp)
awk '
    /^ignoreip/ { printing=1; next }
    printing && /^[[:space:]]/ { next }
    printing { printing=0 }
    !printing { print }
' "$JAIL_CONF" > "$TMPFILE"

# Insert the new ignoreip line after the comment
sed -i "/^# Auto-maintained by/a\\
${NEW_IGNORE}" "$TMPFILE" 2>/dev/null

# If the marker comment wasn't found, insert before [npm-docker]
if ! grep -q '^ignoreip' "$TMPFILE"; then
    sed -i "/^\[npm-docker\]/i\\
${NEW_IGNORE}\n" "$TMPFILE"
fi

cp "$TMPFILE" "$JAIL_CONF"
rm -f "$TMPFILE"

echo "$(date): Updated $JAIL_CONF"

echo "$(date): Done. Restart NPM and Fail2ban containers to apply changes."
