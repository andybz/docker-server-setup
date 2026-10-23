#!/usr/bin/env bash
#
# Set up (or re-point) the off-site backup repository used by server-backup.
# Installed as /usr/local/sbin/setup-backups. Run as root: sudo setup-backups
#
# Supported destinations:
#   1) Backblaze B2
#   2) S3-compatible storage (AWS S3, DigitalOcean Spaces, Wasabi, Cloudflare R2,
#      Hetzner Object Storage, ...)
#   3) SFTP (Hetzner Storage Box, another server, a NAS)
#
# Everything is encrypted by restic before it leaves the server. The repository
# password is generated here and shown ONCE: store it in your password manager,
# because without it the backups cannot be restored.

set -Eeuo pipefail
umask 077

RESTIC_ENV=/root/.restic.env
CONF=/etc/server-setup.conf

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo setup-backups"; exit 1; }

if ! command -v restic >/dev/null; then
  apt-get update -qq && apt-get install -y -qq restic >/dev/null
fi

if [ -f "$RESTIC_ENV" ]; then
  read -r -p "A backup repository is already configured. Replace it (y/n)? " yn
  [[ $yn =~ ^[Yy]$ ]] || exit 0
  cp -p "$RESTIC_ENV" "$RESTIC_ENV.bak.$(date +%s)"
fi

echo "Where should backups go?"
echo "  1) Backblaze B2"
echo "  2) S3-compatible (AWS, DigitalOcean Spaces, Wasabi, R2, Hetzner Object Storage)"
echo "  3) SFTP (Hetzner Storage Box, another server)"
read -r -p "Choose 1-3: " choice

host=$(hostname -s)
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

case "$choice" in
  1)
    read -r -p "B2 bucket name: " bucket
    read -r -p "B2 keyID: " key_id
    read -r -s -p "B2 applicationKey (hidden): " app_key; echo
    {
      echo "RESTIC_REPOSITORY=b2:$bucket:$host"
      echo "B2_ACCOUNT_ID=$key_id"
      echo "B2_ACCOUNT_KEY=$app_key"
    } >"$tmp"
    ;;
  2)
    read -r -p "Endpoint (e.g. nyc3.digitaloceanspaces.com, s3.us-east-1.amazonaws.com): " endpoint
    read -r -p "Bucket name: " bucket
    read -r -p "Access key ID: " key_id
    read -r -s -p "Secret access key (hidden): " secret; echo
    read -r -p "Region (leave empty if not needed): " region
    {
      echo "RESTIC_REPOSITORY=s3:https://${endpoint#https://}/$bucket/$host"
      echo "AWS_ACCESS_KEY_ID=$key_id"
      echo "AWS_SECRET_ACCESS_KEY=$secret"
      [ -n "$region" ] && echo "AWS_DEFAULT_REGION=$region"
    } >"$tmp"
    ;;
  3)
    read -r -p "SFTP user@host (e.g. u123456@u123456.your-storagebox.de): " target
    read -r -p "SFTP port [22]: " port
    port=${port:-22}
    read -r -p "Remote directory [backups/$host]: " remote_dir
    remote_dir=${remote_dir:-backups/$host}
    key=/root/.ssh/backup_ed25519
    mkdir -p /root/.ssh
    [ -f "$key" ] || ssh-keygen -q -t ed25519 -N '' -C "backup@$host" -f "$key"
    sftp_host=${target#*@}
    if ! grep -q "^Host backup-target$" /root/.ssh/config 2>/dev/null; then
      cat >>/root/.ssh/config <<EOF

Host backup-target
    HostName $sftp_host
    User ${target%@*}
    Port $port
    IdentityFile $key
    IdentitiesOnly yes
    ServerAliveInterval 60
EOF
    fi
    echo
    echo "Add this public key to the SFTP account's authorized keys, then press Enter:"
    echo
    cat "$key.pub"
    echo
    read -r -p "Press Enter once the key is installed..."
    ssh -o StrictHostKeyChecking=accept-new backup-target exit 2>/dev/null || true
    echo "RESTIC_REPOSITORY=sftp:backup-target:$remote_dir" >"$tmp"
    ;;
  *)
    echo "Invalid choice"; exit 1 ;;
esac

if [ -f "$RESTIC_ENV" ] && grep -q '^RESTIC_PASSWORD=' "$RESTIC_ENV"; then
  grep '^RESTIC_PASSWORD=' "$RESTIC_ENV" >>"$tmp"
  echo "Keeping the existing repository password."
else
  echo "RESTIC_PASSWORD=$(openssl rand -base64 33 | tr -d '/+=' | cut -c1-40)" >>"$tmp"
fi

install -m 600 "$tmp" "$RESTIC_ENV"

set -a
# shellcheck source=/dev/null
. "$RESTIC_ENV"
set +a

if restic cat config >/dev/null 2>&1; then
  echo "Connected to the existing repository."
else
  restic init
fi

read -r -p "Healthcheck URL to ping after each backup (optional, e.g. https://hc-ping.com/...): " hc
if [ -n "$hc" ]; then
  touch "$CONF"
  sed -i '/^HEALTHCHECK_URL=/d' "$CONF"
  echo "HEALTHCHECK_URL=$hc" >>"$CONF"
fi

echo
echo "================================================================="
echo " Repository password (store it in your password manager NOW;"
echo " without it these backups can never be restored):"
echo
echo "   $RESTIC_PASSWORD"
echo
echo " It is also saved in $RESTIC_ENV on this server."
echo "================================================================="
echo

read -r -p "Run the first backup now (y/n)? " yn
if [[ $yn =~ ^[Yy]$ ]]; then
  systemctl start serverBackup.service
  journalctl -u serverBackup.service -n 20 --no-pager
fi

cat <<'EOF'

Useful commands (as root, after: set -a; . /root/.restic.env; set +a):
  restic snapshots                         list backups
  restic ls latest /home                   browse the latest backup
  restic restore latest --target /tmp/r --include /home/USER/sites/SITE
                                           restore one site into /tmp/r
EOF
