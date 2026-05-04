#!/bin/sh
# PingReports linux agent — metric collector + uploader.
#
# Runs as the unprivileged pingreports-agent user under systemd. Wakes on
# the timer, samples host metrics + inventory, gzips a JSON payload,
# POSTs to the configured ingest endpoint with a Bearer token, then
# exits. POSIX sh — Debian/Ubuntu/RHEL/Alma/Rocky/SUSE/Arch all in scope.

set -eu

CONF_FILE="${PR_AGENT_CONF:-/etc/pingreports-agent/agent.conf}"
STATE_DIR="${PR_AGENT_STATE_DIR:-/var/lib/pingreports-agent}"
QUEUE_DIR="$STATE_DIR/queue"
LOG_TAG="pingreports-agent"

log() { logger -t "$LOG_TAG" -- "$1" 2>/dev/null || echo "$LOG_TAG: $1" >&2; }
die() { log "ERROR: $1"; exit 1; }

[ -r "$CONF_FILE" ] || die "config not readable: $CONF_FILE"
# shellcheck disable=SC1090
. "$CONF_FILE"

: "${PR_AGENT_ID:?PR_AGENT_ID missing}"
: "${PR_AGENT_TOKEN:?PR_AGENT_TOKEN missing}"
: "${PR_INGEST_URL:?PR_INGEST_URL missing}"
PR_AGENT_NAME="${PR_AGENT_NAME:-$(hostname)}"
PR_AGENT_VERSION="${PR_AGENT_VERSION:-0.3.0}"
PR_NET_IFACES="${PR_NET_IFACES:-}"
PR_DISK_PATHS="${PR_DISK_PATHS:-/}"
PR_HTTP_TIMEOUT="${PR_HTTP_TIMEOUT:-30}"
PR_QUEUE_MAX="${PR_QUEUE_MAX:-50}"
PR_TOP_N="${PR_TOP_N:-20}"
PR_SERVICES_MAX="${PR_SERVICES_MAX:-300}"

mkdir -p "$QUEUE_DIR"

PAYLOAD="$(mktemp)"
GZ="$(mktemp)"
trap 'rm -f "$PAYLOAD" "$GZ"' EXIT INT TERM

now_iso() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
now_epoch() { date +%s; }
have() { command -v "$1" >/dev/null 2>&1; }

# json_escape — escape a single value for embedding in a JSON string literal.
json_escape() {
  awk 'BEGIN{
    for (i=0;i<32;i++) tab[sprintf("%c",i)]=sprintf("\\u%04x",i);
    tab["\""]="\\\""; tab["\\"]="\\\\"; tab["\b"]="\\b"; tab["\f"]="\\f";
    tab["\n"]="\\n"; tab["\r"]="\\r"; tab["\t"]="\\t";
  }
  { for (i=1;i<=length($0);i++){c=substr($0,i,1); printf "%s", (c in tab)?tab[c]:c} printf "" }'
}

# ---------------------------------------------------------------------------
# Time-series metric collectors. Each prints "name=value" or
# "name{k=\"v\"}=value" lines to stdout. Failures are non-fatal.
# ---------------------------------------------------------------------------

collect_cpu() {
  if [ -r /proc/stat ]; then
    awk '/^cpu /{
      idle=$5+$6; total=$2+$3+$4+$5+$6+$7+$8+$9;
      printf "cpu_user=%d\ncpu_system=%d\ncpu_idle=%d\ncpu_iowait=%d\ncpu_irq=%d\ncpu_softirq=%d\ncpu_steal=%d\ncpu_total=%d\n",
        $2, $4, $5, $6, $7, $8, $9, total }' /proc/stat
  fi
  if [ -r /proc/stat ]; then
    awk '/^ctxt/{ printf "cpu_ctxt=%d\n", $2 }
         /^processes/{ printf "cpu_forks=%d\n", $2 }
         /^procs_running/{ printf "cpu_procs_running=%d\n", $2 }
         /^procs_blocked/{ printf "cpu_procs_blocked=%d\n", $2 }
         /^intr/{ printf "cpu_intr=%d\n", $2 }' /proc/stat
  fi
}

collect_load() {
  if [ -r /proc/loadavg ]; then
    awk '{ printf "load1=%s\nload5=%s\nload15=%s\nproc_running=%s\nproc_total=%s\n",
           $1, $2, $3,
           ($4 ~ /\//) ? substr($4, 1, index($4,"/")-1) : 0,
           ($4 ~ /\//) ? substr($4, index($4,"/")+1) : 0 }' /proc/loadavg
  fi
}

collect_mem() {
  if [ -r /proc/meminfo ]; then
    awk '
      /^MemTotal:/      { tot=$2 }
      /^MemAvailable:/  { avail=$2 }
      /^MemFree:/       { free=$2 }
      /^Buffers:/       { buf=$2 }
      /^Cached:/        { cache=$2 }
      /^SwapTotal:/     { stot=$2 }
      /^SwapFree:/      { sfree=$2 }
      /^Dirty:/         { dirty=$2 }
      /^Slab:/          { slab=$2 }
      /^Shmem:/         { shmem=$2 }
      END {
        printf "mem_total_kb=%d\nmem_available_kb=%d\nmem_free_kb=%d\nmem_buffers_kb=%d\nmem_cached_kb=%d\nmem_dirty_kb=%d\nmem_slab_kb=%d\nmem_shmem_kb=%d\nswap_total_kb=%d\nswap_free_kb=%d\n",
          tot, avail, free, buf, cache, dirty, slab, shmem, stot, sfree
      }' /proc/meminfo
  fi
}

collect_disk() {
  oldifs="$IFS"; IFS=','
  for path in $PR_DISK_PATHS; do
    [ -d "$path" ] || continue
    df -PB1 "$path" 2>/dev/null | awk -v p="$path" 'NR==2 {
      printf "disk_size_bytes{path=\"%s\"}=%d\ndisk_used_bytes{path=\"%s\"}=%d\ndisk_avail_bytes{path=\"%s\"}=%d\n",
        p, $2, p, $3, p, $4
    }'
    df -Pi "$path" 2>/dev/null | awk -v p="$path" 'NR==2 {
      printf "disk_inodes_total{path=\"%s\"}=%d\ndisk_inodes_used{path=\"%s\"}=%d\n",
        p, $2, p, $3
    }'
  done
  IFS="$oldifs"
}

collect_diskio() {
  [ -r /proc/diskstats ] || return 0
  # /proc/diskstats: f0=major f1=minor f2=name f3=reads_done f4=reads_merged
  # f5=sectors_read f6=ms_reading f7=writes_done f8=writes_merged
  # f9=sectors_written f10=ms_writing f11=ios_in_progress f12=ms_io
  awk '{
    name=$3
    # Skip partitions of the same disk to keep cardinality bounded; we keep
    # whole-device entries (sd[a-z], nvmeNnN, vdN, dm-N) and root logical
    # volumes. Not perfect but cheap.
    if (name ~ /^loop/ || name ~ /^ram/ || name ~ /^sr[0-9]/) next
    if (name ~ /^sd[a-z]+[0-9]+$/) next
    if (name ~ /^nvme[0-9]+n[0-9]+p[0-9]+$/) next
    if (name ~ /^vd[a-z]+[0-9]+$/) next
    printf "diskio_reads{dev=\"%s\"}=%d\ndiskio_read_bytes{dev=\"%s\"}=%d\ndiskio_writes{dev=\"%s\"}=%d\ndiskio_write_bytes{dev=\"%s\"}=%d\ndiskio_busy_ms{dev=\"%s\"}=%d\ndiskio_inflight{dev=\"%s\"}=%d\n",
      name, $4, name, $6*512, name, $8, name, $10*512, name, $13, name, $12
  }' /proc/diskstats
}

