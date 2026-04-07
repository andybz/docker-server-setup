#! /bin/bash

CUR_USER="$(whoami)"

read -r -p "Enter site name or abbreviation (lowercase, no spaces): " sitename

if [ -d "/home/$CUR_USER/sites/$sitename" ]
then
  echo -e "\e[31mFolder exists. Exiting..."
  exit;
fi

mkdir -p "/home/$CUR_USER/sites/$sitename/wordpress"
curl -s https://raw.githubusercontent.com/andybz/docker-server-setup/main/wordpress/docker-compose.yml > "/home/$CUR_USER/sites/$sitename/docker-compose.yml"
curl -s https://raw.githubusercontent.com/andybz/docker-server-setup/main/wordpress/.htninja > "/home/$CUR_USER/sites/$sitename/.htninja"
curl -s https://raw.githubusercontent.com/andybz/docker-server-setup/main/wordpress/redis.conf > "/home/$CUR_USER/sites/$sitename/redis.conf"

read -r -p 'Type "YES" if this site requires PHP 7: ' oldphp

if [ "$oldphp" == "YES" ]
then
  echo "Using PHP 7..."
  sed -i "s/docker-wordpress-8/docker-wordpress-7/" "/home/$CUR_USER/sites/$sitename/docker-compose.yml"
fi

# replace yml with site name
sed -i "s/CHANGE_TO_SITE_NAME/$sitename/" "/home/$CUR_USER/sites/$sitename/docker-compose.yml"
sed -i "s/CHANGE_TO_USERNAME/$CUR_USER/" "/home/$CUR_USER/sites/$sitename/docker-compose.yml"
# sed -i "s/CHANGE_TO_TZ/$(timedatectl show | grep zone | sed 's/Timezone=//')/" "/home/$CUR_USER/sites/$sitename/docker-compose.yml"

echo -e "\n\e[32mSite created at /home/$CUR_USER/sites/$sitename/wordpress\e[0m\n"

read -r -p "Create database now (y/n)? "
if [[ $REPLY =~ ^[Yy]$ ]]
then
  ANDYBZ_DB="${sitename//-/_}"
  ANDYBZ_DB_USER="u_${sitename//-/_}"
  ANDYBZ_DB_PASS=$(< /dev/urandom tr -dc A-Z-a-z-0-9 | head -c"${1:-16}")
  docker exec -e ANDYBZ_DB="$ANDYBZ_DB" -e ANDYBZ_DB_USER="$ANDYBZ_DB_USER" -e ANDYBZ_DB_PASS="$ANDYBZ_DB_PASS" mariadb /bin/bash -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE $ANDYBZ_DB; CREATE USER '\''$ANDYBZ_DB_USER'\''; SET PASSWORD FOR '\''$ANDYBZ_DB_USER'\'' = PASSWORD('\''$ANDYBZ_DB_PASS'\''); GRANT ALL PRIVILEGES ON $ANDYBZ_DB.* TO '\''$ANDYBZ_DB_USER'\''; FLUSH PRIVILEGES;"'
  echo -e "\n\e[36mDatabase:\e[0m $ANDYBZ_DB"
  echo -e "\e[36mUser:\e[0m $ANDYBZ_DB_USER"
  echo -e "\e[36mPassword:\e[0m $ANDYBZ_DB_PASS"
  echo -e "\e[36mHost:\e[0m mariadb\n"
fi


read -r -p "Start site now and create a fresh wp installation (y/n)? "
if [[ ! $REPLY =~ ^[Yy]$ ]]
then
  docker compose -f "/home/$CUR_USER/sites/$sitename/docker-compose.yml" create
  echo -e "\n\e[36mChanging owner of site directory...\e[0m"
  # fix permissions for wordpress directory
  sudo chown nobody: "/home/$CUR_USER/sites/$sitename/wordpress"
  echo "Upload your files and start the site later 👍"
  rm ~/.newsite.sh
  exit;
fi

# start site
docker compose -f "/home/$CUR_USER/sites/$sitename/docker-compose.yml" up -d

echo "Site created 👍"

rm ~/.newsite.sh
