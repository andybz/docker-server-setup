# Cloudflare + Fail2ban with Nginx Proxy Manager

New servers set up with `setup.sh` handle Cloudflare-proxied sites out of the box. This page explains how, and how to check it.

## The problem

When a site is proxied through Cloudflare (orange cloud), the server sees Cloudflare's IP addresses instead of the visitors'. Without extra configuration:

1. **Fail2ban bans Cloudflare**, blocking all proxied traffic instead of one attacker.
2. **Fail2ban is useless**, because every request seems to come from Cloudflare.
3. **iptables bans can't work** for proxied sites, because the connection really does come from Cloudflare.

## How it's solved

1. **Real visitor IPs.** NPM keeps Cloudflare's IP ranges in its built-in `ip_ranges.conf` (refreshed when NPM starts) and trusts them for real-IP restoration. `~/server/npm/data/nginx/custom/server_proxy.conf` tells nginx to take the visitor IP from Cloudflare's `CF-Connecting-IP` header:

   ```nginx
   real_ip_header CF-Connecting-IP;
   real_ip_recursive on;
   include /data/nginx/custom/f2b/*.conf;
   ```

   Only requests from trusted (Cloudflare) addresses are rewritten, so direct visitors can't spoof the header. NPM's base `nginx.conf` already sets `real_ip_header` at the http level, so this must stay in `server_proxy.conf`; putting it in `http_top.conf` causes a "duplicate directive" error.

2. **Bans that work behind Cloudflare.** The `npm-firewall-block` action writes every ban to iptables (for direct connections) and to an nginx deny list in `~/server/npm/data/nginx/custom/f2b/`, which the `include` line above loads into every proxy host. `npmReload.path` reloads NPM whenever a list changes.

3. **Cloudflare can never be banned.** `~/server/fail2ban/data/jail.d/00-cloudflare.local` holds Cloudflare's IPv4 and IPv6 ranges, and `jail.local` adds them to `ignoreip` with `%(cloudflare_ips)s`. `update-cloudflare-ips` rewrites that file weekly (`cloudflareIps.timer`), checks that every line it downloads is a valid IP range, and reloads fail2ban only if something changed. Nothing else in the fail2ban config is touched.

## Checking it

Real client IPs in the access logs. The `[Client ...]` field should show visitor IPs, not Cloudflare ranges (104.x, 172.64-71.x, 162.158.x, ...). Internal Docker IPs like `172.18.0.1` from WordPress cron are normal:

```bash
tail -20 ~/server/npm/data/logs/proxy-host-*_access.log
```

Cloudflare whitelisted in fail2ban:

```bash
docker exec fail2ban fail2ban-client get npm-docker ignoreip
```

Cloudflare range updates:

```bash
systemctl list-timers cloudflareIps.timer
journalctl -u cloudflareIps.service -n 5
sudo update-cloudflare-ips        # run it now
```

NPM config valid after a change:

```bash
docker exec nginx-proxy-manager nginx -t
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `nginx: [emerg] "real_ip_header" directive is duplicate` | `real_ip_header` added to `http_top.conf` | Keep it only in `server_proxy.conf` |
| Logs show Cloudflare IPs as clients | `server_proxy.conf` missing or NPM not restarted | Check the file, then `docker restart nginx-proxy-manager` |
| Fail2ban banning Cloudflare IPs | `00-cloudflare.local` missing or `%(cloudflare_ips)s` removed from `ignoreip` | `sudo update-cloudflare-ips`, check `jail.local` |
| Banned visitor still reaches a proxied site | NPM not reloaded after the ban | `systemctl status npmReload.path`, or `docker exec nginx-proxy-manager nginx -s reload` |