collect_net() {
  [ -r /proc/net/dev ] || return 0
  awk -v want="$PR_NET_IFACES" '
    NR<=2 { next }
    {
      iface=$1; sub(/:/, "", iface);
      if (iface=="lo") next;
      if (want != "") {
        keep=0; n=split(want, w, ",");
        for (i=1;i<=n;i++) if (w[i]==iface) keep=1;
        if (!keep) next;
      }
      printf "net_rx_bytes{iface=\"%s\"}=%d\nnet_rx_packets{iface=\"%s\"}=%d\nnet_rx_errs{iface=\"%s\"}=%d\nnet_rx_drops{iface=\"%s\"}=%d\nnet_tx_bytes{iface=\"%s\"}=%d\nnet_tx_packets{iface=\"%s\"}=%d\nnet_tx_errs{iface=\"%s\"}=%d\nnet_tx_drops{iface=\"%s\"}=%d\n",
        iface, $2, iface, $3, iface, $4, iface, $5, iface, $10, iface, $11, iface, $12, iface, $13
    }' /proc/net/dev
  # Per-iface link speed (Mbps) when known.
  for d in /sys/class/net/*; do
    [ -e "$d" ] || continue
    name="$(basename "$d")"
    [ "$name" = "lo" ] && continue
    if [ -r "$d/speed" ]; then
      speed=$(cat "$d/speed" 2>/dev/null) || speed=""
      [ -n "$speed" ] && [ "$speed" -gt 0 ] 2>/dev/null && \
        printf 'net_link_mbps{iface="%s"}=%s\n' "$name" "$speed"
    fi
  done
}

collect_sockets() {
  [ -r /proc/net/sockstat ] || return 0
  awk '
    /^TCP:/ { for (i=2;i<=NF-1;i++) if ($i=="inuse") tcp_inuse=$(i+1); else if ($i=="tw") tcp_tw=$(i+1); else if ($i=="orphan") tcp_orphan=$(i+1) }
    /^UDP:/ { for (i=2;i<=NF-1;i++) if ($i=="inuse") udp_inuse=$(i+1) }
    /^sockets:/ { for (i=2;i<=NF-1;i++) if ($i=="used") used=$(i+1) }
    END {
      printf "sock_total=%d\nsock_tcp_inuse=%d\nsock_tcp_tw=%d\nsock_tcp_orphan=%d\nsock_udp_inuse=%d\n",
        used+0, tcp_inuse+0, tcp_tw+0, tcp_orphan+0, udp_inuse+0
    }' /proc/net/sockstat
  if have ss; then
    # ss is in iproute2; widely available.
    states=$(ss -antH 2>/dev/null | awk '{print $1}' | sort | uniq -c)
    [ -z "$states" ] && return 0
    printf '%s\n' "$states" | while read -r count state; do
      [ -z "$state" ] && continue
      printf 'sock_state{kind="tcp",state="%s"}=%d\n' "$state" "$count"
    done
    udp_listen=$(ss -anuH 2>/dev/null | wc -l | awk '{print $1}')
    [ -n "$udp_listen" ] && printf 'sock_state{kind="udp",state="LISTEN"}=%d\n' "$udp_listen"
  fi
}

collect_files() {
  if [ -r /proc/sys/fs/file-nr ]; then
    awk '{ printf "fd_open=%d\nfd_unused=%d\nfd_max=%d\n", $1, $2, $3 }' /proc/sys/fs/file-nr
  fi
}

collect_uptime() {
  [ -r /proc/uptime ] || return 0
  awk '{ printf "uptime_seconds=%d\nidle_seconds=%d\n", $1, $2 }' /proc/uptime
}

collect_users() {
  if have who; then
    n=$(who 2>/dev/null | wc -l | awk '{print $1}')
    printf 'users_logged_in=%s\n' "${n:-0}"
  fi
}

collect_proc_counts() {
  total=$(ls -1 /proc 2>/dev/null | grep -c '^[0-9]\+$' || echo 0)
  zombie=$(awk '/^State:.*Z/{c++} END{print c+0}' /proc/[0-9]*/status 2>/dev/null || echo 0)
  threads=$(awk '/^Threads:/{t+=$2} END{print t+0}' /proc/[0-9]*/status 2>/dev/null || echo 0)
  printf 'proc_count=%s\nproc_zombie=%s\nproc_threads=%s\n' "${total:-0}" "${zombie:-0}" "${threads:-0}"
}

collect_temps() {
  # lm-sensors: emit tempN per sensor if present.
  if have sensors; then
    sensors -A 2>/dev/null | awk '
      /^[A-Za-z0-9_-]+$/ { adapter=$1; next }
      /^Adapter:/ { next }
      /:/ {
        # Match "  Sensor Name:  +42.0°C  ..." or similar.
        n=split($0, parts, ":")
        if (n < 2) next
        label=parts[1]; sub(/^[ \t]+/, "", label); sub(/[ \t]+$/, "", label)
        gsub(/[^A-Za-z0-9_]/, "_", label)
        rest=parts[2]
        # Extract first numeric value (pcpu /pmem etc).
        if (match(rest, /[+-]?[0-9]+\.[0-9]+/)) {
          v = substr(rest, RSTART, RLENGTH)
          if (rest ~ /°C/ || rest ~ / C/) {
            printf "sensor_temp_c{name=\"%s\"}=%s\n", (adapter "_" label), v
          } else if (rest ~ / V/) {
            printf "sensor_volt{name=\"%s\"}=%s\n", (adapter "_" label), v
          } else if (rest ~ /RPM/) {
            printf "sensor_fan_rpm{name=\"%s\"}=%s\n", (adapter "_" label), v
          }
        }
      }'
  fi
}

collect_systemd_counts() {
  have systemctl || return 0
  total=$(systemctl list-units --type=service --no-pager --no-legend --plain 2>/dev/null | wc -l | awk '{print $1}')
  active=$(systemctl list-units --type=service --state=active --no-pager --no-legend --plain 2>/dev/null | wc -l | awk '{print $1}')
  failed=$(systemctl list-units --type=service --state=failed --no-pager --no-legend --plain 2>/dev/null | wc -l | awk '{print $1}')
  printf 'systemd_units_total=%s\nsystemd_units_active=%s\nsystemd_units_failed=%s\n' \
    "${total:-0}" "${active:-0}" "${failed:-0}"
}

collect_docker_metrics() {
  have docker || return 0
  docker info >/dev/null 2>&1 || return 0
  running=$(docker ps -q 2>/dev/null | wc -l | awk '{print $1}')
  total=$(docker ps -aq 2>/dev/null | wc -l | awk '{print $1}')
  images=$(docker images -q 2>/dev/null | wc -l | awk '{print $1}')
  printf 'docker_containers_running=%s\ndocker_containers_total=%s\ndocker_images=%s\n' \
    "${running:-0}" "${total:-0}" "${images:-0}"
  # Per-container resource usage. Limit to top-30 by ID order to bound cost.
  docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.NetIO}}|{{.BlockIO}}|{{.PIDs}}' 2>/dev/null \
    | head -30 \
    | while IFS='|' read -r name cpu mem netio blockio pids; do
        [ -z "$name" ] && continue
        cpu_n=$(printf '%s' "$cpu" | sed 's/%//')
        mem_b=$(printf '%s' "$mem" | awk -F/ '{print $1}' | tr -d '[:space:]' | awk '{
          v=$0; suf="";
          if (match(v, /[KMGTPE]i?B$/)) { suf=substr(v,RSTART,RLENGTH); v=substr(v,1,RSTART-1) }
          mul=1
          if (suf=="KiB" || suf=="KB") mul=1024
          else if (suf=="MiB" || suf=="MB") mul=1048576
          else if (suf=="GiB" || suf=="GB") mul=1073741824
          else if (suf=="TiB" || suf=="TB") mul=1099511627776
          printf "%d", v*mul
        }')
        net_rx=$(printf '%s' "$netio" | awk -F/ '{print $1}' | tr -d '[:space:]' | awk '{
          v=$0; suf="";
          if (match(v, /[KMGTPE]i?B$/)) { suf=substr(v,RSTART,RLENGTH); v=substr(v,1,RSTART-1) }
          mul=1
          if (suf=="KiB" || suf=="kB") mul=1024
          else if (suf=="MiB" || suf=="MB") mul=1048576
          else if (suf=="GiB" || suf=="GB") mul=1073741824
          printf "%d", v*mul
        }')
        net_tx=$(printf '%s' "$netio" | awk -F/ '{print $2}' | tr -d '[:space:]' | awk '{
          v=$0; suf="";
          if (match(v, /[KMGTPE]i?B$/)) { suf=substr(v,RSTART,RLENGTH); v=substr(v,1,RSTART-1) }
          mul=1
          if (suf=="KiB" || suf=="kB") mul=1024
          else if (suf=="MiB" || suf=="MB") mul=1048576
          else if (suf=="GiB" || suf=="GB") mul=1073741824
          printf "%d", v*mul
        }')
        printf 'docker_container_cpu_pct{name="%s"}=%s\n' "$name" "${cpu_n:-0}"
        [ -n "$mem_b" ] && printf 'docker_container_mem_bytes{name="%s"}=%s\n' "$name" "$mem_b"
        [ -n "$net_rx" ] && printf 'docker_container_net_rx_bytes{name="%s"}=%s\n' "$name" "$net_rx"
        [ -n "$net_tx" ] && printf 'docker_container_net_tx_bytes{name="%s"}=%s\n' "$name" "$net_tx"
        [ -n "$pids" ] && printf 'docker_container_pids{name="%s"}=%s\n' "$name" "$pids"
      done
}

