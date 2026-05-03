#!/bin/sh
# PingReports linux agent installer.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/PingReports/linux-agent/main/install.sh | sudo PR_AGENT_ID=... PR_AGENT_TOKEN=... sh
#
# What it does:
#   1. Detects the package manager (apt / dnf / yum / zypper / pacman).
#   2. Asks for confirmation, then installs curl + gzip + coreutils + util-linux.
#   3. Creates a system user 'pingreports-agent' (no shell, no home).
#   4. Drops agent.sh under /usr/local/lib/pingreports-agent/.
#   5. Writes /etc/pingreports-agent/agent.conf with the IDs/token.
#   6. Generates a randomized 5-minute schedule offset so 1000 hosts don't
#      stomp on the sink at :00:00.
#   7. Installs systemd units (service + timer) and starts the timer.
#
# Re-running the installer with the same env updates config + binary in
# place; it is idempotent.

set -eu

AGENT_USER="pingreports-agent"
AGENT_HOME="/var/lib/pingreports-agent"
AGENT_LIB="/usr/local/lib/pingreports-agent"
AGENT_CONF_DIR="/etc/pingreports-agent"
AGENT_CONF="$AGENT_CONF_DIR/agent.conf"
SVC_NAME="pingreports-agent.service"
TMR_NAME="pingreports-agent.timer"
DEFAULT_INGEST="https://agents-pr.sxp.dev/v1/ingest"

PR_AGENT_VERSION="0.2.0"

if [ "$(id -u)" -ne 0 ]; then
  echo "install.sh must be run as root (sudo)." >&2
  exit 1
fi

require() { command -v "$1" >/dev/null 2>&1; }

PM=""
if require apt-get; then PM=apt
elif require dnf; then PM=dnf
elif require yum; then PM=yum
elif require zypper; then PM=zypper
elif require pacman; then PM=pacman
else
  echo "Unsupported distribution — no apt/dnf/yum/zypper/pacman found." >&2
  exit 1
fi

PKG_LIST="curl gzip coreutils util-linux"
case "$PM" in
  apt) PKG_LIST="$PKG_LIST" ;;
  dnf|yum) PKG_LIST="curl gzip coreutils util-linux" ;;
  zypper) PKG_LIST="curl gzip coreutils util-linux" ;;
  pacman) PKG_LIST="curl gzip coreutils util-linux" ;;
esac

assume_yes="${PR_ASSUME_YES:-}"
if [ -t 0 ] && [ -z "$assume_yes" ]; then
  printf 'PingReports agent installer\n'
  printf '  package manager : %s\n' "$PM"
  printf '  packages        : %s\n' "$PKG_LIST"
  printf '  agent user      : %s\n' "$AGENT_USER"
  printf '  config          : %s\n' "$AGENT_CONF"
  printf '  systemd units   : %s, %s\n' "$SVC_NAME" "$TMR_NAME"
  printf 'Proceed? [y/N] '
  read -r ans || ans=""
  case "$ans" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 0 ;; esac
fi

PR_AGENT_ID="${PR_AGENT_ID:-}"
PR_AGENT_TOKEN="${PR_AGENT_TOKEN:-}"
PR_INGEST_URL="${PR_INGEST_URL:-$DEFAULT_INGEST}"
PR_AGENT_NAME="${PR_AGENT_NAME:-$(hostname)}"
PR_AGENT_TAGS="${PR_AGENT_TAGS:-}"

if [ -z "$PR_AGENT_ID" ] || [ -z "$PR_AGENT_TOKEN" ]; then
  if [ -r "$AGENT_CONF" ]; then
    # Allow re-running the installer to refresh binaries without re-passing
    # the credentials. Read whatever's already on disk.
    # shellcheck disable=SC1090
    . "$AGENT_CONF"
  fi
fi

if [ -z "${PR_AGENT_ID:-}" ] || [ -z "${PR_AGENT_TOKEN:-}" ]; then
  echo "PR_AGENT_ID and PR_AGENT_TOKEN must be set (env or /etc/pingreports-agent/agent.conf)." >&2
  exit 1
