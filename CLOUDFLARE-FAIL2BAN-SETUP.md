# Cloudflare + Fail2ban Setup for Nginx Proxy Manager

Guide for configuring Fail2ban to work correctly behind Cloudflare-proxied traffic on servers running Nginx Proxy Manager (NPM) in Docker.

## Problem

When traffic is proxied through Cloudflare, the origin server sees Cloudflare's IP addresses instead of real visitor IPs. This causes two issues:

1. **Fail2ban bans Cloudflare IPs** — blocking ALL proxied traffic instead of individual attackers
2. **Fail2ban is ineffective** — it can only see Cloudflare IPs, not real malicious clients

## Solution Overview

1. Configure nginx `real_ip` module to restore actual visitor IPs from the `CF-Connecting-IP` header
2. Whitelist all Cloudflare IP ranges in Fail2ban's `ignoreip` as a safety net
3. Auto-update script + cron job to keep Cloudflare IP ranges current

## Prerequisites

- Nginx Proxy Manager running in Docker (image: `jc21/nginx-proxy-manager`)
- Fail2ban running in Docker (image: `crazymax/fail2ban`)
- Fail2ban config directory mapped to `~/server/fail2ban/data/`
- NPM data directory mapped to `~/server/npm/data/`

## File Structure

```
~/server/
├── npm/data/nginx/custom/
│   ├── http_top.conf          # set_real_ip_from directives (http context)
│   ├── server_proxy.conf      # real_ip_header override (server context)
│   └── root_top.conf          # (existing, not modified)
├── fail2ban/data/jail.d/
│   └── jail.local             # ignoreip with Cloudflare ranges
└── update-cloudflare-ips.sh   # auto-update script
```

## Step 1: Configure Nginx Real IP Restoration

NPM's custom config directory (`npm/data/nginx/custom/`) supports files that are auto-included at different nginx config levels.

**Important:** NPM's base `nginx.conf` already sets `real_ip_header X-Real-IP` in the `http` block. You CANNOT set `real_ip_header` again in `http_top.conf` or nginx will fail with a "duplicate directive" error. Instead, split the config:

- `http_top.conf` — `set_real_ip_from` directives (tells nginx which source IPs to trust)
- `server_proxy.conf` — `real_ip_header` override (overrides the http-level default per proxy host)

### http_top.conf

Add `set_real_ip_from` for all Cloudflare IPv4 and IPv6 ranges. Current ranges are published at:
- https://www.cloudflare.com/ips-v4
- https://www.cloudflare.com/ips-v6

```nginx
# Cloudflare IPv4 ranges
set_real_ip_from 173.245.48.0/20;
set_real_ip_from 103.21.244.0/22;
set_real_ip_from 103.22.200.0/22;
set_real_ip_from 103.31.4.0/22;
set_real_ip_from 141.101.64.0/18;
set_real_ip_from 108.162.192.0/18;
set_real_ip_from 190.93.240.0/20;
set_real_ip_from 188.114.96.0/20;
set_real_ip_from 197.234.240.0/22;
set_real_ip_from 198.41.128.0/17;
set_real_ip_from 162.158.0.0/15;
set_real_ip_from 104.16.0.0/13;
set_real_ip_from 104.24.0.0/14;
set_real_ip_from 172.64.0.0/13;
set_real_ip_from 131.0.72.0/22;

# Cloudflare IPv6 ranges
set_real_ip_from 2400:cb00::/32;
set_real_ip_from 2606:4700::/32;
set_real_ip_from 2803:f800::/32;
set_real_ip_from 2405:b500::/32;
set_real_ip_from 2405:8100::/32;
set_real_ip_from 2a06:98c0::/29;
set_real_ip_from 2c0f:f248::/32;
```

If the server also uses GeoIP2 blocking, append those directives in the same file (see existing config for reference).

### server_proxy.conf

```nginx
# Override the http-level real_ip_header for Cloudflare
real_ip_header CF-Connecting-IP;
real_ip_recursive on;
```

If the server also uses GeoIP2 country blocking, add:

```nginx
if ($blocked_country) {
    return 403;
}
```

## Step 2: Whitelist Cloudflare IPs in Fail2ban

In `fail2ban/data/jail.d/jail.local`, add all Cloudflare IPv4 ranges to the `ignoreip` directive.

This is a safety net — once real_ip is configured, Fail2ban should only see real client IPs in the logs. But if the real_ip config ever fails or is misconfigured, this prevents Fail2ban from banning Cloudflare IPs and taking down all traffic.

Append the Cloudflare ranges to the existing `ignoreip` line (space-separated):

```
ignoreip = 127.0.0.1/8 <your-other-ips>
           173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22
           141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20
           197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13
           104.24.0.0/14 172.64.0.0/13 131.0.72.0/22
```

## Step 3: Auto-Update Script

Cloudflare IP ranges change infrequently but do change. The `update-cloudflare-ips.sh` script fetches current ranges from Cloudflare's public endpoints and regenerates both configs.

Deploy the script to `~/server/update-cloudflare-ips.sh` and make it executable.

**Before deploying**, update these paths in the script to match the target server:
- `NGINX_CONF` — path to `http_top.conf`
- `JAIL_CONF` — path to `jail.local`

The script preserves:
- Any GeoIP2 config block in `http_top.conf`
- User's custom IPs in the Fail2ban `ignoreip` line (only Cloudflare ranges are replaced)

## Step 4: Cron Job

Add to **root's crontab** (runs as root for file permissions):

```bash
sudo crontab -e
```

Add:

```
0 3 * * 0 /home/andy/server/update-cloudflare-ips.sh >> /var/log/cloudflare-ip-update.log 2>&1
```

This runs weekly on Sundays at 3:00 AM. Do NOT use `sudo` inside the cron entry — root's crontab already runs as root.

## Step 5: Apply Changes

Restart both containers:

```bash
sudo docker restart nginx-proxy-manager fail2ban
```

## Verification

### Confirm nginx has no config errors

```bash
sudo docker logs --tail 20 nginx-proxy-manager
```

Look for `nginx: [emerg]` errors. If you see "duplicate directive" for `real_ip_header`, ensure it is only in `server_proxy.conf` and NOT in `http_top.conf`.

### Confirm Fail2ban loaded Cloudflare IPs

```bash
sudo docker exec fail2ban fail2ban-client get <jail-name> ignoreip
```

All Cloudflare IPv4 ranges should appear in the output.

### Confirm real client IPs in access logs

```bash
sudo tail -20 ~/server/npm/data/logs/proxy-host-*_access.log
```

The `[Client ...]` field should show real visitor IPs, not Cloudflare range IPs (104.x, 172.64.x, 162.158.x, etc.). Internal Docker IPs like `172.18.0.1` from wp-cron are normal.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `nginx: [emerg] "real_ip_header" directive is duplicate` | `real_ip_header` in both `http_top.conf` and NPM's base `nginx.conf` | Remove `real_ip_header` from `http_top.conf`, put it in `server_proxy.conf` only |
| Logs still show Cloudflare IPs as clients | `set_real_ip_from` missing a Cloudflare range, or containers not restarted | Run update script, restart NPM container |
| Fail2ban banning Cloudflare IPs | `ignoreip` not updated | Run update script, restart Fail2ban container |
| Cron job `Permission denied` on log file | Cron entry is in user's crontab, not root's | Move entry to root's crontab: `sudo crontab -e` |