collect_podman_metrics() {
  have podman || return 0
  podman info >/dev/null 2>&1 || return 0
  running=$(podman ps -q 2>/dev/null | wc -l | awk '{print $1}')
  total=$(podman ps -aq 2>/dev/null | wc -l | awk '{print $1}')
  images=$(podman images -q 2>/dev/null | wc -l | awk '{print $1}')
  printf 'podman_containers_running=%s\npodman_containers_total=%s\npodman_images=%s\n' \
    "${running:-0}" "${total:-0}" "${images:-0}"
}

collect_proc_metrics() {
  # Per-comm time-series metrics for the drill-down. We sum across all
  # PIDs of the same comm so the chart stays continuous when a process
  # restarts and gets a new pid.
  #
  # Cardinality is bounded by emitting only the UNION of the top-N by
  # CPU and top-N by RSS — same set the inventory drill-down will show
  # as clickable rows. Without this the user can click a memory-heavy
  # process that never appears in CPU top-N and the per-comm chart
  # stays empty.
  ps -eo pcpu,pmem,rss,comm --no-headers 2>/dev/null \
    | awk -v top="$PR_TOP_N" '
        {
          sub(/^[ \t]+/, "")
          pcpu=$1; pmem=$2; rss=$3; comm=$4
          if (comm == "ps" || comm == "awk" || comm == "sort" || comm == "sed" \
              || comm == "agent.sh" || comm == "logger" || comm == "wc" \
              || comm == "tail" || comm == "head" || comm == "tr" \
              || comm == "cut" || comm == "mktemp" || comm == "rm") next
          gsub(/[^a-zA-Z0-9_.-]/, "_", comm)
          if (length(comm) == 0) next
          cpu_by[comm] += pcpu + 0
          mem_by[comm] += pmem + 0
          rss_by[comm] += rss + 0
        }
        END {
          # Build CPU-sorted and RSS-sorted lists.
          n=0
          for (c in cpu_by) { sorted_cpu[++n] = cpu_by[c] "\t" c; sorted_rss[n] = rss_by[c] "\t" c }
          # Insertion-sort both arrays descending — small N.
          for (i=2; i<=n; i++) {
            x = sorted_cpu[i]; split(x, p, "\t"); xv = p[1] + 0
            j = i - 1
            while (j >= 1) { split(sorted_cpu[j], q, "\t"); if (q[1] + 0 < xv) { sorted_cpu[j+1] = sorted_cpu[j]; j-- } else break }
            sorted_cpu[j+1] = x
            x = sorted_rss[i]; split(x, p, "\t"); xv = p[1] + 0
            j = i - 1
            while (j >= 1) { split(sorted_rss[j], q, "\t"); if (q[1] + 0 < xv) { sorted_rss[j+1] = sorted_rss[j]; j-- } else break }
            sorted_rss[j+1] = x
          }
          # Union of top-N CPU and top-N RSS.
          delete keep
          for (i=1; i<=n && i<=top; i++) { split(sorted_cpu[i], p, "\t"); keep[p[2]] = 1 }
          for (i=1; i<=n && i<=top; i++) { split(sorted_rss[i], p, "\t"); keep[p[2]] = 1 }
          for (c in keep) {
            printf "proc_cpu_pct{comm=\"%s\"}=%s\n", c, cpu_by[c]
            printf "proc_mem_pct{comm=\"%s\"}=%s\n", c, mem_by[c]
            printf "proc_rss_kb{comm=\"%s\"}=%s\n",  c, rss_by[c]
          }
        }'
}

collect_gpu_metrics() {
  # NVIDIA via nvidia-smi. Each line: idx,util_pct,mem_used_mb,mem_total_mb,
  # temp_c,power_w,fan_pct,clk_sm,clk_mem.
  if have nvidia-smi; then
    nvidia-smi --query-gpu=index,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,fan.speed,clocks.sm,clocks.mem,utilization.memory \
               --format=csv,noheader,nounits 2>/dev/null \
      | while IFS=, read -r idx util mem_u mem_t temp pwr fan clk_sm clk_mem util_mem; do
          idx=$(printf '%s' "$idx" | tr -d '[:space:]')
          [ -z "$idx" ] && continue
          util=$(printf '%s' "$util" | tr -d '[:space:]'); [ -z "$util" ] || [ "$util" = "[N/A]" ] && util=0
          util_mem=$(printf '%s' "$util_mem" | tr -d '[:space:]'); [ -z "$util_mem" ] || [ "$util_mem" = "[N/A]" ] && util_mem=0
          mem_u=$(printf '%s' "$mem_u" | tr -d '[:space:]'); [ -z "$mem_u" ] || [ "$mem_u" = "[N/A]" ] && mem_u=0
          mem_t=$(printf '%s' "$mem_t" | tr -d '[:space:]'); [ -z "$mem_t" ] || [ "$mem_t" = "[N/A]" ] && mem_t=0
          temp=$(printf '%s' "$temp" | tr -d '[:space:]'); [ -z "$temp" ] || [ "$temp" = "[N/A]" ] && temp=0
          pwr=$(printf '%s' "$pwr" | tr -d '[:space:]'); [ -z "$pwr" ] || [ "$pwr" = "[N/A]" ] && pwr=0
          fan=$(printf '%s' "$fan" | tr -d '[:space:]'); [ -z "$fan" ] || [ "$fan" = "[N/A]" ] && fan=0
          clk_sm=$(printf '%s' "$clk_sm" | tr -d '[:space:]'); [ -z "$clk_sm" ] || [ "$clk_sm" = "[N/A]" ] && clk_sm=0
          clk_mem=$(printf '%s' "$clk_mem" | tr -d '[:space:]'); [ -z "$clk_mem" ] || [ "$clk_mem" = "[N/A]" ] && clk_mem=0
          mem_u_b=$(awk -v v="$mem_u" 'BEGIN{printf "%d", v*1048576}')
          mem_t_b=$(awk -v v="$mem_t" 'BEGIN{printf "%d", v*1048576}')
          printf 'gpu_util_pct{idx="%s",vendor="nvidia"}=%s\n' "$idx" "$util"
          printf 'gpu_mem_util_pct{idx="%s",vendor="nvidia"}=%s\n' "$idx" "$util_mem"
          printf 'gpu_mem_used_bytes{idx="%s",vendor="nvidia"}=%s\n' "$idx" "$mem_u_b"
          printf 'gpu_mem_total_bytes{idx="%s",vendor="nvidia"}=%s\n' "$idx" "$mem_t_b"
          printf 'gpu_temp_c{idx="%s",vendor="nvidia"}=%s\n' "$idx" "$temp"
          printf 'gpu_power_w{idx="%s",vendor="nvidia"}=%s\n' "$idx" "$pwr"
          printf 'gpu_fan_pct{idx="%s",vendor="nvidia"}=%s\n' "$idx" "$fan"
          printf 'gpu_clock_sm_mhz{idx="%s",vendor="nvidia"}=%s\n' "$idx" "$clk_sm"
          printf 'gpu_clock_mem_mhz{idx="%s",vendor="nvidia"}=%s\n' "$idx" "$clk_mem"
        done
  fi
  # AMD GPUs via rocm-smi (if ROCm installed). Lighter coverage; not a goal
  # for v0.3.0 — leave as a stub the next bump can fill.
  :
}

collect_pending_updates() {
  # Returns three counters — total updatable, security-flagged subset, and
  # whether a reboot is required. Cached by the package manager so this
  # is cheap per push.
  if have apt-get && [ -r /var/lib/apt/lists ]; then
    total=$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l | awk '{print $1}')
    sec=$(apt list --upgradable 2>/dev/null | tail -n +2 | grep -ic 'security' || true)
    [ -z "$sec" ] && sec=0
    printf 'updates_pending=%s\nupdates_security=%s\n' "${total:-0}" "${sec:-0}"
  elif have dnf; then
    total=$(dnf -q check-update 2>/dev/null | grep -Ec '^[a-zA-Z]' || true)
    sec=$(dnf -q check-update --security 2>/dev/null | grep -Ec '^[a-zA-Z]' || true)
    printf 'updates_pending=%s\nupdates_security=%s\n' "${total:-0}" "${sec:-0}"
  elif have yum; then
    total=$(yum -q check-update 2>/dev/null | grep -Ec '^[a-zA-Z]' || true)
    printf 'updates_pending=%s\nupdates_security=0\n' "${total:-0}"
  elif have zypper; then
    total=$(zypper -q list-updates 2>/dev/null | grep -c '^v ' || true)
    printf 'updates_pending=%s\nupdates_security=0\n' "${total:-0}"
  fi
  if [ -e /var/run/reboot-required ] || [ -e /run/reboot-required ]; then
    printf 'reboot_required=1\n'
  else
    printf 'reboot_required=0\n'
  fi
}