fi

install_pkgs() {
  case "$PM" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $PKG_LIST
      ;;
    dnf) dnf install -y -q $PKG_LIST ;;
    yum) yum install -y -q $PKG_LIST ;;
    zypper) zypper -nq install -y $PKG_LIST ;;
    pacman) pacman -Sy --noconfirm --needed $PKG_LIST ;;
  esac
}

install_pkgs

# 3. user
if ! id -u "$AGENT_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$AGENT_HOME" --shell /usr/sbin/nologin --create-home "$AGENT_USER" \
    || useradd -r -d "$AGENT_HOME" -s /usr/sbin/nologin -m "$AGENT_USER"
fi
mkdir -p "$AGENT_HOME" "$AGENT_LIB" "$AGENT_CONF_DIR"
chown -R "$AGENT_USER:$AGENT_USER" "$AGENT_HOME"
chmod 0750 "$AGENT_HOME"

# 3b. Optional group memberships for extended metrics. Each is opt-in:
# - PR_GRANT_DOCKER=1   → docker group (required to read `docker ps/stats`)
# - PR_GRANT_PODMAN=1   → podman socket group (varies; podman is often rootless)
# - PR_GRANT_LIBVIRT=1  → libvirt + libvirt-qemu groups (read VM stats)
# - PR_GRANT_KVM=1      → kvm group (lets the agent see /dev/kvm caps)
#
# When stdin is interactive AND the matching group exists on the host AND
# the relevant tool is installed, prompt; otherwise honour the env flag and
# default OFF. The agent gracefully skips collectors it can't read.
maybe_add_group() {
  flag_name="$1"  # PR_GRANT_DOCKER etc
  group_name="$2"
  reason="$3"
  flag_val=$(eval "printf '%s' \"\${$flag_name:-}\"")
  if ! getent group "$group_name" >/dev/null 2>&1; then
    return 0
  fi
  if [ "$flag_val" = "1" ] || [ "$flag_val" = "true" ] || [ "$flag_val" = "yes" ]; then
    add=1
  elif [ "$flag_val" = "0" ] || [ "$flag_val" = "false" ] || [ "$flag_val" = "no" ]; then
    add=0
  elif [ -t 0 ] && [ -z "$assume_yes" ]; then
    printf 'Add %s to group "%s"? %s [y/N] ' "$AGENT_USER" "$group_name" "$reason"
    read -r ans </dev/tty 2>/dev/null || ans=""
    case "$ans" in y|Y|yes|YES) add=1 ;; *) add=0 ;; esac
  else
    add=0
  fi
  if [ "$add" = "1" ]; then
    if usermod -aG "$group_name" "$AGENT_USER" 2>/dev/null; then
      echo "  + added $AGENT_USER to group $group_name"
    fi
  fi
}

if require docker; then
  maybe_add_group PR_GRANT_DOCKER docker "(reads container CPU / mem / net stats)"
fi
if require podman; then
  for g in podman containers; do
    if getent group "$g" >/dev/null 2>&1; then
      maybe_add_group PR_GRANT_PODMAN "$g" "(reads podman container stats)"
      break
    fi
  done
fi
if require virsh; then
  for g in libvirt libvirtd; do
    if getent group "$g" >/dev/null 2>&1; then
      maybe_add_group PR_GRANT_LIBVIRT "$g" "(reads VM list + per-VM CPU / mem)"
      break
    fi
  done
  if getent group libvirt-qemu >/dev/null 2>&1; then
    maybe_add_group PR_GRANT_LIBVIRT libvirt-qemu "(reads QEMU process info)"
  fi
fi
if [ -e /dev/kvm ]; then
  maybe_add_group PR_GRANT_KVM kvm "(detect KVM accel availability)"
fi

