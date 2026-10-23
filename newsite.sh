#!/usr/bin/env bash
#
# Create a WordPress site in ~/sites/<name> with its own Redis and database.
# Run via: andybz -> Create Site

set -Eeuo pipefail

TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUR_USER="$(whoami)"
SITES="$HOME/sites"

read -r -p "Site name (lowercase letters, digits and dashes, e.g. acme-co): " sitename
if [[ ! $sitename =~ ^[a-z][a-z0-9-]{1,30}$ ]]; then
  echo -e "\e[31mInvalid name. Use 2-31 lowercase letters, digits or dashes, starting with a letter.\e[0m"
  exit 1
fi

dir="$SITES/$sitename"
if [ -e "$dir" ]; then
  echo -e "\e[31m$dir already exists. Exiting.\e[0m"
  exit 1
fi

mkdir -p "$dir/wordpress"
sed "s/CHANGE_TO_SITE_NAME/$sitename/g; s/CHANGE_TO_USERNAME/$CUR_USER/g" \
  "$TOOLS/wordpress/docker-compose.yml" >"$dir/docker-compose.yml"
cp "$TOOLS/wordpress/.htninja" "$TOOLS/wordpress/redis.conf" "$dir/"

echo -e "\n\e[32mSite created at $dir/wordpress\e[0m\n"

read -r -p "Create database now (y/n)? " yn
if [[ $yn =~ ^[Yy]$ ]]; then
  db="${sitename//-/_}"
  db_user="u_${db}"
  db_pass=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-24)
  docker exec -e DB="$db" -e DB_USER="$db_user" -e DB_PASS="$db_pass" mariadb sh -c '
    MYSQL_PWD="${MARIADB_ROOT_PASSWORD:-$MYSQL_ROOT_PASSWORD}" mariadb -uroot -e "
      CREATE DATABASE \`$DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
      CREATE USER \`$DB_USER\`@\`%\` IDENTIFIED BY \"$DB_PASS\";
      GRANT ALL PRIVILEGES ON \`$DB\`.* TO \`$DB_USER\`@\`%\`;"'
  (
    umask 077
    printf "DB_NAME=%s\nDB_USER=%s\nDB_PASSWORD=%s\nDB_HOST=mariadb\n" "$db" "$db_user" "$db_pass" >"$dir/.db-credentials"
  )
  unset db_pass
  echo -e "\n\e[36mDatabase:\e[0m $db"
  echo -e "\e[36mUser:\e[0m     $db_user"
  echo -e "\e[36mHost:\e[0m     mariadb"
  echo -e "\e[36mPassword:\e[0m saved in $dir/.db-credentials (readable only by you)\n"
fi

read -r -p "Start the site now with a fresh WordPress install (y/n)? " yn
if [[ ! $yn =~ ^[Yy]$ ]]; then
  docker compose -f "$dir/docker-compose.yml" create
  sudo chown nobody: "$dir/wordpress"
  echo "Upload your files to $dir/wordpress and start the site later (andybz -> Start site) 👍"
  echo "Tip: a .sql file placed in wordpress/ is imported automatically on first start if the database is empty."
else
  docker compose -f "$dir/docker-compose.yml" up -d
  echo "Site started 👍"
fi

echo -e "\nIn Nginx Proxy Manager, add a proxy host forwarding to \e[36mhttp://$sitename:80\e[0m."