collect_libvirt_metrics() {
  have virsh || return 0
  virsh list --all >/dev/null 2>&1 || return 0
  running=$(virsh list --state-running --name 2>/dev/null | grep -c . || echo 0)
  total=$(virsh list --all --name 2>/dev/null | grep -c . || echo 0)
  printf 'libvirt_vms_running=%s\nlibvirt_vms_total=%s\n' "${running:-0}" "${total:-0}"
  # Per-VM stats (running only).
  virsh list --state-running --name 2>/dev/null | while read -r vm; do
    [ -z "$vm" ] && continue
    info=$(virsh dominfo "$vm" 2>/dev/null) || continue
    cpus=$(printf '%s' "$info" | awk -F: '/CPU\(s\)/{gsub(/[ \t]/,"",$2); print $2; exit}')
    mem=$(printf '%s' "$info" | awk -F: '/Used memory/{gsub(/[ \t]/,"",$2); sub(/KiB$/,"",$2); print $2*1024; exit}')
    [ -n "$cpus" ] && printf 'libvirt_vm_cpus{name="%s"}=%s\n' "$vm" "$cpus"
    [ -n "$mem" ] && printf 'libvirt_vm_mem_bytes{name="%s"}=%s\n' "$vm" "$mem"
  done
}

# ---------------------------------------------------------------------------
# Inventory snapshots — single JSON object per push, stored on Agent.last_inventory.
# ---------------------------------------------------------------------------

inventory_capabilities() {
  # Two-state probe per capability: present (binary or device exists) and
  # accessible (we can actually use it as the agent's user). Agents
  # installed via `curl|sh` without an interactive TTY skip the optional
  # group-membership prompts (docker / libvirt / podman / kvm), so a
  # libvirt-host can end up with virsh on PATH but pingreports-agent NOT
  # in the libvirt group → present=true, accessible=false. The UI uses
  # that gap to show "permission denied — run `usermod -aG libvirt
  # pingreports-agent && systemctl restart pingreports-agent.timer`".
  has_docker=false; docker_present=false
  have docker && docker_present=true && docker info >/dev/null 2>&1 && has_docker=true
  has_podman=false; podman_present=false
  have podman && podman_present=true && podman info >/dev/null 2>&1 && has_podman=true
  has_libvirt=false; libvirt_present=false
  if have virsh && { [ -S /var/run/libvirt/libvirt-sock ] || [ -S /var/run/libvirt/libvirt-sock-ro ] || pgrep -x libvirtd >/dev/null 2>&1; }; then
    libvirt_present=true
  fi
  if [ "$libvirt_present" = "true" ] && virsh list --all >/dev/null 2>&1; then
    has_libvirt=true
  fi
  has_kvm=false; kvm_present=false
  [ -e /dev/kvm ] && kvm_present=true && [ -r /dev/kvm ] && has_kvm=true
  has_sensors=false; have sensors && sensors -A >/dev/null 2>&1 && has_sensors=true
  has_systemd=false; have systemctl && has_systemd=true
  has_gpu=false; (have nvidia-smi && nvidia-smi -L >/dev/null 2>&1) && has_gpu=true
  has_apt=false; have apt-get && has_apt=true
  has_dnf=false; have dnf && has_dnf=true
  # Emit capabilities + a parallel "present" map so UI can highlight
  # binary-installed-but-permission-denied capabilities.
  printf '"capabilities":{"docker":%s,"podman":%s,"libvirt":%s,"kvm":%s,"sensors":%s,"systemd":%s,"gpu":%s,"apt":%s,"dnf":%s},' \
    "$has_docker" "$has_podman" "$has_libvirt" "$has_kvm" "$has_sensors" "$has_systemd" "$has_gpu" "$has_apt" "$has_dnf"
  printf '"capability_present":{"docker":%s,"podman":%s,"libvirt":%s,"kvm":%s}' \
    "$docker_present" "$podman_present" "$libvirt_present" "$kvm_present"
}

# Note: the systemd-unit lookup is now inlined into _proc_extra_json with
# the same `set +e` safety net so a single bad cgroup file can't fail the
# whole batch.

_proc_extra_json() {
  # Emit JSON fragments for /proc/<pid>/{status,io,fd}. Best-effort —
  # /proc/<pid>/io requires ptrace privileges even for same-uid access on
  # most kernels, so silently fall back to zero. We disable `set -e`
  # locally so any awk/ls EACCES is just an empty value, not a fatal exit.
  set +e
  pid="$1"
  threads=0
  state="?"
  num_fds=0
  ctxt_voluntary=0
  ctxt_nonvoluntary=0
  read_bytes=0
  write_bytes=0
  if [ -r "/proc/$pid/status" ]; then
    t=$(awk '/^Threads:/{print $2; exit}' "/proc/$pid/status" 2>/dev/null) ; [ -n "$t" ] && threads="$t"
    s=$(awk '/^State:/{print $2; exit}' "/proc/$pid/status" 2>/dev/null) ; [ -n "$s" ] && state="$s"
    cv=$(awk '/^voluntary_ctxt_switches:/{print $2; exit}' "/proc/$pid/status" 2>/dev/null) ; [ -n "$cv" ] && ctxt_voluntary="$cv"
    cn=$(awk '/^nonvoluntary_ctxt_switches:/{print $2; exit}' "/proc/$pid/status" 2>/dev/null) ; [ -n "$cn" ] && ctxt_nonvoluntary="$cn"
  fi
  if [ -r "/proc/$pid/io" ]; then
    rb=$(awk '/^read_bytes:/{print $2; exit}' "/proc/$pid/io" 2>/dev/null) ; [ -n "$rb" ] && read_bytes="$rb"
    wb=$(awk '/^write_bytes:/{print $2; exit}' "/proc/$pid/io" 2>/dev/null) ; [ -n "$wb" ] && write_bytes="$wb"
  fi
  if [ -d "/proc/$pid/fd" ]; then
    n=$(ls -1 "/proc/$pid/fd" 2>/dev/null | wc -l | awk '{print $1}') ; [ -n "$n" ] && num_fds="$n"
  fi
  unit=""
  if [ -r "/proc/$pid/cgroup" ]; then
    unit=$(awk -F: '$1=="0" || $2=="name=systemd" {
        p=$3; n=split(p, parts, "/")
        for (i=n;i>=1;i--) {
          if (parts[i] ~ /\.(service|scope|target|socket|timer|mount|slice)$/) {
            print parts[i]; exit
          }
        }
      }' "/proc/$pid/cgroup" 2>/dev/null)
  fi
  printf '"threads":%s,"state":"%s","fds":%s,"ctxt_v":%s,"ctxt_nv":%s,"io_read_bytes":%s,"io_write_bytes":%s,"unit":"%s"' \
    "$threads" "$state" "$num_fds" \
    "$ctxt_voluntary" "$ctxt_nonvoluntary" \
    "$read_bytes" "$write_bytes" \
    "$(printf '%s' "$unit" | json_escape)"
  set -e
}

