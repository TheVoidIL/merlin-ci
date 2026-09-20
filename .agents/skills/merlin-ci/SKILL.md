---
name: merlin-ci
description: >-
  Trigger-driven router automation, self-healing CI engine, and watchdog operations for Asuswrt-Merlin firmware.
  Use when developing, maintaining, debugging, extending, deploying, or testing Merlin-CI jobs, router telemetry, or watchdog scripts.
---

# Merlin-CI (`mci`) Skill & Engineering Runbook

## Overview
**Merlin-CI** is an event-driven Continuous Integration (CI) and autonomous self-healing engine engineered specifically for embedded Linux routers running **Asuswrt-Merlin** firmware (ARM & MIPS architectures, including WiFi 7 Broadcom BCM4916 like RT-BE92U).

Unlike traditional server CI, Merlin-CI operates under severe embedded hardware constraints:
- **Zero Resident Memory**: Defaults to Asuswrt's native `cru` (BusyBox `crond`). Wakes up periodically, evaluates trigger conditions in < 0.5s, executes if needed, and **exits completely**, leaving 0 MB of resident RAM.
- **`renice 19` CPU Priority**: Low scheduling priority ensures packet routing, NAT, and WiFi traffic are never impacted.
- **NAND Flash-Wear Protection**: All logs, snapshots, and runtime state are strictly stored on external USB storage (`/opt/var/merlin-ci`).
- **Automated Rollback**: Pre-execution snapshots are created before changes; if post-execution smoke tests fail, the previous state is restored automatically.

---

## Repository & Project Architecture

```
d:\CICD_Asus / /jffs/addons/merlin-ci/
├── merlin-ci.sh                 # Master CLI & interactive AMTM menu entry point
├── install.sh                   # Router installer & environment bootstrap
├── LICENSE                      # MIT License (The Void)
├── README.md                    # Public documentation and quick-start guide
├── lib/
│   ├── config.sh                # Configuration parser & validator
│   ├── daemon.sh                # Trigger evaluator & cron (cru) scheduler
│   ├── notify.sh                # Multi-channel notification dispatcher (Email/Discord/TG)
│   ├── runner.sh                # 5-stage CI execution & rollback engine
│   └── ui.sh                    # ANSI styling, semantic color helpers & AMTM banner
├── jobs/                        # 16 Autonomous Watchdogs & CI pipelines
│   ├── amtm-general-autoupdate.job.sh
│   ├── amtm-self-update.job.sh
│   ├── cpu-thermal-heal.job.sh
│   ├── dns-unresponsive-heal.job.sh
│   ├── entware-autoupdate.job.sh
│   ├── firewall-leak-audit.job.sh
│   ├── iot-anomaly-contain.job.sh
│   ├── letsencrypt-cert-watchdog.job.sh
│   ├── new-device-watchdog.job.sh
│   ├── nvram-jffs-vault.job.sh
│   ├── ram-oom-heal.job.sh
│   ├── router-daily-digest.job.sh
│   ├── ssh-auth-watchdog.job.sh
│   ├── usb-storage-fsck-watchdog.job.sh
│   ├── usb-swap-repair.job.sh
│   └── wan-gateway-watchdog.job.sh
├── templates/
│   ├── custom.job.sh            # Blueprint for creating new user jobs
│   ├── merlin-ci.conf           # System configuration template
│   └── send_alert.sh            # Executive NOC Email Dashboard template
└── tests/
    └── test_runner.sh           # Test harness for CI runner verification
```

---

## Built-in Jobs & Watchdogs Reference

| Job Name | Category | Trigger / Purpose | Automated Healing / Action | Smoke Test & Rollback |
| :--- | :--- | :--- | :--- | :--- |
| `amtm-general-autoupdate` | **Master Addon CI** | `amtm updcheck` detects 3rd-party script releases | Targeted `amtmupdate` on outdated scripts | Validates script syntax (`sh -n`), checks `dnsmasq` & `httpd`; auto-rollbacks `/jffs/scripts/` |
| `amtm-self-update` | **AMTM Core CI** | New amtm version available | Updates `/jffs/scripts/amtm` silently | Syntax verification; restores active backup on error |
| `entware-autoupdate` | **Package CI** | `opkg list-upgradable` returns packages | Upgrades packages, backs up `/opt/etc/` | Checks opkg db and binary execution; restores configs |
| `wan-gateway-watchdog` | **Self-Healing** | Gateway/internet drops while WAN interface is linked | Soft DHCP lease refresh (`udhcpc`) or `service restart_wan` | Verifies multi-target external ping & public DNS |
| `dns-unresponsive-heal` | **Self-Healing** | `dnsmasq` deadlocks or local queries fail | Flushes cache, restarts `dnsmasq` | Local query benchmark (< 25ms); restores config |
| `usb-swap-repair` | **Self-Healing** | Swap inactive in `/proc/swaps` or ghost mounts exist | Clears ghost mounts, runs `mkswap` & `swapon` | Verifies `/proc/swaps` and `SwapTotal > 0` |
| `usb-storage-fsck-watchdog`| **Self-Healing** | USB storage partition turns Read-Only (`ro`) | Remounts `rw`, runs `fsck.ext4` if needed | Validates filesystem write permissions across all drives |
| `nvram-jffs-vault` | **Disaster Recovery**| Scheduled weekly (7 days elapsed) | Exports NVRAM (`/sbin/nvram show`), compresses `/jffs/` | Verifies archive integrity with `tar -tzf` & rotates last 4 |
| `firewall-leak-audit` | **Security** | Missing core iptables chains or Skynet rules | Restarts Skynet rules or `service restart_firewall` | Confirms netfilter chains (INPUT, FORWARD) & IPSets active |
| `letsencrypt-cert-watchdog`| **Security** | SSL certificate expires within 7 days | Triggers WebUI renewal (`service restart_httpd`) | Verifies renewed certificate expiration date is > 7 days |
| `ssh-auth-watchdog` | **Security** | Repeated failed SSH login attempts in syslog | Extracts attacker IPs and adds iptables DROP rules | Verifies DROP rules present in iptables INPUT chain |
| `new-device-watchdog` | **Security** | Unrecognized MAC in active DHCP leases | Dispatches instant alert via `send_alert.sh` | Verifies MAC registered to `known_macs.txt` |
| `iot-anomaly-contain` | **Security** | IoT device connection count spikes abnormally | Isolates compromised IoT IP via iptables quarantine | Confirms quarantine rules active; alerts admin |
| `cpu-thermal-heal` | **Hardware** | RT-BE92U CPU temperature exceeds safe threshold | Kills runaway processes, throttles background jobs | Verifies temperature decrease below critical limit |
| `ram-oom-heal` | **Hardware** | Free memory drops below minimum threshold | Drops caches (`drop_caches`), restarts memory leakers | Verifies memory availability restored |
| `router-daily-digest` | **Telemetry** | Scheduled daily | Aggregates 24h metrics, thermal, RAM, Skynet blocks | Dispatches single Executive NOC Email Dashboard |

