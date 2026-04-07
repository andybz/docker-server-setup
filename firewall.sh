#! /bin/bash

set -e

# runs on first login to set up and save firewall rules

SSH_PORT=REPLACE_ME

read -p "$(echo -e "\e[32mWelcome! The last thing we need to do is set up and save firewall rules. Do you want to do this now (y/n)?\e[0m ")" yn

if [[ ! $yn =~ ^[Yy]$ ]]; then
  echo "Goodbye. This script will run again next time you log in."
  exit
fi

if ! command -v iptables > /dev/null 2>&1; then
  echo -e "\n\e[31miptables not found. Install iptables and rerun this script.\e[0m\n"
  exit 1
fi

if ! command -v netfilter-persistent > /dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  sudo apt update -y
  sudo apt install iptables-persistent -y
fi

# allow return traffic for outgoing connections initiated by the server itself
sudo iptables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
  sudo iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# allow loopback
sudo iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || sudo iptables -A INPUT -i lo -j ACCEPT
# allow http, https, ssh
if [[ "$SSH_PORT" != "22" ]]; then
  SSH_PORTS="22,$SSH_PORT"
else
  SSH_PORTS="22"
fi
sudo iptables -C INPUT -p tcp -m multiport --dports 80,443,"$SSH_PORTS" -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT 2>/dev/null || \
  sudo iptables -A INPUT -p tcp -m multiport --dports 80,443,"$SSH_PORTS" -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT
# set input policy to drop everything else
sudo iptables --policy INPUT DROP

sudo netfilter-persistent save

echo -e "\n\e[32mFirewall configured 👍. If you didn't save rules, please run sudo netfilter-persistent save :)\e[0m\n"

rm ~/firewall.sh