inventory_top_processes() {
  # Tab-separated process snapshot (POSIX-portable). Columns:
  # pid \t user \t pcpu \t pmem \t rss \t comm \t args.
  #
  # Filter out the agent's own helper processes — ps / awk / sort / sed
  # / json_escape / agent.sh itself ALWAYS show up at the top of the CPU
  # list because they are running while we sample. Keeping them in
  # would make the operator see "pingreports-agent at 100% CPU" instead
  # of the actual workload.
  src="$(mktemp)"
  ps -eo pid,user:20,pcpu,pmem,rss,comm,args --no-headers 2>/dev/null \
    | awk -v me="$$" '
        {
          sub(/^[ \t]+/, "")
          pid=$1; user=$2; pcpu=$3; pmem=$4; rss=$5; comm=$6
          if (user == "pingreports+" || user == "pingreports-agent") next
          if (comm == "ps" || comm == "awk" || comm == "sort" || comm == "sed" \
              || comm == "agent.sh" || comm == "json_escape" || comm == "logger" \
              || comm == "wc" || comm == "tail" || comm == "head" || comm == "tr" \
              || comm == "cut" || comm == "mktemp" || comm == "rm") next
          $1=$2=$3=$4=$5=$6=""
          sub(/^[ \t]+/, "")
          args=$0
          gsub(/\t/, " ", args)
          printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", pid, user, pcpu, pmem, rss, comm, args
        }' > "$src"

  emit_proc_array() {
    sort_key="$1"  # 3 = pcpu, 5 = rss
    out_label="$2"
    printf '"%s":[' "$out_label"
    join_tmp="$(mktemp)"
    sort -t '	' -k"$sort_key,$sort_key" -gr "$src" 2>/dev/null | head -"$PR_TOP_N" \
      | while IFS='	' read -r pid user pcpu pmem rss comm args; do
          [ -z "$pid" ] && continue
          args_short=$(printf '%s' "$args" | cut -c1-200)
          extra=$(_proc_extra_json "$pid")
          printf '{"pid":%s,"user":"%s","cpu":%s,"mem":%s,"rss_kb":%s,"comm":"%s","args":"%s",%s}\n' \
            "$pid" \
            "$(printf '%s' "$user" | json_escape)" \
            "$pcpu" "$pmem" "$rss" \
            "$(printf '%s' "$comm" | json_escape)" \
            "$(printf '%s' "$args_short" | json_escape)" \
            "$extra" >> "$join_tmp"
        done
    awk 'NR>1{printf ","} {printf "%s", $0}' "$join_tmp"
    printf ']'
    rm -f "$join_tmp"
  }

  emit_proc_array 3 "top_proc_cpu"
  printf ','
  emit_proc_array 5 "top_proc_mem"
  rm -f "$src"
}

inventory_systemd_all() {
  # All loaded units (services + scopes + sockets + timers + targets +
  # mounts) with their state — capped to PR_SERVICES_MAX. Each field is
  # piped through json_escape so backslash sequences in unit names like
  # `dev-disk-by\x2ddiskseq.device` (systemd's own escape for non-name
  # characters) become valid JSON `\\x2d` instead of an invalid `\x` JSON
  # escape that breaks the whole payload.
  if ! have systemctl; then printf '"systemd_units":[]'; return 0; fi
  tmp="$(mktemp)"
  systemctl list-units --all --no-pager --no-legend --plain 2>/dev/null \
    | head -"$PR_SERVICES_MAX" \
    | while IFS= read -r line; do
        unit=$(printf '%s' "$line"   | awk '{print $1}')
        load=$(printf '%s' "$line"   | awk '{print $2}')
        active=$(printf '%s' "$line" | awk '{print $3}')
        sub_=$(printf '%s' "$line"   | awk '{print $4}')
        desc=$(printf '%s' "$line"   | awk '{for(i=5;i<=NF;i++) printf "%s%s", (i==5?"":" "), $i}')
        [ -z "$unit" ] && continue
        printf '{"unit":"%s","load":"%s","active":"%s","sub":"%s","desc":"%s"}\n' \
          "$(printf '%s' "$unit"   | json_escape)" \
          "$(printf '%s' "$load"   | json_escape)" \
          "$(printf '%s' "$active" | json_escape)" \
          "$(printf '%s' "$sub_"   | json_escape)" \
          "$(printf '%s' "$desc"   | json_escape)" >> "$tmp"
      done
  printf '"systemd_units":['
  awk 'NR>1{printf ","} {printf "%s", $0}' "$tmp"
  printf ']'
  rm -f "$tmp"
}

inventory_established_connections() {
  if ! have ss; then printf '"established":[]'; return 0; fi
  tmp="$(mktemp)"
  # `ss -tnH state established` columns are
  #   recv-q  send-q  local-addr:port  peer-addr:port  [users:((...))]
  # — the state column is consumed by the filter and not echoed, so we
  # need $3 (local) and $4 (peer), not $4 / $5.
  ss -tnH state established 2>/dev/null | head -200 \
    | while IFS= read -r line; do
        local_addr=$(printf '%s' "$line" | awk '{print $3}')
        remote_addr=$(printf '%s' "$line" | awk '{print $4}')
        users=$(printf '%s' "$line" | awk '{for(i=5;i<=NF;i++) printf "%s ", $i}')
        [ -z "$local_addr" ] || [ -z "$remote_addr" ] && continue
        local_ip="${local_addr%:*}"; local_port="${local_addr##*:}"
        remote_ip="${remote_addr%:*}"; remote_port="${remote_addr##*:}"
        # strip [...]
        case "$local_ip" in \[*]) local_ip="${local_ip#\[}"; local_ip="${local_ip%]}";; esac
        case "$remote_ip" in \[*]) remote_ip="${remote_ip#\[}"; remote_ip="${remote_ip%]}";; esac
        proc=$(printf '%s' "$users" | sed -n 's/.*"\([^"]*\)".*/\1/p')
        printf '{"local_ip":"%s","local_port":%s,"remote_ip":"%s","remote_port":%s,"proc":"%s"}\n' \
          "$(printf '%s' "$local_ip" | json_escape)" "${local_port:-0}" \
          "$(printf '%s' "$remote_ip" | json_escape)" "${remote_port:-0}" \
          "$(printf '%s' "$proc" | json_escape)" >> "$tmp"
      done
  printf '"established":['
  awk 'NR>1{printf ","} {printf "%s", $0}' "$tmp"
  printf ']'
  rm -f "$tmp"
}

