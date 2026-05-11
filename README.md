# linux-agent

Host metric agent for PingReports. Runs as a non-root systemd timer, samples
CPU/load/memory/disk/network/services/logins every 5 minutes, ships a
gzipped JSON batch to the configured ingest endpoint.

## Install

```
curl -fsSL https://raw.githubusercontent.com/PingReports/linux-agent/main/install.sh \
  | sudo PR_AGENT_ID=<id> PR_AGENT_TOKEN=<token> sh
```

## Files

* `install.sh` — distro-agnostic installer (apt/dnf/yum/zypper/pacman).
* `agent.sh` — oneshot collector + uploader.
* `uninstall.sh` — removes user, units, state.