---

## 5-Stage Job Execution Model

Every job script implements standard hook functions:
1. `mci_check_trigger`: Returns `0` (run needed) or `1` (all clear, skip execution).
2. `mci_backup "$backup_dir"`: Takes snapshot of critical files before modifying them.
3. `mci_run`: Performs the core update, repair, or maintenance task.
4. `mci_verify`: Verifies health and functionality. Returns `0` (success) or `1` (failed smoke test).
5. `mci_rollback "$backup_dir"`: Restores the snapshot if `mci_verify` fails.
6. `mci_notify "$status" "$duration"`: Optional custom alert hook.

---

## Maintenance & Operational Runbooks

### 1. Deploying Updates from PC to Router
To deploy modified scripts to the router via SSH (`tamird@192.168.50.1:1025`):

```powershell
# Copy specific libraries or jobs:
scp -O -P 1025 d:\CICD_Asus\lib\ui.sh tamird@192.168.50.1:/jffs/addons/merlin-ci/lib/
scp -O -P 1025 d:\CICD_Asus\lib\runner.sh tamird@192.168.50.1:/jffs/addons/merlin-ci/lib/
scp -O -P 1025 d:\CICD_Asus\jobs\nvram-jffs-vault.job.sh tamird@192.168.50.1:/jffs/addons/merlin-ci/jobs/
scp -O -P 1025 d:\CICD_Asus\templates\send_alert.sh tamird@192.168.50.1:/jffs/scripts/send_alert.sh

# Or sync all jobs:
scp -O -P 1025 d:\CICD_Asus\jobs\*.job.sh tamird@192.168.50.1:/jffs/addons/merlin-ci/jobs/
```

On router SSH terminal, ensure execute permissions:
```sh
chmod +x /jffs/scripts/send_alert.sh
chmod +x /jffs/addons/merlin-ci/jobs/*.job.sh /jffs/addons/merlin-ci/lib/*.sh
```

### 2. Testing & Running Jobs
```sh
# Force-run a specific job regardless of trigger condition
mci run nvram-jffs-vault -f
mci run router-daily-digest -f

# Scan all triggers (evaluates watchdog conditions without running unneeded jobs)
mci check

# View logs for a specific job
mci logs nvram-jffs-vault
```

### 3. Adding a New Custom Watchdog Job
1. Copy `templates/custom.job.sh` to `jobs/<my-watchdog>.job.sh`.
2. Define `JOB_NAME`, `JOB_DESCRIPTION`, `JOB_ENABLED=1`, and `JOB_TYPE="watchdog"` (or `"daily"`).
3. Implement `mci_check_trigger`, `mci_run`, and `mci_verify`.
4. Deploy to `/jffs/addons/merlin-ci/jobs/`. It is immediately recognized by `mci list` and `mci check`.

---

## Embedded Linux & Asuswrt Gotchas

1. **BusyBox `ash` vs Bash**:
   - Never rely on `command -v <binary>` for core Asuswrt binaries. On some Asuswrt BusyBox builds, `command` is disabled or returns an error. Always check direct paths (`/sbin/nvram`, `/bin/nvram`, `/usr/sbin/...`) or use `which <binary>`.
   - Never use Bashisms like `[[ ]]` or `${var//search/replace}`. Use standard POSIX `[ ]` and `sed`/`awk`.
2. **ANSI Color Stripping for Emails**:
   - BusyBox `sed` does not parse hex escape sequences like `\x1b`. Always construct real ASCII 27 escape bytes with `ESC="$(printf '\033')"` before stripping: `sed "s/${ESC}\[[0-9;]*[a-zA-Z]//g"`.
3. **Duplicate Email Prevention**:
   - For jobs that send their own specialized notification (like `router-daily-digest`), define `JOB_NOTIFY_SUCCESS=0` inside the job script. The runner will suppress routine success emails while preserving failure and rollback alerts.
4. **Strict Unix LF Line Endings**:
   - Windows PowerShell edits can accidentally introduce CRLF (`\r\n`), causing `: not found` errors in BusyBox. Always normalize with `d:\CICD_Asus\scratch\normalize_eol.ps1` before committing or deploying.