inventory_system_info() {
  # DMI from /sys/class/dmi/id (world-readable on most distros). Fall back
  # to dmidecode if present and runnable. Includes board / BIOS / chassis
  # vendor + product + serials redacted.
  d=/sys/class/dmi/id
  read_or() { f="$1"; [ -r "$f" ] && head -1 "$f" 2>/dev/null || printf ''; }
  bios_vendor=$(read_or "$d/bios_vendor")
  bios_version=$(read_or "$d/bios_version")
  bios_date=$(read_or "$d/bios_date")
  board_vendor=$(read_or "$d/board_vendor")
  board_name=$(read_or "$d/board_name")
  board_version=$(read_or "$d/board_version")
  product_name=$(read_or "$d/product_name")
  product_family=$(read_or "$d/product_family")
  sys_vendor=$(read_or "$d/sys_vendor")
  chassis_type=$(read_or "$d/chassis_type")
  cpus_logical=$(nproc 2>/dev/null || echo 0)
  cpus_physical=$(awk -F: '/^physical id/{ids[$2]=1} END{c=0; for (k in ids) c++; print c+0}' /proc/cpuinfo 2>/dev/null)
  [ -z "$cpus_physical" ] || [ "$cpus_physical" = "0" ] && cpus_physical=1
  cpu_cores=$(awk -F: '/^cpu cores/{print $2; exit}' /proc/cpuinfo 2>/dev/null | tr -d '[:space:]')
  cpu_model=$(awk -F: '/^model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null | sed 's/^ *//')
  cpu_flags=""
  if grep -q '^flags' /proc/cpuinfo 2>/dev/null; then
    cpu_flags=$(awk -F: '/^flags/{print $2; exit}' /proc/cpuinfo | tr -s ' ' | sed 's/^ //')
    # cap to 200 chars to keep payload sane
    cpu_flags=$(printf '%s' "$cpu_flags" | cut -c1-300)
  fi
  mem_total_kb=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null)
  swap_total_kb=$(awk '/^SwapTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null)
  kernel_cmdline=$([ -r /proc/cmdline ] && head -1 /proc/cmdline 2>/dev/null | cut -c1-300)
  resolvers=""
  [ -r /etc/resolv.conf ] && resolvers=$(awk '/^nameserver/{printf "%s%s", sep, $2; sep=","}' /etc/resolv.conf 2>/dev/null | cut -c1-200)
  ntp_source=""
  if have timedatectl; then
    ntp_source=$(timedatectl show -p NTPSynchronized -p Timezone -p ServerName --value 2>/dev/null | tr '\n' ',' | cut -c1-200)
  fi
  printf '"system_info":{'
  printf '"sys_vendor":"%s",'      "$(printf '%s' "$sys_vendor"     | json_escape)"
  printf '"product_name":"%s",'    "$(printf '%s' "$product_name"   | json_escape)"
  printf '"product_family":"%s",'  "$(printf '%s' "$product_family" | json_escape)"
  printf '"board_vendor":"%s",'    "$(printf '%s' "$board_vendor"   | json_escape)"
  printf '"board_name":"%s",'      "$(printf '%s' "$board_name"     | json_escape)"
  printf '"board_version":"%s",'   "$(printf '%s' "$board_version"  | json_escape)"
  printf '"bios_vendor":"%s",'     "$(printf '%s' "$bios_vendor"    | json_escape)"
  printf '"bios_version":"%s",'    "$(printf '%s' "$bios_version"   | json_escape)"
  printf '"bios_date":"%s",'       "$(printf '%s' "$bios_date"      | json_escape)"
  printf '"chassis_type":"%s",'    "$(printf '%s' "$chassis_type"   | json_escape)"
  printf '"cpu_model":"%s",'       "$(printf '%s' "$cpu_model"      | json_escape)"
  printf '"cpu_logical":%s,'       "${cpus_logical:-0}"
  printf '"cpu_physical":%s,'      "${cpus_physical:-1}"
  printf '"cpu_cores":%s,'         "${cpu_cores:-0}"
  printf '"mem_total_kb":%s,'      "${mem_total_kb:-0}"
  printf '"swap_total_kb":%s,'     "${swap_total_kb:-0}"
  printf '"kernel_cmdline":"%s",'  "$(printf '%s' "$kernel_cmdline" | json_escape)"
  printf '"resolvers":"%s",'       "$(printf '%s' "$resolvers"      | json_escape)"
  printf '"ntp_status":"%s",'      "$(printf '%s' "$ntp_source"     | json_escape)"
  printf '"cpu_flags":"%s"'        "$(printf '%s' "$cpu_flags"      | json_escape)"
  printf '}'
}

inventory_gpus() {
  if ! have nvidia-smi || ! nvidia-smi -L >/dev/null 2>&1; then
    printf '"gpus":[]'; return 0
  fi
  tmp="$(mktemp)"
  nvidia-smi --query-gpu=index,name,driver_version,vbios_version,uuid,pci.bus_id,memory.total,compute_cap \
             --format=csv,noheader 2>/dev/null \
    | while IFS=, read -r idx name drv vbios uuid pci memt ccap; do
        idx=$(printf '%s' "$idx" | tr -d '[:space:]')
        [ -z "$idx" ] && continue
        printf '{"vendor":"nvidia","idx":%s,"name":"%s","driver":"%s","vbios":"%s","uuid":"%s","pci":"%s","mem_total":"%s","compute":"%s"}\n' \
          "$idx" \
          "$(printf '%s' "${name#  }"  | json_escape)" \
          "$(printf '%s' "${drv# }"    | json_escape)" \
          "$(printf '%s' "${vbios# }"  | json_escape)" \
          "$(printf '%s' "${uuid# }"   | json_escape)" \
          "$(printf '%s' "${pci# }"    | json_escape)" \
          "$(printf '%s' "${memt# }"   | json_escape)" \
          "$(printf '%s' "${ccap# }"   | json_escape)" >> "$tmp"
      done
  printf '"gpus":['
  awk 'NR>1{printf ","} {printf "%s", $0}' "$tmp"
  printf ']'
  rm -f "$tmp"
}

inventory_pending_updates() {
  total=0; sec=0; reboot=0
  list_tmp="$(mktemp)"
  if have apt-get && [ -r /var/lib/apt/lists ]; then
    # `apt list --upgradable` lines look like
    # `pkg/repo new-version arch [upgradable from: old-version]`. Parse
    # name + new-version + repo; flag entries from a -security pocket.
    apt list --upgradable 2>/dev/null | tail -n +2 \
      | awk '
          /\// {
            n=split($1, parts, "/")
            name=parts[1]; repo=parts[2]
            ver=$2
            sec="0"; if (repo ~ /security/) sec="1"
            printf "{\"name\":\"%s\",\"version\":\"%s\",\"repo\":\"%s\",\"security\":%s}\n", name, ver, repo, sec
          }' | head -200 > "$list_tmp"
    total=$(wc -l < "$list_tmp" | awk '{print $1}')
    sec=$(grep -c '"security":1' "$list_tmp" || true)
  elif have dnf; then
    dnf -q check-update 2>/dev/null \
      | awk 'NF==3 && $0 !~ /^Last metadata|^[[:space:]]/ {
          printf "{\"name\":\"%s\",\"version\":\"%s\",\"repo\":\"%s\",\"security\":0}\n", $1, $2, $3
        }' | head -200 > "$list_tmp"
    sec_names=$(dnf -q check-update --security 2>/dev/null | awk 'NF==3 {print $1}' | tr '\n' '|' | sed 's/|$//')
    if [ -n "$sec_names" ]; then
      sed -i -E "s/(\"name\":\"($sec_names)\",[^}]*\"security\":)0/\11/g" "$list_tmp" 2>/dev/null || true
    fi
    total=$(wc -l < "$list_tmp" | awk '{print $1}')
    sec=$(grep -c '"security":1' "$list_tmp" || true)
  fi
  [ -z "$sec" ] && sec=0
  [ -e /var/run/reboot-required ] || [ -e /run/reboot-required ] && reboot=1 || reboot=0
  printf '"updates":{"total":%s,"security":%s,"reboot_required":%s,"packages":[' \
    "${total:-0}" "${sec:-0}" "${reboot:-0}"
  awk 'NR>1{printf ","} {printf "%s", $0}' "$list_tmp"
  printf ']}'
  rm -f "$list_tmp"
}

inventory_listening_ports() {
  have ss || { printf '"listening_ports":[]'; return 0; }
  # Write all entries (TCP + UDP) to a tmp file one-per-line, then comma-join.
  # This avoids the POSIX subshell-variable-scoping trap where two separate
  # `while-read` pipes can't share a "first" flag.
  tmp="$(mktemp)"
  ss -tlnpH 2>/dev/null | head -100 | while IFS= read -r line; do
    addr=$(printf '%s' "$line" | awk '{print $4}')
    proc=$(printf '%s' "$line" | awk '{print $NF}')
    [ -z "$addr" ] && continue
    port="${addr##*:}"
    printf '{"proto":"tcp","addr":"%s","port":%s,"proc":"%s"}\n' \
      "$(printf '%s' "${addr%:*}" | json_escape)" "$port" \
      "$(printf '%s' "$proc" | json_escape)" >> "$tmp"
  done
  ss -ulnpH 2>/dev/null | head -50 | while IFS= read -r line; do
    addr=$(printf '%s' "$line" | awk '{print $4}')
    proc=$(printf '%s' "$line" | awk '{print $NF}')
    [ -z "$addr" ] && continue
    port="${addr##*:}"
    printf '{"proto":"udp","addr":"%s","port":%s,"proc":"%s"}\n' \
      "$(printf '%s' "${addr%:*}" | json_escape)" "$port" \
      "$(printf '%s' "$proc" | json_escape)" >> "$tmp"
  done
  printf '"listening_ports":['
  awk 'NR>1{printf ","} {printf "%s", $0}' "$tmp"
  printf ']'
  rm -f "$tmp"
}

inventory_docker() {
  if ! have docker || ! docker info >/dev/null 2>&1; then
    printf '"docker":null'
    return 0
  fi
  ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null)
  printf '"docker":{"version":"%s","containers":[' \
    "$(printf '%s' "${ver:-unknown}" | json_escape)"
  tmp="$(mktemp)"
  docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.State}}|{{.RunningFor}}|{{.Ports}}|{{.ID}}' 2>/dev/null \
    | head -50 | while IFS='|' read -r name image status state running ports cid; do
        [ -z "$name" ] && continue
        # Per-container inspect fields, fetched one at a time so a single
        # template-syntax mismatch (older docker versions don't support
        # `{{len .Mounts}}`) cannot fail the whole row. Each value is
        # captured independently with `|| true` so an inspect error
        # under `set -e` is harmless.
        di() { docker inspect --format "$1" "$cid" 2>/dev/null || true; }
        health=$(di '{{.State.Health.Status}}'); [ -z "$health" ] || [ "$health" = "<no value>" ] && health="n/a"
        restarts=$(di '{{.RestartCount}}'); [ -z "$restarts" ] && restarts=0
        netmode=$(di '{{.HostConfig.NetworkMode}}')
        created=$(di '{{.Created}}'); created=$(printf '%s' "$created" | cut -c1-25)
        started=$(di '{{.State.StartedAt}}'); started=$(printf '%s' "$started" | cut -c1-25)
        exit_code=$(di '{{.State.ExitCode}}'); [ -z "$exit_code" ] && exit_code=0
        # `len .Mounts` template arg landed in docker 20.x; older releases
        # would error out, so try-and-degrade.
        mounts=$(di '{{len .Mounts}}'); case "$mounts" in ''|*[!0-9]*) mounts=0 ;; esac
        hostname=$(di '{{.Config.Hostname}}')
        printf '{"name":"%s","image":"%s","status":"%s","state":"%s","running":"%s","ports":"%s","id":"%s","health":"%s","restarts":%s,"netmode":"%s","created":"%s","started":"%s","exit_code":%s,"mounts":%s,"hostname":"%s"}\n' \
          "$(printf '%s' "$name" | json_escape)" \
          "$(printf '%s' "$image" | json_escape)" \
          "$(printf '%s' "$status" | json_escape)" \
          "$(printf '%s' "$state" | json_escape)" \
          "$(printf '%s' "$running" | json_escape)" \
          "$(printf '%s' "$ports" | json_escape)" \
          "$(printf '%s' "$cid" | cut -c1-12 | json_escape)" \
          "$(printf '%s' "$health" | json_escape)" \
          "$restarts" \
          "$(printf '%s' "$netmode" | json_escape)" \
          "$(printf '%s' "$created" | cut -c1-25 | json_escape)" \
          "$(printf '%s' "$started" | cut -c1-25 | json_escape)" \
          "$exit_code" \
          "$mounts" \
          "$(printf '%s' "$hostname" | json_escape)" >> "$tmp"
      done
  awk 'NR>1{printf ","} {printf "%s", $0}' "$tmp"
  printf ']}'
  rm -f "$tmp"
}

inventory_podman() {
  if ! have podman || ! podman info >/dev/null 2>&1; then
    printf '"podman":null'
    return 0
  fi
  ver=$(podman version --format '{{.Server.Version}}' 2>/dev/null || podman version --format '{{.Version}}' 2>/dev/null)
  printf '"podman":{"version":"%s","containers":[' \
    "$(printf '%s' "${ver:-unknown}" | json_escape)"
  first=1
  podman ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.State}}|{{.ID}}' 2>/dev/null \
    | head -50 | while IFS='|' read -r name image status state cid; do
        [ -z "$name" ] && continue
        [ "$first" = "1" ] && first=0 || printf ','
        printf '{"name":"%s","image":"%s","status":"%s","state":"%s","id":"%s"}' \
          "$(printf '%s' "$name" | json_escape)" \
          "$(printf '%s' "$image" | json_escape)" \
          "$(printf '%s' "$status" | json_escape)" \
          "$(printf '%s' "$state" | json_escape)" \
          "$(printf '%s' "$cid" | cut -c1-12 | json_escape)"
      done
  printf ']}'
}

