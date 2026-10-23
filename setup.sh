#!/usr/bin/env bash
#
# AndyBZ server setup for a fresh Ubuntu / Debian server. Run as root:
#
#   curl -fsSL https://raw.githubusercontent.com/andybz/docker-server-setup/main/setup.sh -o setup.sh
#   sudo bash setup.sh
#
# Every question can be answered ahead of time with an environment variable:
#   USERNAME=andy SSH_PORT=57822 TIMEZONE=America/New_York sudo -E bash setup.sh
# Optional: SSH_PUBKEY (if root has no authorized_keys), USER_PASSWORD (sudo
# password; prompted if unset), REPO_REF (branch or tag to install, default main),
# REBOOT=yes|no.

set -Eeuo pipefail

GREEN="\e[32m"
CYAN="\e[36m"
YELLOW="\e[33m"
RED="\e[31m"
ENDCOLOR="\e[0m"
REPO_URL="${REPO_URL:-https://github.com/andybz/docker-server-setup.git}"
REPO_REF="${REPO_REF:-main}"

step() { echo -e "\n${CYAN}==> $*${ENDCOLOR}"; }
die() { echo -e "${RED}$*${ENDCOLOR}" >&2; exit 1; }
trap 'echo -e "${RED}Setup failed at line $LINENO. Fix the problem and re-run; finished steps are skipped.${ENDCOLOR}"' ERR

[ "$(id -u)" -eq 0 ] || die "Run this script as root (sudo bash setup.sh)."
# shellcheck source=/dev/null
. /etc/os-release
case "$ID" in ubuntu | debian) ;; *) die "Only Ubuntu and Debian are supported." ;; esac

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

echo -e "${GREEN}AndyBZ server setup${ENDCOLOR}"

# ---------------------------------------------------------------------------
# Questions
# ---------------------------------------------------------------------------
CUR_TIMEZONE=$(timedatectl show -p Timezone --value)
if [ -z "${TIMEZONE:-}" ]; then
  read -r -p "Time zone [$CUR_TIMEZONE]: " TIMEZONE
  TIMEZONE=${TIMEZONE:-$CUR_TIMEZONE}
fi
# (no grep -q: it exits early, and with pipefail the pipeline would then fail)
timedatectl list-timezones | grep -x "$TIMEZONE" >/dev/null || die "Unknown time zone: $TIMEZONE"

while [[ ! ${USERNAME:-} =~ ^[a-z][-a-z0-9]{0,30}$ ]]; do
  read -r -p "Username to create (lowercase letters, digits, dashes): " USERNAME
done

while ! [[ ${SSH_PORT:-} =~ ^[0-9]+$ ]] || ((SSH_PORT < 1024 || SSH_PORT > 65000)) || ((SSH_PORT >= 6900 && SSH_PORT <= 6905)); do
  read -r -p "SSH port (1024-65000, not 6900-6905): " SSH_PORT
done

if [ ! -s /root/.ssh/authorized_keys ] && [ -z "${SSH_PUBKEY:-}" ]; then
  read -r -p "Paste your public SSH key: " SSH_PUBKEY
fi

# ---------------------------------------------------------------------------
# System
# ---------------------------------------------------------------------------
step "Time zone: $TIMEZONE"
timedatectl set-timezone "$TIMEZONE"

step "Updating packages"
apt-get update -qq
apt-get -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
# iptables-persistent replaces ufw; don't let it snapshot rules on install
echo "iptables-persistent iptables-persistent/autosave_v4 boolean false" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" | debconf-set-selections
apt-get -y -qq install ca-certificates curl gnupg git openssl python3 \
  unattended-upgrades apt-listchanges fail2ban iptables-persistent restic >/dev/null

step "Automatic security updates"
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
cat >/etc/apt/apt.conf.d/52unattended-upgrades-local <<'EOF'
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
// set to "true" (and pick a time) to reboot automatically for kernel updates
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF
systemctl enable -q --now unattended-upgrades

step "Kernel network hardening"
cat >/etc/sysctl.d/90-hardening.conf <<'EOF'
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
vm.swappiness = 10
EOF
sysctl -q --system

mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
if [ -z "$(swapon --show --noheadings)" ] && [ "$mem_mb" -lt 4096 ]; then
  step "Adding a 2 GB swap file (${mem_mb} MB RAM)"
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap -q /swapfile && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
fi

# ---------------------------------------------------------------------------
# User
# ---------------------------------------------------------------------------
step "User: $USERNAME"
HOME_DIR="/home/$USERNAME"
if ! id "$USERNAME" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$USERNAME"
  if [ -n "${USER_PASSWORD:-}" ]; then
    echo "$USERNAME:$USER_PASSWORD" | chpasswd
  else
    echo "Set a password for $USERNAME (used for sudo):"
    passwd "$USERNAME"
  fi
fi
usermod -aG sudo "$USERNAME" 2>/dev/null || usermod -aG wheel "$USERNAME"

