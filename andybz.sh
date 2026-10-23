#!/usr/bin/env bash
#
# andybz - server helper menu (runs from ~/server/tools; alias: andybz)

TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITES="$HOME/sites"
SERVER="$HOME/server"
JAIL_LOCAL="$SERVER/fail2ban/data/jail.d/jail.local"
GEOIP_CONF="$SERVER/npm/data/nginx/custom/http_top.conf"

# wp-cli inside a site container, as the nobody user that owns the files
wp_in() {
  local site=$1
  shift
  docker exec -u 65534:65534 -e HOME=/tmp "$site" wp --path=/usr/src/wordpress "$@"
}

fail2ban_jails() {
  docker exec fail2ban fail2ban-client status | sed -n 's/.*Jail list:[[:space:]]*//p' | tr -d ','
}

valid_ip() {
  python3 -c 'import ipaddress,sys; ipaddress.ip_network(sys.argv[1], strict=False)' "$1" 2>/dev/null
}

select_project() {
  echo "==========================="
  echo " SELECT PROJECT"
  echo "==========================="
  local sites=()
  for d in "$SITES"/*/; do [ -f "$d/docker-compose.yml" ] && sites+=("$(basename "$d")"); done
  if [ ${#sites[@]} -eq 0 ]; then
    echo "No sites found in $SITES"
    exit 1
  fi
  PS3="> "
  select sitename in "${sites[@]}"; do
    [ -n "$sitename" ] && break
    echo ">>> Invalid Selection"
  done
}

PS3="Choose action: "

select action in "Start site" "Stop Site" "Create Site" "Delete Site & Files" "Restart Site" "Fix Permissions" \
  "Add SSH Key" "Container Shell" "Fail2ban Status" "Unban IP" "Whitelist IP" "Blacklist IP" \
  "Prune Docker Images" "MariaDB Upgrade" "Ban Country" "Unban Country" "DB Search Replace" \
  "Backup Now" "Backup Status" "Update Server Containers" "Update Tools" "Quit"; do
  case $action in
    "Start site")
      select_project
      docker compose -f "$SITES/$sitename/docker-compose.yml" up -d
      echo -e "\e[32mSite started 👍\e[0m"
      break ;;

    "Stop Site")
      select_project
      docker compose -f "$SITES/$sitename/docker-compose.yml" stop
      echo -e "\e[32mSite stopped 👍\e[0m"
      break ;;

    "Restart Site")
      select_project
      docker compose -f "$SITES/$sitename/docker-compose.yml" restart
      echo -e "\e[32mSite restarted 👍\e[0m"
      break ;;

    "Create Site")
      "$TOOLS/newsite.sh"
      break ;;

    "Delete Site & Files")
      select_project
      dir="$SITES/$sitename"
      # guard against anything but a real site folder directly inside ~/sites
      if [ -z "$sitename" ] || [ "$(dirname "$(realpath "$dir")")" != "$(realpath "$SITES")" ]; then
        echo -e "\e[31mRefusing to delete '$dir'.\e[0m"
        break
      fi
      echo -e "\e[31mThis permanently deletes $dir, its containers and (optionally) its database.\e[0m"
      read -r -p "Type the site name ($sitename) to confirm: " confirm
      if [ "$confirm" != "$sitename" ]; then
        echo "Names don't match. Nothing deleted."
        break
      fi
      docker compose -f "$dir/docker-compose.yml" down
      if [ -f "$dir/.db-credentials" ]; then
        db=$(sed -n 's/^DB_NAME=//p' "$dir/.db-credentials")
        db_user=$(sed -n 's/^DB_USER=//p' "$dir/.db-credentials")
        read -r -p "Also drop database '$db' and user '$db_user' (y/n)? " yn
        if [[ $yn =~ ^[Yy]$ ]]; then
          docker exec -e DB="$db" -e DB_USER="$db_user" mariadb sh -c '
            MYSQL_PWD="${MARIADB_ROOT_PASSWORD:-$MYSQL_ROOT_PASSWORD}" mariadb -uroot -e \
              "DROP DATABASE IF EXISTS \`$DB\`; DROP USER IF EXISTS \`$DB_USER\`@\`%\`;"'
        fi
      fi
      sudo rm -r -- "$dir"
      echo -e "\e[32m$sitename deleted 👍\e[0m"
      break ;;

    "Fix Permissions")
      select_project
      sudo chown -R nobody: "$SITES/$sitename/wordpress"
      sudo find "$SITES/$sitename" -type d -exec chmod 755 {} +
      sudo find "$SITES/$sitename/wordpress" -type f -exec chmod 644 {} +
      echo -e "\e[32mPermissions updated 👍\e[0m"
      break ;;

    "Add SSH Key")
      read -r -p "Please paste your public SSH key: " sshkey
      if ssh-keygen -l -f <(echo "$sshkey") >/dev/null 2>&1; then
        echo "$sshkey" >>"$HOME/.ssh/authorized_keys"
        echo -e "\e[32mSSH key added 👍\e[0m"
      else
        echo -e "\e[31mThat doesn't look like a valid public key. Nothing added.\e[0m"
      fi
      break ;;

    "Container Shell")
      select_project
      echo -e "\e[36mConnecting shell for $sitename...\e[0m"
      docker exec -it "$sitename" ash
      break ;;

    "Fail2ban Status")
      for jail in $(fail2ban_jails); do docker exec fail2ban fail2ban-client status "$jail"; done
      echo -e "\n\e[36mSSH jail (host):\e[0m"
      sudo fail2ban-client status sshd
      break ;;

    "Unban IP")
      read -r -p "Enter IP Address: " ip
      valid_ip "$ip" || { echo -e "\e[31mInvalid IP.\e[0m"; break; }
      for jail in $(fail2ban_jails); do docker exec fail2ban fail2ban-client set "$jail" unbanip "$ip" >/dev/null 2>&1; done
      sudo fail2ban-client unban "$ip" >/dev/null 2>&1
      echo -e "\e[32m$ip has been unbanned. If it should never be banned, whitelist it as well 👍\e[0m"
      break ;;

    "Whitelist IP")
      read -r -p "Enter IP address or range (e.g. 203.0.113.7 or 203.0.113.0/24): " ip
      valid_ip "$ip" || { echo -e "\e[31mInvalid IP.\e[0m"; break; }
      sudo sed -i "0,/^ignoreip = /s|^ignoreip = .*|& $ip|" "$JAIL_LOCAL"
      docker exec fail2ban fail2ban-client reload >/dev/null
      echo -e "\e[32m$ip has been whitelisted. If it's currently banned, unban it as well 👍\e[0m"
      break ;;

    "Blacklist IP")
      read -r -p "Enter IP Address to ban: " ip
      valid_ip "$ip" || { echo -e "\e[31mInvalid IP.\e[0m"; break; }
      for jail in $(fail2ban_jails); do docker exec fail2ban fail2ban-client set "$jail" banip "$ip" >/dev/null; done
      echo -e "\e[32m$ip has been banned in all jails 👍\e[0m"
      break ;;

    "Prune Docker Images")
      docker image prune -a
      break ;;

    "MariaDB Upgrade")
      # the official image upgrades itself on start (MARIADB_AUTO_UPGRADE); this forces it
      docker exec mariadb sh -c 'MYSQL_PWD="${MARIADB_ROOT_PASSWORD:-$MYSQL_ROOT_PASSWORD}" mariadb-upgrade -uroot'
      break ;;

    "DB Search Replace")
      select_project
      read -r -p "Enter search string: " search
      read -r -p "Enter replace string: " replace
      [ -n "$search" ] || { echo "Search string can't be empty."; break; }
      echo -e "\n\e[36mDry run (nothing changed yet):\e[0m"
      wp_in "$sitename" search-replace "$search" "$replace" --all-tables --dry-run --report-changed-only || break
      read -r -p "Apply these changes (y/n)? " yn
      [[ $yn =~ ^[Yy]$ ]] || break
      backup="$SITES/$sitename/db-before-replace-$(date +%Y%m%d-%H%M%S).sql.gz"
      (umask 077 && wp_in "$sitename" db export - | gzip >"$backup")
      echo "Database backed up to $backup"
      wp_in "$sitename" search-replace "$search" "$replace" --all-tables
      wp_in "$sitename" cache flush
      break ;;

    "Ban Country")
      echo -e "\e[36mCurrently banned countries:\e[0m"
      grep -E '^    [A-Z]{2} 1;' "$GEOIP_CONF" 2>/dev/null | awk '{print "  " $1}' || echo "  (none)"
      read -r -p "Enter 2-letter country code to ban (e.g. CN, RU): " countrycode
      countrycode=$(echo "$countrycode" | tr '[:lower:]' '[:upper:]')
      if [[ ! "$countrycode" =~ ^[A-Z]{2}$ ]]; then
        echo -e "\e[31mInvalid country code. Must be exactly 2 letters.\e[0m"
      elif grep -q "^    $countrycode 1;" "$GEOIP_CONF" 2>/dev/null; then
        echo -e "\e[33m$countrycode is already banned.\e[0m"
      else
        sudo sed -i "/^}$/i\    $countrycode 1;" "$GEOIP_CONF"
        docker exec nginx-proxy-manager nginx -s reload
        echo -e "\e[32m$countrycode has been banned and nginx reloaded 👍\e[0m"
      fi
      break ;;

    "Unban Country")
      echo -e "\e[36mCurrently banned countries:\e[0m"
      grep -E '^    [A-Z]{2} 1;' "$GEOIP_CONF" 2>/dev/null | awk '{print "  " $1}' || echo "  (none)"
      read -r -p "Enter 2-letter country code to unban: " countrycode
      countrycode=$(echo "$countrycode" | tr '[:lower:]' '[:upper:]')
      if [[ ! "$countrycode" =~ ^[A-Z]{2}$ ]]; then
        echo -e "\e[31mInvalid country code. Must be exactly 2 letters.\e[0m"
      elif ! grep -q "^    $countrycode 1;" "$GEOIP_CONF" 2>/dev/null; then
        echo -e "\e[33m$countrycode is not currently banned.\e[0m"
      else
        sudo sed -i "/^    $countrycode 1;$/d" "$GEOIP_CONF"
        docker exec nginx-proxy-manager nginx -s reload
        echo -e "\e[32m$countrycode has been unbanned and nginx reloaded 👍\e[0m"
      fi
      break ;;

    "Backup Now")
      echo -e "\e[36mRunning backup (this can take a while)...\e[0m"
      if sudo systemctl start serverBackup.service; then
        echo -e "\e[32mBackup finished 👍\e[0m"
      else
        echo -e "\e[31mBackup failed:\e[0m"
      fi
      sudo journalctl -u serverBackup.service -n 15 --no-pager -o cat
      break ;;

    "Backup Status")
      systemctl list-timers serverBackup.timer --no-pager
      echo
      sudo journalctl -u serverBackup.service -n 15 --no-pager -o cat
      echo
      if sudo test -r /root/.restic.env; then
        sudo bash -c 'set -a; . /root/.restic.env; set +a; restic snapshots --compact --latest 10'
      else
        echo -e "\e[31mNo off-site backup configured. Run: sudo setup-backups\e[0m"
      fi
      break ;;

    "Update Server Containers")
      # Watchtower only updates sites and phpMyAdmin; update the rest deliberately
      docker compose -f "$SERVER/docker-compose.yml" pull
      docker compose -f "$SERVER/docker-compose.yml" up -d
      echo -e "\e[32mServer containers updated 👍\e[0m"
      break ;;

    "Update Tools")
      git -C "$TOOLS" pull --ff-only
      echo -e "\e[33mTools updated. Review what changed: git -C $TOOLS log -5\e[0m"
      break ;;

    "Quit")
      echo "Goodbye 👍"
      break ;;

    *)
      echo "huh?" ;;
  esac
done
