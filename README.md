## AndyBZ setup script for Debian / Ubuntu servers

Run as root on a fresh installation.

```bash
curl -s https://raw.githubusercontent.com/andybz/docker-server-setup/main/setup.sh > setup.sh && chmod +x ./setup.sh && ./setup.sh
```

### Hardens and configures system

- Creates non-root user with sudo and docker privileges.

- Updates packages and optionally enables unattended-upgrades.

- Changes SSH port and disables password login.

- Configures firewall to block ingress except on ports 80, 443, and your chosen SSH port.

- Fail2ban working out of the box to block malicious bot traffic to public web applications.

- Ensures the server is set to your preferred time zone.

- Adds aliases like `dcu` / `dcd` / `dcr` for docker compose up / down / restart.

### Installs docker, docker compose, and selected services

Besides Nginx Proxy Manager, all services are tunneled through SSH and not publicly accessible. The following are installed by default:

- **[Portainer](https://github.com/portainer/portainer)** and **[ctop](https://github.com/bcicen/ctop)** for easy container management with GUI and terminal.

- **[Nginx Proxy Manager](https://github.com/NginxProxyManager/nginx-proxy-manager)** for publicly exposing your services with automatic SSL.

- **[Fail2ban](https://github.com/crazy-max/docker-fail2ban)** configured to read Nginx Proxy Manager logs and block malicious IPs in iptables.

- **[MariaDB database](https://hub.docker.com/r/linuxserver/mariadb)** used by Nginx Proxy Manager and any other apps you want.

- **[phpMyAdmin](https://hub.docker.com/r/linuxserver/phpmyadmin)** for graphical administration of the MariaDB database.

- **[File Browser](https://github.com/filebrowser/filebrowser)** for graphical file management.

- **[Watchtower](https://github.com/containrrr/watchtower)** to automatically update running containers to the latest image version.

- **[Dozzle](https://github.com/amir20/dozzle)** for browsing container logs.

- **[Kopia](https://github.com/kopia/kopia)** for backups.

These are defined and can be disabled in `~/server/docker-compose.yml`. (Except the Kopia server which is a systemd service.)

## Notes

There is a docker network with the same name as your username. If you create new containers in that that network, you can use the container name as a hostname in Nginx Proxy Manager.

If you need to open a port for Wireguard or another service, [allow the port in iptables](https://www.digitalocean.com/community/tutorials/iptables-essentials-common-firewall-rules-and-commands) and run `sudo netfilter-persistent save` to save rules.

Individual MariaDB databases are automatically saved to disk each day for backup in `~/server/backups/mariadb`. To run the export job manually, use `/root/.export_mariadb.sh`.

To remove access for an SSH key, edit `~/.ssh/authorized_keys` and remove the line containing the key.

If you want to monitor uptime, check out **[Uptime Kuma](https://github.com/louislam/uptime-kuma)**, but you should run this from a different machine.

If you're running wordpress sites created via the `boost` command, wp-fail2ban events are logged to `~/server/wp-fail2ban.log`. This file is automatically monitored by the fail2ban container, and you can use it to review security related events. For example, use `grep "Accepted" ~/server/wp-fail2ban.log` to view succesful logins if you want to whitelist IPs. The timestamps in this file are unfortunately locked to GMT. If you know how to change the timezone for syslog in Alpine Linux, let me know.

## boost command

The command `boost` runs a helper script that allows you to do the following:

- Start site
- Stop site
- Create wordpress site + database
- Delete site / files
- Restart site
- Fix permissions for created wordpress site
- Add SSH key
- Start container shell session
- View status of all Fail2ban jails
- Unban IP in Fail2ban jail
- Permanently whitelist IP in Fail2ban

## Working with Fail2ban

You can view logs for Fail2ban in Dozzle or by using `docker logs fail2ban`.

The jail is reloaded every six hours with a systemd timer to pick up log files from new proxy hosts.

Additional rules may be added to the container in `~/server/fail2ban`. Use the FORWARD chain (not INPUT or DOCKER-USER) and make sure the filter regex is using the NPM log format - `[Client <HOST>]`.

**Unban all IPs** If you get into a tricky situation.

```bash
docker exec fail2ban sh -c "fail2ban-client set npm-docker unbanip --all"
```

## Logs

You can view / search / download container logs with **[Dozzle](http://localhost:6905)**. For wordpress containers, this will show both nginx and php-fpm output.

Nginx Proxy Manager logs are located in `~/server/npm/data/logs/`. You need the ID of the proxy host you want to view, which you can find by clicking the three dots in NPM. These logs are limited to web requests and are rotated weekly.

Example command to view live log: `tail -f ~/server/npm/data/logs/proxy-host-1_access.log`

Example command search log for IP: `grep "0.0.0.0" ~/server/npm/data/logs/proxy-host-1_access.log`

## Using with Cloudflare

If you proxy traffic through Cloudflare and want to use Fail2ban, additional configuration is required to avoid banning Cloudflare IPs. Please reference the guides below.

Fail2ban configuration is located in `~/server/fail2ban`.

- https://www.youtube.com/watch?v=Ha8NIAOsNvo (and [companion article](https://dbt3ch.com/books/fail2ban/page/how-to-install-and-configure-Fail2ban-to-work-with-nginx-proxy-manager) by DB Tech)

- https://blog.lrvt.de/fail2ban-with-nginx-proxy-manager/