install -d -m 700 -o "$USERNAME" -g "$USERNAME" "$HOME_DIR/.ssh"
if [ -n "${SSH_PUBKEY:-}" ]; then
  echo "$SSH_PUBKEY" >>"$HOME_DIR/.ssh/authorized_keys"
elif [ ! -s "$HOME_DIR/.ssh/authorized_keys" ]; then
  cp /root/.ssh/authorized_keys "$HOME_DIR/.ssh/authorized_keys"
fi
chown "$USERNAME:" "$HOME_DIR/.ssh/authorized_keys"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"

cat >/etc/server-setup.conf <<EOF
# Read by the root scripts in /usr/local/sbin (backups, Cloudflare updater, firewall)
USERNAME=$USERNAME
SSH_PORT=$SSH_PORT
LOCAL_KEEP_DAYS=7
EOF
chmod 644 /etc/server-setup.conf

# ---------------------------------------------------------------------------
# Tools (this repo), kept on the server so nothing is downloaded and run blindly
# ---------------------------------------------------------------------------
step "Installing tools ($REPO_REF) into $HOME_DIR/server/tools"
TOOLS="$HOME_DIR/server/tools"
mkdir -p "$HOME_DIR/server" "$HOME_DIR/sites" "$HOME_DIR/server/backups"
if [ -d "$TOOLS/.git" ]; then
  git -C "$TOOLS" fetch -q --depth 1 origin "$REPO_REF" && git -C "$TOOLS" checkout -q FETCH_HEAD
else
  git clone -q --depth 1 --branch "$REPO_REF" "$REPO_URL" "$TOOLS"
fi
chown -R "$USERNAME:" "$TOOLS" "$HOME_DIR/sites"

# ---------------------------------------------------------------------------
# Firewall (before Docker starts publishing ports)
# ---------------------------------------------------------------------------
step "Firewall"
bash "$TOOLS/firewall.sh" apply "$SSH_PORT"

# ---------------------------------------------------------------------------
# SSH
# ---------------------------------------------------------------------------
step "SSH: port $SSH_PORT, keys only, no root login"
# port 22 stays open until the first login on the new port proves it works
# (firewall.sh first-login then closes it)
port_lines="Port $SSH_PORT"
[ "$SSH_PORT" != 22 ] && port_lines="$port_lines
Port 22"
cat >/etc/ssh/sshd_config.d/00-hardening.conf <<EOF
# Written by setup.sh. The 00- prefix makes these win over later drop-ins
# (such as cloud-init's), which sshd would otherwise read first.
$port_lines
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
AllowUsers $USERNAME
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
PermitUserEnvironment no
EOF
sshd -t
systemctl daemon-reload
if systemctl is-active --quiet ssh.socket; then systemctl restart ssh.socket; else systemctl restart ssh; fi

# fail2ban on the host for SSH (the fail2ban container covers the websites)
cat >/etc/fail2ban/jail.d/sshd.local <<EOF
[DEFAULT]
backend = systemd
banaction = iptables-multiport
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = $SSH_PORT,22

[recidive]
enabled = true
logpath = /var/log/fail2ban.log
backend = auto
bantime = 1w
findtime = 1d
EOF
systemctl enable -q fail2ban
systemctl restart fail2ban

# ---------------------------------------------------------------------------
# Docker
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null; then
  step "Installing Docker (official repository)"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" \
    >/etc/apt/sources.list.d/docker.list
  mkdir -p /etc/docker
  # cap container logs so they can't fill the disk
  cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "local",
  "log-opts": { "max-size": "20m", "max-file": "5" }
}
EOF
  apt-get update -qq
  apt-get -y -qq install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
fi
systemctl enable -q --now docker
usermod -aG docker "$USERNAME"

# ---------------------------------------------------------------------------
# Server stack
# ---------------------------------------------------------------------------
step "Server containers"
SERVER="$HOME_DIR/server"
cp -n "$TOOLS/docker-compose.yml" "$SERVER/docker-compose.yml"
if [ ! -f "$SERVER/.env" ]; then
  gen() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-24; }
  (
    umask 077
    cat >"$SERVER/.env" <<EOF
USERNAME=$USERNAME
TZ=$TIMEZONE
MARIADB_ROOT_PASSWORD=$(gen)
NPM_DB_PASSWORD=$(gen)
EOF
  )
fi
chown "$USERNAME:" "$SERVER/.env" "$SERVER/docker-compose.yml"
chmod 600 "$SERVER/.env"

mkdir -p "$SERVER/fail2ban/data" "$SERVER/npm/data/logs" "$SERVER/npm/data/nginx/custom/f2b" "$SERVER/filebrowser/config"
cp -rn "$TOOLS/fail2ban/." "$SERVER/fail2ban/data/"
cp -n "$TOOLS/npm/custom/server_proxy.conf" "$SERVER/npm/data/nginx/custom/server_proxy.conf"
# empty logs and deny lists so fail2ban and the NPM reload watcher start cleanly
touch "$SERVER/npm/data/logs/proxy-host-"{1..5}"_access.log" "$SERVER/wp-fail2ban.log" \
  "$SERVER/npm/data/nginx/custom/f2b/"{npm-docker,wordpress-hard,wordpress-soft}.conf
