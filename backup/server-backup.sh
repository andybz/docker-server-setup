#!/usr/bin/env bash
#
# Nightly server backup (installed as /usr/local/sbin/server-backup, run as root
# by serverBackup.timer):
#   1. dumps every MariaDB database to ~/server/backups/mariadb (kept 7 days)
#   2. sends ~/sites and ~/server to the off-site restic repository set up by
#      setup-backups, then prunes old snapshots
#
# Settings come from /etc/server-setup.conf (USERNAME, optional HEALTHCHECK_URL,
# LOCAL_KEEP_DAYS) and the repository from /root/.restic.env.

set -Eeuo pipefail
umask 077

CONF=/etc/server-setup.conf
RESTIC_ENV=/root/.restic.env
# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"

USERNAME="${USERNAME:?USERNAME is not set in $CONF}"
HOME_DIR="/home/$USERNAME"
DUMP_DIR="$HOME_DIR/server/backups/mariadb"
LOCAL_KEEP_DAYS="${LOCAL_KEEP_DAYS:-7}"

log() { echo "$(date '+%F %T') $*"; }

# optional dead-man's switch, e.g. https://hc-ping.com/<uuid>
ping_healthcheck() {
  [ -n "${HEALTHCHECK_URL:-}" ] || return 0
  curl -fsS -m 10 --retry 3 "${HEALTHCHECK_URL}${1:-}" >/dev/null || true
}

trap 'log "backup FAILED (line $LINENO)"; ping_healthcheck /fail' ERR

# never run two backups at once
exec 9>/run/server-backup.lock
flock -n 9 || { log "another backup is running, skipping"; exit 0; }

ping_healthcheck /start

# ---------------------------------------------------------------------------
# 1. Database dumps
# ---------------------------------------------------------------------------
mkdir -p "$DUMP_DIR"
chmod 700 "$DUMP_DIR"
stamp=$(date +%F)

# works with both the official mariadb image and the older linuxserver one
# shellcheck disable=SC2016 # expanded inside the container, not here
ROOT_PW_EXPR='${MARIADB_ROOT_PASSWORD:-$MYSQL_ROOT_PASSWORD}'

databases=$(docker exec mariadb sh -c "MYSQL_PWD=\"$ROOT_PW_EXPR\" mariadb -N -uroot -e 'show databases'" |
  grep -vxE 'information_schema|performance_schema|mysql|sys')

for db in $databases; do
  out="$DUMP_DIR/$db-$stamp.sql.gz"
  docker exec -e DB="$db" mariadb sh -c \
    "MYSQL_PWD=\"$ROOT_PW_EXPR\" mariadb-dump -uroot --single-transaction --quick --routines --events \"\$DB\"" |
    gzip -6 >"$out.tmp"
  gzip -t "$out.tmp"
  mv "$out.tmp" "$out"
  log "dumped $db ($(du -h "$out" | cut -f1))"
done

find "$DUMP_DIR" -name '*.sql.gz' -mtime +"$LOCAL_KEEP_DAYS" -delete

# ---------------------------------------------------------------------------
# 2. Off-site copy
# ---------------------------------------------------------------------------
if [ ! -r "$RESTIC_ENV" ]; then
  log "ERROR: no off-site repository configured. Run: sudo setup-backups"
  log "Only local database dumps were made; they are lost if this server is."
  ping_healthcheck /fail
  exit 2
fi

set -a
# shellcheck source=/dev/null
. "$RESTIC_ENV"
set +a

restic unlock --quiet || true

restic backup --quiet --tag nightly --exclude-caches \
  --exclude "$HOME_DIR/sites/*/wordpress/wp-content/cache" \
  --exclude "$HOME_DIR/sites/*/wordpress/wp-content/w3tc-config" \
  --exclude "$HOME_DIR/server/npm/data/logs" \
  --exclude "$HOME_DIR/server/portainer" \
  "$HOME_DIR/sites" "$HOME_DIR/server" "$CONF"
log "off-site snapshot saved"

restic forget --quiet --tag nightly --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
log "old snapshots pruned"

# weekly integrity check that also reads back a sample of the stored data
if [ "$(date +%u)" = 7 ]; then
  restic check --quiet --read-data-subset=5%
  log "repository check passed"
fi

ping_healthcheck
log "backup finished"
