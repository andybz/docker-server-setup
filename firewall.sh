#!/usr/bin/env bash
#
# Host firewall for IPv4 and IPv6 (lives in ~/server/tools).
#
#   sudo ./firewall.sh apply <ssh_port>   allow 80, 443, <ssh_port> and, until the
#                                         new port is proven, 22
#   sudo ./firewall.sh close-22           drop port 22 from the firewall and sshd
#   ./firewall.sh first-login             run from .bashrc: closes port 22 the
#                                         first time you log in on the new port
#
# Only INPUT is filtered. Docker's published ports go through FORWARD and are
# NOT covered here, which is why every admin UI in docker-compose.yml binds to
# 127.0.0.1. Never publish a port as "8080:80" unless it should be public.

set -Eeuo pipefail

CONF=/etc/server-setup.conf
# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"

need_root() { [ "$(id -u)" -eq 0 ] || { echo "Run with sudo"; exit 1; }; }

write_rules_files() {
  local ports=$1
  mkdir -p /etc/iptables
  for family in v4 v6; do
    {
      echo "*filter"
      echo ":INPUT DROP [0:0]"
      echo ":FORWARD ACCEPT [0:0]"
      echo ":OUTPUT ACCEPT [0:0]"
      echo "-A INPUT -i lo -j ACCEPT"
      echo "-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
      echo "-A INPUT -p tcp -m multiport --dports $ports -m conntrack --ctstate NEW -j ACCEPT"
      [ "$family" = v6 ] && echo "-A INPUT -p ipv6-icmp -j ACCEPT"
      echo "COMMIT"
    } >"/etc/iptables/rules.$family"
  done
}

apply_rules() {
  local ports=$1
  for T in iptables ip6tables; do
    $T -C INPUT -i lo -j ACCEPT 2>/dev/null || $T -A INPUT -i lo -j ACCEPT
    $T -C INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null ||
      $T -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    # add the new port rule before removing the old one, so SSH is never cut off
    $T -C INPUT -p tcp -m multiport --dports "$ports" -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null ||
      $T -A INPUT -p tcp -m multiport --dports "$ports" -m conntrack --ctstate NEW -j ACCEPT
    $T -S INPUT | grep -E -- "--dports [0-9,]+ -m conntrack --ctstate NEW -j ACCEPT" |
      grep -vF -- "--dports $ports " | sed 's/^-A/-D/' | while read -r rule; do
      # shellcheck disable=SC2086
      $T $rule
    done
  done
  ip6tables -C INPUT -p ipv6-icmp -j ACCEPT 2>/dev/null || ip6tables -A INPUT -p ipv6-icmp -j ACCEPT
  iptables -P INPUT DROP
  ip6tables -P INPUT DROP
  # saved by hand rather than with netfilter-persistent save, which would also
  # store Docker's chains and restore stale copies of them at boot
  write_rules_files "$ports"
}

case "${1:-}" in
  apply)
    need_root
    port=${2:?usage: firewall.sh apply <ssh_port>}
    ports="80,443,$port"
    [ "$port" != 22 ] && ports="$ports,22"
    apply_rules "$ports"
    echo "Firewall: allowing tcp $ports (IPv4 and IPv6), dropping everything else."
    ;;

  close-22)
    need_root
    port=${SSH_PORT:?SSH_PORT is not set in $CONF}
    [ "$port" = 22 ] && { echo "SSH runs on port 22; nothing to close."; exit 0; }
    apply_rules "80,443,$port"
    sed -i '/^Port 22$/d' /etc/ssh/sshd_config.d/00-hardening.conf
    sshd -t
    systemctl daemon-reload
    if systemctl is-active --quiet ssh.socket; then systemctl restart ssh.socket; else systemctl restart ssh; fi
    sed -i "s/^port = .*/port = $port/" /etc/fail2ban/jail.d/sshd.local 2>/dev/null && systemctl restart fail2ban || true
    echo "Port 22 closed. SSH now only listens on $port."
    ;;

  first-login)
    [ -f "$HOME/.setup-pending" ] || exit 0
    server_port=${SSH_CONNECTION##* }
    if [ -n "${SSH_PORT:-}" ] && [ "$server_port" = "$SSH_PORT" ]; then
      echo -e "\e[32mYou're logged in on port $SSH_PORT, so the temporary port 22 can be closed.\e[0m"
      sudo "$0" close-22 && rm -f "$HOME/.setup-pending"
      echo -e "\nNext: set up off-site backups with \e[36msudo setup-backups\e[0m\n"
    else
      echo -e "\e[33mSetup isn't finished: log in once on port ${SSH_PORT:-?} to close port 22.\e[0m"
    fi
    ;;

  *)
    sed -n '3,12p' "$0"
    exit 1
    ;;
esac
