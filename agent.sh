#!/bin/sh
# PingReports linux agent — metric collector + uploader.
#
# Runs as the unprivileged pingreports-agent user under systemd. Wakes on
# the timer, samples host metrics + inventory, gzips a JSON payload,
# POSTs to the configured ingest endpoint with a Bearer token, then
# exits. Designed to be runnable on any POSIX shell that ships with
# Debian/Ubuntu/RHEL/Alma/Rocky/SUSE/Arch.

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
PR_AGENT_VERSION="${PR_AGENT_VERSION:-0.1.0}"
PR_NET_IFACES="${PR_NET_IFACES:-}"
PR_DISK_PATHS="${PR_DISK_PATHS:-/}"
PR_HTTP_TIMEOUT="${PR_HTTP_TIMEOUT:-30}"
PR_QUEUE_MAX="${PR_QUEUE_MAX:-50}"

mkdir -p "$QUEUE_DIR"

PAYLOAD="$(mktemp)"
GZ="$(mktemp)"
trap 'rm -f "$PAYLOAD" "$GZ"' EXIT INT TERM

now_iso() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
now_epoch() { date +%s; }

# json_escape — escape a single value for embedding in a JSON string literal.
# Avoids pulling in jq as a hard dependency on minimal images.
json_escape() {
  awk 'BEGIN{
    for (i=0;i<32;i++) tab[sprintf("%c",i)]=sprintf("\\u%04x",i);
    tab["\""]="\\\""; tab["\\"]="\\\\"; tab["\b"]="\\b"; tab["\f"]="\\f";
    tab["\n"]="\\n"; tab["\r"]="\\r"; tab["\t"]="\\t";
  }
  { for (i=1;i<=length($0);i++){c=substr($0,i,1); printf "%s", (c in tab)?tab[c]:c} printf "" }'
}

emit_kv_string() { printf '"%s":"%s"' "$1" "$(printf '%s' "$2" | json_escape)"; }
emit_kv_number() { printf '"%s":%s' "$1" "$2"; }

# ---------------------------------------------------------------------------
# Metric collectors. Each prints "name=value" lines on stdout. Failure of
# any single collector is non-fatal — we capture what we can and move on.
# ---------------------------------------------------------------------------

collect_cpu() {
  if [ -r /proc/stat ]; then
    awk '/^cpu /{
      idle=$5+$6; total=$2+$3+$4+$5+$6+$7+$8+$9;
      printf "cpu_user=%d\ncpu_system=%d\ncpu_idle=%d\ncpu_iowait=%d\ncpu_total=%d\n",
        $2, $4, $5, $6, total }' /proc/stat
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
      END {
        printf "mem_total_kb=%d\nmem_available_kb=%d\nmem_free_kb=%d\nmem_buffers_kb=%d\nmem_cached_kb=%d\nswap_total_kb=%d\nswap_free_kb=%d\n",
          tot, avail, free, buf, cache, stot, sfree
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
  done
  IFS="$oldifs"
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
      printf "net_rx_bytes{iface=\"%s\"}=%d\nnet_rx_packets{iface=\"%s\"}=%d\nnet_rx_errs{iface=\"%s\"}=%d\nnet_tx_bytes{iface=\"%s\"}=%d\nnet_tx_packets{iface=\"%s\"}=%d\nnet_tx_errs{iface=\"%s\"}=%d\n",
        iface, $2, iface, $3, iface, $4, iface, $10, iface, $11, iface, $12
    }' /proc/net/dev
}

collect_uptime() {
  [ -r /proc/uptime ] || return 0
  awk '{ printf "uptime_seconds=%d\n", $1 }' /proc/uptime
}

# ---------------------------------------------------------------------------
# Inventory. Distro/kernel + active services. Reported once per push so the
# UI can surface "service down" events from the same dataset.
# ---------------------------------------------------------------------------

collect_inventory() {
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

  printf '"os_id":"%s","os_version":"%s","os_pretty":"%s","kernel":"%s","arch":"%s","cpus":%d' \
    "$(printf '%s' "$os_id"     | json_escape)" \
    "$(printf '%s' "$os_version" | json_escape)" \
    "$(printf '%s' "$os_pretty"  | json_escape)" \
    "$(printf '%s' "$kernel"     | json_escape)" \
    "$(printf '%s' "$arch"       | json_escape)" \
    "${cpus:-0}"
  if [ -n "$cpu_model" ]; then
    printf ',"cpu_model":"%s"' "$(printf '%s' "$cpu_model" | json_escape)"
  fi
}

collect_services() {
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl list-units --type=service --state=loaded --no-pager --no-legend --plain 2>/dev/null \
    | awk '{
        unit=$1; load=$2; active=$3; sub_=$4;
        if (NF<4) next;
        printf "%s\037%s\037%s\037%s\n", unit, load, active, sub_
      }' | head -200
}

collect_logins() {
  command -v lastlog >/dev/null 2>&1 || return 0
  who 2>/dev/null | awk '{
    user=$1; line=$2; ts=$3" "$4; from="";
    if (NF>=5) for (i=5;i<=NF;i++) from=from $i" ";
    sub(/[ \t]+$/, "", from);
    printf "%s\037%s\037%s\037%s\n", user, line, ts, from
  }' | head -50
}

# ---------------------------------------------------------------------------
# Build payload JSON. We avoid jq (no hard dep): templated strings instead.
# ---------------------------------------------------------------------------

build_payload() {
  ts="$(now_iso)"
  agent_name_esc="$(printf '%s' "$PR_AGENT_NAME" | json_escape)"
  agent_ver_esc="$(printf '%s' "$PR_AGENT_VERSION" | json_escape)"

  inv_body="$(collect_inventory)"

  metrics=""
  for raw in \
    "$(collect_cpu)" \
    "$(collect_load)" \
    "$(collect_mem)" \
    "$(collect_disk)" \
    "$(collect_net)" \
    "$(collect_uptime)"
  do
    [ -n "$raw" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      # Lines look like either `name=value` or `name{k="v"[,k2="v2"]}=value`.
      # Use non-greedy parameter expansion to split on the LAST `=` so the
      # `=` inside label values doesn't break the parse.
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
  raw_svc="$(collect_services || true)"
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
  raw_lgn="$(collect_logins || true)"
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

  {
    printf '{'
    printf '"agent_id":"%s",' "$PR_AGENT_ID"
    printf '"name":"%s",' "$agent_name_esc"
    printf '"agent_version":"%s",' "$agent_ver_esc"
    printf '"ts":"%s",' "$ts"
    printf '"inventory":{%s},' "$inv_body"
    printf '"metrics":[%s],' "$metrics"
    printf '"services":[%s],' "$services"
    printf '"logins":[%s]' "$logins"
    printf '}'
  } > "$PAYLOAD"
}

# ---------------------------------------------------------------------------
# Queue + send. If the network blip-fails, we drop the payload into the
# queue dir and try to drain it on the next tick. Bounded by PR_QUEUE_MAX.
# ---------------------------------------------------------------------------

post_one() {
  body_file="$1"
  gz_file="$2"
  gzip -c -- "$body_file" > "$gz_file"
  http=$(
    curl -sS -o /dev/null -w '%{http_code}' \
      --max-time "$PR_HTTP_TIMEOUT" \
      -H 'Content-Type: application/json' \
      -H 'Content-Encoding: gzip' \
      -H "Authorization: Bearer $PR_AGENT_TOKEN" \
      -H "X-Agent-Id: $PR_AGENT_ID" \
      -H "X-Agent-Version: $PR_AGENT_VERSION" \
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
  # Trim oldest if we're past PR_QUEUE_MAX.
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