inventory_libvirt() {
  if ! have virsh || ! virsh list --all >/dev/null 2>&1; then
    printf '"libvirt":null'
    return 0
  fi
  ver=$(virsh --version 2>/dev/null)
  printf '"libvirt":{"version":"%s","vms":[' \
    "$(printf '%s' "${ver:-unknown}" | json_escape)"
  first=1
  virsh list --all 2>/dev/null | awk 'NR>2 && NF>=3 { print }' | while IFS= read -r line; do
    name=$(printf '%s' "$line" | awk '{print $2}')
    state=$(printf '%s' "$line" | awk '{ for(i=3;i<=NF;i++) printf "%s ", $i; print "" }')
    [ -z "$name" ] || [ "$name" = "-" ] && continue
    state=$(printf '%s' "$state" | sed 's/[ \t]*$//')
    cpus=""
    mem=""
    if [ "$state" = "running" ]; then
      info=$(virsh dominfo "$name" 2>/dev/null) || info=""
      cpus=$(printf '%s' "$info" | awk -F: '/CPU\(s\)/{gsub(/[ \t]/,"",$2); print $2; exit}')
      mem=$(printf '%s' "$info" | awk -F: '/Used memory/{gsub(/[ \t]/,"",$2); sub(/KiB$/,"",$2); print $2*1024; exit}')
    fi
    [ "$first" = "1" ] && first=0 || printf ','
    printf '{"name":"%s","state":"%s","cpus":%s,"mem_bytes":%s}' \
      "$(printf '%s' "$name" | json_escape)" \
      "$(printf '%s' "$state" | json_escape)" \
      "${cpus:-0}" "${mem:-0}"
  done
  printf ']}'
}

inventory_failed_services() {
  if ! have systemctl; then
    printf '"failed_services":[]'
    return 0
  fi
  printf '"failed_services":['
  first=1
  systemctl list-units --type=service --state=failed --no-pager --no-legend --plain 2>/dev/null \
    | head -50 | awk '{
        unit=$1; load=$2; active=$3; sub_=$4;
        printf "%s\037%s\037%s\n", unit, active, sub_
      }' | while IFS= read -r line; do
    unit=$(printf '%s' "$line" | awk -F '\037' '{print $1}')
    active=$(printf '%s' "$line" | awk -F '\037' '{print $2}')
    sub_=$(printf '%s' "$line" | awk -F '\037' '{print $3}')
    [ -z "$unit" ] && continue
    [ "$first" = "1" ] && first=0 || printf ','
    printf '{"unit":"%s","active":"%s","sub":"%s"}' \
      "$(printf '%s' "$unit" | json_escape)" \
      "$(printf '%s' "$active" | json_escape)" \
      "$(printf '%s' "$sub_" | json_escape)"
  done
  printf ']'
}

inventory_sensors() {
  if ! have sensors; then printf '"sensors":[]'; return 0; fi
  printf '"sensors":['
  first=1
  collect_temps | while IFS= read -r line; do
    base="${line%%\{*}"
    rest="${line#*\{}"
    rest="${rest%%\}*}"
    label=$(printf '%s' "$rest" | sed 's/^name="//; s/"$//')
    val="${line##*=}"
    [ "$first" = "1" ] && first=0 || printf ','
    printf '{"kind":"%s","name":"%s","value":%s}' \
      "$(printf '%s' "$base" | sed 's/^sensor_//' | json_escape)" \
      "$(printf '%s' "$label" | json_escape)" "$val"
  done
  printf ']'
}

inventory_kernel() {
  os_id="unknown"; os_version="unknown"; os_pretty=""
  if [ -r /etc/os-release ]; then
    os_id="$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-unknown}")"
    os_version="$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_ID:-unknown}")"
    os_pretty="$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-}")"
  fi
  kernel="$(uname -r 2>/dev/null || printf 'unknown')"
  arch="$(uname -m 2>/dev/null || printf 'unknown')"
  cpus="$(nproc 2>/dev/null || awk '/^processor/{n++} END{print n+0}' /proc/cpuinfo)"
  cpu_model="$(awk -F: '/^model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null | sed 's/^ *//')"
  virt=""
  if have systemd-detect-virt; then virt="$(systemd-detect-virt 2>/dev/null || printf '')"; fi
  boot_id=""
  [ -r /proc/sys/kernel/random/boot_id ] && boot_id="$(cat /proc/sys/kernel/random/boot_id)"
  printf '"os_id":"%s","os_version":"%s","os_pretty":"%s","kernel":"%s","arch":"%s","cpus":%d,"virt":"%s","boot_id":"%s"' \
    "$(printf '%s' "$os_id"     | json_escape)" \
    "$(printf '%s' "$os_version" | json_escape)" \
    "$(printf '%s' "$os_pretty"  | json_escape)" \
    "$(printf '%s' "$kernel"     | json_escape)" \
    "$(printf '%s' "$arch"       | json_escape)" \
    "${cpus:-0}" \
    "$(printf '%s' "$virt"       | json_escape)" \
    "$(printf '%s' "$boot_id"    | json_escape)"
  if [ -n "$cpu_model" ]; then
    printf ',"cpu_model":"%s"' "$(printf '%s' "$cpu_model" | json_escape)"
  fi
}

# ---------------------------------------------------------------------------
# Services + logins (back-compat events).
# ---------------------------------------------------------------------------

collect_services_event() {
  have systemctl || return 0
  systemctl list-units --type=service --state=loaded --no-pager --no-legend --plain 2>/dev/null \
    | awk '{
        unit=$1; load=$2; active=$3; sub_=$4;
        if (NF<4) next;
        printf "%s\037%s\037%s\037%s\n", unit, load, active, sub_
      }' | head -"$PR_SERVICES_MAX"
}

