## AndyBZ setup script for Debian / Ubuntu servers

Run as root on a fresh installation:

```bash
curl -fsSL https://raw.githubusercontent.com/andybz/docker-server-setup/main/setup.sh -o setup.sh
sudo bash setup.sh
```

The script asks for a time zone, username, SSH port and (if needed) an SSH key. To run it without questions, set them as environment variables:

```bash
USERNAME=andy SSH_PORT=57822 TIMEZONE=America/New_York sudo -E bash setup.sh
```

Other optional variables: `SSH_PUBKEY`, `USER_PASSWORD` (sudo password), `REPO_REF` (branch or tag to install, default `main`) and `REBOOT=yes|no`. Re-running the script is safe: finished steps are skipped and existing passwords and settings are kept.

After setup:

1. Log in as your user on the new SSH port. On that first login, port 22 is closed automatically.
2. Set up off-site backups: `sudo setup-backups` (see [Backups](#backups)). Until you do, the nightly backup reports a failure on purpose.

### Hardens and configures the system

- Creates a non-root user with sudo and docker access.
- Updates packages and turns on automatic security updates.
- SSH: moves to your chosen port, keys only, no root login, only your user allowed (`/etc/ssh/sshd_config.d/00-hardening.conf`). fail2ban on the host bans SSH brute-forcing.
- Firewall for IPv4 and IPv6: only 80, 443 and your SSH port are reachable.
- Kernel network hardening, a swap file on small servers, and Docker log size limits so logs can't fill the disk.
- Time zone and handy aliases: `dcu` / `dcd` / `dcr` for docker compose up / down / restart.

### Installs Docker and these services

Besides Nginx Proxy Manager, every service is only reachable through an SSH tunnel:

- **[Portainer](https://github.com/portainer/portainer)** and **[ctop](https://github.com/bcicen/ctop)** for container management (GUI and terminal).
- **[Nginx Proxy Manager](https://github.com/NginxProxyManager/nginx-proxy-manager)** for publishing sites with automatic SSL.
- **[Fail2ban](https://github.com/crazy-max/docker-fail2ban)** reading the NPM and WordPress logs and banning attackers (IPv4 and IPv6).
- **[MariaDB](https://hub.docker.com/_/mariadb)** (official image, 11.4 LTS) used by NPM and the sites.
- **[phpMyAdmin](https://hub.docker.com/_/phpmyadmin)** (official image). Log in with a database user; there is deliberately no auto-login.
- **[File Browser](https://github.com/filebrowser/filebrowser)** for file management. Newer versions create a random admin password on first start: `docker logs filebrowser 2>&1 | grep password`.
- **[Watchtower](https://github.com/nicholas-fedor/watchtower)** (maintained fork) to update containers automatically.
- **[Dozzle](https://github.com/amir20/dozzle)** for browsing container logs.

They are defined in `~/server/docker-compose.yml`. Passwords live in `~/server/.env` (readable only by you). Your MariaDB root password is in there too.

Add this to `~/.ssh/config` on your computer to reach the admin pages (setup prints it for you):

```
Host myserver
    HostName <server ip>
    Port <ssh port>
    User <username>
    LocalForward 6900 127.0.0.1:6900
    LocalForward 6901 127.0.0.1:6901
    LocalForward 6902 127.0.0.1:6902
    LocalForward 6903 127.0.0.1:6903
    LocalForward 6905 127.0.0.1:6905
```

Then: Portainer http://localhost:6900, Nginx Proxy Manager http://localhost:6901, phpMyAdmin http://localhost:6902, File Browser http://localhost:6903, Dozzle http://localhost:6905.

## Notes

There is a docker network with the same name as your username. Sites and NPM share it, so you can use a container name as the forward hostname in Nginx Proxy Manager. Each site's Redis runs on a private network of its own, so sites can't reach each other's caches.

**Docker bypasses the host firewall.** A port published as `"8080:80"` is open to the whole internet no matter what the firewall says. Always publish admin ports as `127.0.0.1:PORT:PORT` (as `docker-compose.yml` does); only NPM should publish 80 and 443. If your cloud provider has a firewall (Hetzner, DigitalOcean), allow only 80, 443 and your SSH port there too.

The setup scripts live on the server in `~/server/tools` (a git clone of this repo). Nothing is downloaded and run on the fly; update them deliberately with `andybz` → **Update Tools**.

To remove access for an SSH key, edit `~/.ssh/authorized_keys` and delete its line.

If you want to monitor uptime, check out **[Uptime Kuma](https://github.com/louislam/uptime-kuma)**, but run it from a different machine.

## andybz command

`andybz` opens a helper menu:

- Start / stop / restart a site
- Create a WordPress site and database (the database password is saved in `~/sites/<site>/.db-credentials`)
- Delete a site, its files and optionally its database (asks you to type the site name to confirm)
- Fix file permissions of a site
- Add an SSH key
- Open a shell in a site container
- Fail2ban: status, unban, permanently whitelist, blacklist an IP
- Ban / unban a country (GeoIP2, see [GEOIP-SETUP.md](GEOIP-SETUP.md))
- Database search-replace (dry run first, and a database backup before changing anything)
- Run a backup now / show backup status
- Update the server containers that Watchtower leaves alone (NPM, MariaDB, Portainer, ...)
- Update the tools in `~/server/tools`

## Backups

Every night at about 1:30 a.m. `serverBackup.timer` runs `/usr/local/sbin/server-backup`, which:

1. dumps every MariaDB database to `~/server/backups/mariadb` (one file per database per day, kept 7 days)
2. sends `~/sites`, `~/server` (including those dumps) and the server settings to an **off-site** repository with [restic](https://restic.net), encrypted before it leaves the server
3. keeps 7 daily, 4 weekly and 6 monthly snapshots, and checks the repository once a week

Set up the off-site destination once with `sudo setup-backups`. It supports Backblaze B2, any S3-compatible storage (AWS, DigitalOcean Spaces, Wasabi, Cloudflare R2, Hetzner Object Storage) and SFTP (for example a Hetzner Storage Box). It generates the repository password and shows it once: **store it in your password manager**, because without it the backups can't be restored. You can also give it a [healthchecks.io](https://healthchecks.io) URL to be alerted when a backup fails or doesn't run.

Check on backups with `andybz` → **Backup Status**, or `systemctl status serverBackup.service`.

Restore (as root):

```bash
set -a; . /root/.restic.env; set +a
restic snapshots                                   # list backups
restic restore latest --target /tmp/restore \
  --include /home/USER/sites/SITE                  # one site's files
# a database: the dumps are inside the snapshot under ~/server/backups/mariadb
gunzip -c /tmp/restore/home/USER/server/backups/mariadb/DB-DATE.sql.gz |
  docker exec -i mariadb sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -uroot DB'
```

## Working with Fail2ban

You can view logs for Fail2ban in Dozzle or with `docker logs fail2ban`.

Each ban is applied in iptables (FORWARD chain, which Docker traffic uses) and also written to an nginx deny list in `~/server/npm/data/nginx/custom/f2b/`. NPM includes that list in every proxy host and is reloaded automatically when it changes (`npmReload.path`), so bans work for Cloudflare-proxied sites too.

The jail is reloaded every six hours to pick up log files from new proxy hosts.

Additional rules may be added in `~/server/fail2ban/data`. Use the FORWARD chain (not INPUT or DOCKER-USER) and make sure the filter regex uses the NPM log format: `[Client <HOST>]`.

**Unban all IPs** if you get into a tricky situation:

```bash
docker exec fail2ban fail2ban-client set npm-docker unbanip --all
```

If you're running WordPress sites created with `andybz`, wp-fail2ban events are logged to `~/server/wp-fail2ban.log` and feed the `wordpress-soft` and `wordpress-hard` jails. For example, `grep "Accepted" ~/server/wp-fail2ban.log` shows successful logins. The timestamps in this file are in GMT.

## Using with Cloudflare

Works out of the box: NPM restores the real visitor IP from Cloudflare's `CF-Connecting-IP` header, Cloudflare's ranges are whitelisted in fail2ban (kept current weekly by `update-cloudflare-ips`), and bans also apply through the nginx deny lists. See [CLOUDFLARE-FAIL2BAN-SETUP.md](CLOUDFLARE-FAIL2BAN-SETUP.md) for details.

## Logs

You can view, search and download container logs with **[Dozzle](http://localhost:6905)**. For WordPress containers this shows both nginx and php-fpm output.

Nginx Proxy Manager logs are in `~/server/npm/data/logs/`. You need the ID of the proxy host, which you can find by clicking the three dots in NPM. These logs only cover web requests and are rotated weekly.

- Live log: `tail -f ~/server/npm/data/logs/proxy-host-1_access.log`
- Search for an IP: `grep "203.0.113.7" ~/server/npm/data/logs/proxy-host-1_access.log`

## Upgrading a server set up with an older version

Re-running `setup.sh` is not meant for existing servers. To bring one up to date by hand:

1. **Off-site backups** (most important): copy `backup/server-backup.sh` and `backup/setup-backups.sh` to `/usr/local/sbin/server-backup` and `/usr/local/sbin/setup-backups`, create `/etc/server-setup.conf` with `USERNAME=...`, install `systemd/serverBackup.*` and enable the timer, disable `mariadbBackup.timer` and `kopiaServer.service`, then run `sudo setup-backups`. It works with the old `linuxserver/mariadb` container too.
2. **Fail2ban**: replace `~/server/fail2ban/data/action.d/npm-firewall-block.conf`, add `jail.d/00-cloudflare.local` and the `%(cloudflare_ips)s` line in `jail.local`, add the `/nginx-deny` volume and `npm/custom/server_proxy.conf`, install `systemd/npmReload.*` and `systemd/cloudflareIps.*` plus `/usr/local/sbin/update-cloudflare-ips`.
3. **Sites**: add the private `internal` network for Redis, the Watchtower label and `mem_limit` from `wordpress/docker-compose.yml`, then `docker compose up -d` in the site folder.
4. **Watchtower**: switch to label mode (`WATCHTOWER_LABEL_ENABLE`) or keep listing containers explicitly.
5. **SSH and firewall**: move SSH settings into `/etc/ssh/sshd_config.d/00-hardening.conf` and add IPv6 rules matching `firewall.sh`.
