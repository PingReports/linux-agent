#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "uninstall.sh must be run as root." >&2
  exit 1
fi

systemctl disable --now pingreports-agent.timer 2>/dev/null || true
systemctl stop pingreports-agent.service 2>/dev/null || true
rm -f /etc/systemd/system/pingreports-agent.timer
rm -f /etc/systemd/system/pingreports-agent.service
systemctl daemon-reload

rm -rf /usr/local/lib/pingreports-agent
rm -rf /etc/pingreports-agent
rm -rf /var/lib/pingreports-agent

if id -u pingreports-agent >/dev/null 2>&1; then
  userdel pingreports-agent 2>/dev/null || true
fi

echo "PingReports agent removed."