collect_logins_event() {
  have who || return 0
  who 2>/dev/null | awk '{
    user=$1; line=$2; ts=$3" "$4; from="";
    if (NF>=5) for (i=5;i<=NF;i++) from=from $i" ";
    sub(/[ \t]+$/, "", from);
    printf "%s\037%s\037%s\037%s\n", user, line, ts, from
  }' | head -50
}

# ---------------------------------------------------------------------------
# Build payload.
# ---------------------------------------------------------------------------

build_payload() {
  ts="$(now_iso)"
  agent_name_esc="$(printf '%s' "$PR_AGENT_NAME" | json_escape)"
  agent_ver_esc="$(printf '%s' "$PR_AGENT_VERSION" | json_escape)"

  metrics=""
  for raw in \
    "$(collect_cpu)" \
    "$(collect_load)" \
    "$(collect_mem)" \
    "$(collect_disk)" \
    "$(collect_diskio)" \
    "$(collect_net)" \
    "$(collect_sockets)" \
    "$(collect_files)" \
    "$(collect_uptime)" \
    "$(collect_users)" \
    "$(collect_proc_counts)" \
    "$(collect_temps)" \
    "$(collect_systemd_counts)" \
    "$(collect_docker_metrics)" \
    "$(collect_podman_metrics)" \
    "$(collect_libvirt_metrics)" \
    "$(collect_gpu_metrics)" \
    "$(collect_pending_updates)" \
    "$(collect_proc_metrics)"
  do
    [ -n "$raw" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      key="${line%=*}"; val="${line##*=}"
      base="${key%%\{*}"
      labels=""
      if [ "$base" != "$key" ]; then
        rest="${key#*\{}"; rest="${rest%\}}"
        labels=",\"labels\":{"
        first=1
        oldifs="$IFS"; IFS=','
        for kv in $rest; do
          k="${kv%%=*}"; v="${kv#*=}"
          v="${v#\"}"; v="${v%\"}"
          if [ "$first" -eq 1 ]; then first=0; else labels="$labels,"; fi
          labels="$labels\"$(printf '%s' "$k" | json_escape)\":\"$(printf '%s' "$v" | json_escape)\""
        done
        IFS="$oldifs"
        labels="$labels}"
      fi
      [ -n "$metrics" ] && metrics="$metrics,"
      metrics="$metrics{\"ts\":\"$ts\",\"name\":\"$(printf '%s' "$base" | json_escape)\",\"value\":${val}${labels}}"
    done <<EOF_LINES
$raw
EOF_LINES
  done

  services=""
  raw_svc="$(collect_services_event || true)"
  if [ -n "$raw_svc" ]; then
    first=1
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      unit="$(printf '%s' "$line" | awk -F '\037' '{print $1}')"
      load="$(printf '%s' "$line" | awk -F '\037' '{print $2}')"
      active="$(printf '%s' "$line" | awk -F '\037' '{print $3}')"
      sub_="$(printf '%s' "$line" | awk -F '\037' '{print $4}')"
      if [ "$first" -eq 1 ]; then first=0; else services="$services,"; fi
      services="$services{\"unit\":\"$(printf '%s' "$unit" | json_escape)\",\"load\":\"$load\",\"active\":\"$active\",\"sub\":\"$sub_\"}"
    done <<EOF_SVC
$raw_svc
EOF_SVC
  fi

  logins=""
  raw_lgn="$(collect_logins_event || true)"
  if [ -n "$raw_lgn" ]; then
    first=1
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      user="$(printf '%s' "$line" | awk -F '\037' '{print $1}')"
      tty="$(printf '%s' "$line" | awk -F '\037' '{print $2}')"
      ts_login="$(printf '%s' "$line" | awk -F '\037' '{print $3}')"
      from="$(printf '%s' "$line" | awk -F '\037' '{print $4}')"
      if [ "$first" -eq 1 ]; then first=0; else logins="$logins,"; fi
      logins="$logins{\"user\":\"$(printf '%s' "$user" | json_escape)\",\"tty\":\"$(printf '%s' "$tty" | json_escape)\",\"ts\":\"$(printf '%s' "$ts_login" | json_escape)\",\"from\":\"$(printf '%s' "$from" | json_escape)\"}"
    done <<EOF_LGN
$raw_lgn
EOF_LGN
  fi

  # Inventory blob — a single JSON object with all snapshot data.
  cap="$(inventory_capabilities)"
  kern="$(inventory_kernel)"
  sysinfo="$(inventory_system_info)"
  procs="$(inventory_top_processes)"
  ports="$(inventory_listening_ports)"
  estab="$(inventory_established_connections)"
  dock="$(inventory_docker)"
  pman="$(inventory_podman)"
  lvirt="$(inventory_libvirt)"
  units_all="$(inventory_systemd_all)"
  failed="$(inventory_failed_services)"
  snsr="$(inventory_sensors)"
  gpus="$(inventory_gpus)"
  upd="$(inventory_pending_updates)"

  {
    printf '{'
    printf '"agent_id":"%s",' "$PR_AGENT_ID"
    printf '"name":"%s",' "$agent_name_esc"
    printf '"agent_version":"%s",' "$agent_ver_esc"
    printf '"ts":"%s",' "$ts"
    printf '"inventory":{%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s},' \
      "$kern" "$cap" "$sysinfo" "$procs" "$ports" "$estab" \
      "$dock" "$pman" "$lvirt" "$units_all" "$failed" "$snsr" \
      "$gpus" "$upd"
    printf '"metrics":[%s],' "$metrics"
    printf '"services":[%s],' "$services"
    printf '"logins":[%s]' "$logins"
    printf '}'
  } > "$PAYLOAD"
}

# ---------------------------------------------------------------------------
# Queue + send (unchanged from 0.1.0).
# ---------------------------------------------------------------------------

post_one() {
  body_file="$1"
  gz_file="$2"
  gzip -c -- "$body_file" > "$gz_file"
  # Hand the bearer token to curl via a config file fed on stdin
  # (`curl -K -`). On default Ubuntu/Debian /proc is mounted without
  # hidepid, so any local user could otherwise read the token via
  # /proc/$(pidof curl)/cmdline while the agent is mid-push. The
  # config file form keeps the secret in process memory only.
  http=$(
    printf '%s\n' "header = \"Authorization: Bearer $PR_AGENT_TOKEN\"" \
    | curl -sS -o /dev/null -w '%{http_code}' \
      --max-time "$PR_HTTP_TIMEOUT" \
      -H 'Content-Type: application/json' \
      -H 'Content-Encoding: gzip' \
      -H "X-Agent-Id: $PR_AGENT_ID" \
      -H "X-Agent-Version: $PR_AGENT_VERSION" \
      -K - \
      --data-binary "@$gz_file" \
      "$PR_INGEST_URL"
  ) || http=000
  case "$http" in
    2*) return 0 ;;
    400|401|403|413|422) log "ingest rejected http=$http (drop): $body_file"; return 0 ;;
    *) log "ingest http=$http (queue): $body_file"; return 1 ;;
  esac
}

drain_queue() {
  count=0
  for f in "$QUEUE_DIR"/*.json; do
    [ -e "$f" ] || break
    count=$((count+1))
    [ $count -gt 20 ] && break
    if post_one "$f" "$GZ"; then rm -f -- "$f"; else break; fi
  done
}

enqueue() {
  ts_epoch="$(now_epoch)"; rand="$$$ts_epoch"
  cp -- "$PAYLOAD" "$QUEUE_DIR/q-$ts_epoch-$rand.json"
  count="$(ls -1 "$QUEUE_DIR" 2>/dev/null | wc -l | awk '{print $1}')"
  if [ "$count" -gt "$PR_QUEUE_MAX" ]; then
    drop=$((count - PR_QUEUE_MAX))
    ls -1tr "$QUEUE_DIR" 2>/dev/null | head -n "$drop" | while IFS= read -r name; do
      rm -f -- "$QUEUE_DIR/$name"
    done
    log "queue trimmed by $drop"
  fi
}

# ---------------------------------------------------------------------------
# Main: collect → send → drain. Locking via mkdir to avoid concurrent runs.
# ---------------------------------------------------------------------------

LOCK_DIR="$STATE_DIR/.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log "another agent run is in flight, skipping"
  exit 0
fi
trap 'rmdir "$LOCK_DIR" >/dev/null 2>&1 || true; rm -f "$PAYLOAD" "$GZ"' EXIT INT TERM

build_payload

if post_one "$PAYLOAD" "$GZ"; then
  drain_queue || true
else
  enqueue
fi