chown "$USERNAME:" "$SERVER/wp-fail2ban.log"
chown -R 65534:65534 "$SERVER/filebrowser"
sed "s/USERNAME/$USERNAME/" "$TOOLS/wordpress/wp-fail2ban.conf" >/etc/logrotate.d/wp-fail2ban.conf

docker network inspect "$USERNAME" >/dev/null 2>&1 || docker network create "$USERNAME" >/dev/null
docker network inspect database >/dev/null 2>&1 || docker network create database >/dev/null
docker compose -f "$SERVER/docker-compose.yml" up -d --quiet-pull

# ---------------------------------------------------------------------------
# Backups and maintenance timers
# ---------------------------------------------------------------------------
step "Backup and maintenance timers"
install -m 755 "$TOOLS/backup/server-backup.sh" /usr/local/sbin/server-backup
install -m 755 "$TOOLS/backup/setup-backups.sh" /usr/local/sbin/setup-backups
install -m 755 "$TOOLS/update-cloudflare-ips.sh" /usr/local/sbin/update-cloudflare-ips
for unit in serverBackup.service serverBackup.timer cloudflareIps.service cloudflareIps.timer \
  reloadFail2ban.service reloadFail2ban.timer npmReload.service npmReload.path; do
  sed "s/USERNAME/$USERNAME/g" "$TOOLS/systemd/$unit" >"/etc/systemd/system/$unit"
done
systemctl daemon-reload
systemctl enable -q --now serverBackup.timer cloudflareIps.timer reloadFail2ban.timer npmReload.path

# ---------------------------------------------------------------------------
# Shell
# ---------------------------------------------------------------------------
BASHRC="$HOME_DIR/.bashrc"
if ! grep -q '# docker-server-setup' "$BASHRC"; then
  cat >>"$BASHRC" <<'EOF'

# docker-server-setup
alias dcu="docker compose up -d"
alias dcd="docker compose down"
alias dcr="docker compose restart"
alias andybz="$HOME/server/tools/andybz.sh"
alias ctop="docker run --rm -ti --volume /var/run/docker.sock:/var/run/docker.sock:ro quay.io/vektorlab/ctop:latest"
echo -e "\nPortainer: \e[34mhttp://localhost:6900\n\e[0mNginx Proxy Manager: \e[34mhttp://localhost:6901\n\e[0mphpMyAdmin: \e[34mhttp://localhost:6902\n\e[0mFile Browser: \e[34mhttp://localhost:6903\n\e[0mDozzle: \e[34mhttp://localhost:6905\e[0m\n"
"$HOME/server/tools/firewall.sh" first-login
EOF
fi
[ "$SSH_PORT" != 22 ] && touch "$HOME_DIR/.setup-pending" && chown "$USERNAME:" "$HOME_DIR/.setup-pending"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
trap - ERR
PUBLIC_IP=$(curl -4 -fsS --max-time 5 https://ifconfig.me || hostname -I | awk '{print $1}')
echo -e "\n${GREEN}Setup complete 👍${ENDCOLOR}"
echo -e "\nAdd this to ~/.ssh/config on your computer, then log in with: ssh $(hostname -s)\n"
cat <<EOF
Host $(hostname -s)
    HostName $PUBLIC_IP
    Port $SSH_PORT
    User $USERNAME
    LocalForward 6900 127.0.0.1:6900
    LocalForward 6901 127.0.0.1:6901
    LocalForward 6902 127.0.0.1:6902
    LocalForward 6903 127.0.0.1:6903
    LocalForward 6905 127.0.0.1:6905
    ServerAliveInterval 60
    ServerAliveCountMax 10
EOF
echo -e "\n${YELLOW}Next steps:${ENDCOLOR}"
echo "  1. Log in as $USERNAME on port $SSH_PORT. Port 22 closes automatically on that first login."
echo "  2. Set up off-site backups: sudo setup-backups   (until then the nightly backup reports a failure)"
echo "  3. Optional: allow only ports 80, 443 and $SSH_PORT in your cloud provider's firewall too."
echo "  4. File Browser's first admin password: docker logs filebrowser 2>&1 | grep password"
echo "  5. Your MariaDB root password is in ~/server/.env"

if [ -f /var/run/reboot-required ]; then
  if [ -z "${REBOOT:-}" ]; then
    read -r -p "A reboot is needed to finish installing updates. Reboot now (y/n)? " yn
    [[ $yn =~ ^[Yy]$ ]] && REBOOT=yes
  fi
  [ "${REBOOT:-}" = yes ] && reboot
fi