# 4. agent binary (this script's sibling). The installer ships agent.sh
# either alongside itself (curl-piped install pulls it via INSTALL_SOURCE_URL)
# or as a tarball.
: "${PR_AGENT_BRANCH:=main}"
SRC="${PR_AGENT_SRC:-https://raw.githubusercontent.com/PingReports/linux-agent/${PR_AGENT_BRANCH}/agent.sh}"
if [ -r "$(dirname "$0")/agent.sh" ] && [ -z "${PR_AGENT_FORCE_REMOTE:-}" ]; then
  install -m 0755 "$(dirname "$0")/agent.sh" "$AGENT_LIB/agent.sh"
else
  curl -fsSL --proto '=https' --tlsv1.2 -o "$AGENT_LIB/agent.sh.new" "$SRC"
  chmod 0755 "$AGENT_LIB/agent.sh.new"
  mv -f "$AGENT_LIB/agent.sh.new" "$AGENT_LIB/agent.sh"
fi

# 5. config (rendered fresh each run)
umask 077
cat > "$AGENT_CONF.new" <<EOF
# PingReports linux agent — generated by install.sh, ok to edit.
PR_AGENT_ID="$PR_AGENT_ID"
PR_AGENT_TOKEN="$PR_AGENT_TOKEN"
PR_AGENT_NAME="$PR_AGENT_NAME"
PR_AGENT_VERSION="$PR_AGENT_VERSION"
PR_AGENT_TAGS="$PR_AGENT_TAGS"
PR_INGEST_URL="$PR_INGEST_URL"
PR_DISK_PATHS="${PR_DISK_PATHS:-/}"
PR_NET_IFACES="${PR_NET_IFACES:-}"
PR_HTTP_TIMEOUT="${PR_HTTP_TIMEOUT:-30}"
PR_QUEUE_MAX="${PR_QUEUE_MAX:-50}"
EOF
chmod 0640 "$AGENT_CONF.new"
chown root:"$AGENT_USER" "$AGENT_CONF.new"
mv -f "$AGENT_CONF.new" "$AGENT_CONF"
umask 022

# 6. randomized schedule. The timer fires at every 5 minutes from a random
# offset within a 5-minute window so 10k hosts spread evenly.
if [ -r /dev/urandom ]; then
  OFFSET_S="$(od -An -N2 -tu2 < /dev/urandom | awk '{print $1 % 300}')"
else
  OFFSET_S="$(awk 'BEGIN{srand(); print int(rand()*300)}')"
fi
RANDOM_DELAY_S=30  # extra jitter applied by systemd

# 7. systemd units
cat > "/etc/systemd/system/$SVC_NAME" <<EOF
[Unit]
Description=PingReports linux agent oneshot
Documentation=https://github.com/PingReports/linux-agent
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$AGENT_USER
Group=$AGENT_USER
ExecStart=/usr/local/lib/pingreports-agent/agent.sh
Environment=PR_AGENT_CONF=$AGENT_CONF
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$AGENT_HOME
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictNamespaces=true
RestrictRealtime=true
LockPersonality=true
MemoryDenyWriteExecute=true
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
CapabilityBoundingSet=
AmbientCapabilities=
EOF

cat > "/etc/systemd/system/$TMR_NAME" <<EOF
[Unit]
Description=PingReports linux agent — every 5 minutes, jittered

[Timer]
OnBootSec=${OFFSET_S}s
OnUnitActiveSec=300s
RandomizedDelaySec=${RANDOM_DELAY_S}s
AccuracySec=5s
Persistent=true
Unit=$SVC_NAME

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now "$TMR_NAME" >/dev/null 2>&1 || systemctl enable --now "$TMR_NAME"

# Run once immediately so the operator sees an entry in the UI without
# having to wait for the first jittered tick.
systemctl start "$SVC_NAME" >/dev/null 2>&1 || true

echo "PingReports agent installed."
echo "  config : $AGENT_CONF"
echo "  binary : $AGENT_LIB/agent.sh"
echo "  user   : $AGENT_USER"
echo "  groups : $(id -nG "$AGENT_USER" 2>/dev/null | tr ' ' ',')"
echo "  schedule: every 5min (boot offset ${OFFSET_S}s + ${RANDOM_DELAY_S}s jitter)"
echo "  status : systemctl status $TMR_NAME"
echo "  logs   : journalctl -u $SVC_NAME -f"
