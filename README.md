# Merlin-CI (`mci`) 🚀
### Trigger-Driven Addon Automation & Self-Healing CI Engine for Asuswrt-Merlin

**Merlin-CI** is an ultra-lightweight, event-driven Continuous Integration (CI) and self-healing automation engine engineered specifically for embedded Linux routers running [Asuswrt-Merlin](https://www.asuswrt-merlin.net/) firmware (ARM & MIPS architectures).

Unlike traditional build systems, Merlin-CI serves as a **proactive router watchdog and maintenance CI**:
1. **General & Individual Addon Auto-Updates**: Supports master automated updates via the universal `amtmupdate` standard implemented across the AMTM ecosystem, as well as dedicated auto-update pipelines for **Skynet**, **Diversion**, and **Entware packages**.
2. **Automated Self-Healing & System Maintenance**: Actively monitors router infrastructure (such as **USB swap file degradation or disconnection**) and executes automated repair, re-formatting, and reactivation pipelines.
3. **Automated Rollback on Failure**: If any update breaks a service or fails post-execution verification, Merlin-CI automatically restores the pre-flight backup to maintain router stability and WiFi performance.

---

## ⚡ Embedded Linux Optimizations (Low CPU & Low RAM)

Embedded routers have constrained hardware (single/dual-core CPUs and 256MB–512MB RAM). Merlin-CI is built from the ground up for minimal resource usage:

- **Zero Resident RAM Mode (Cron-First Architecture)**:
  Instead of running an idle shell daemon in the background (which wastes 1.5MB–3MB RAM constantly), Merlin-CI defaults to Asuswrt-Merlin's native `cru` (BusyBox `crond`). It wakes up periodically, evaluates triggers in under 0.5s, and **exits completely**, releasing 100% of its memory.
- **`renice 19` Process Priority**:
  All pipeline stages and scripts run with the lowest CPU scheduling priority (`nice -n 19` / `renice`), guaranteeing that packet routing, NAT, and WiFi traffic always take precedence.
- **Resource Guardrails (`runner_check_safety`)**:
  Before any task begins, Merlin-CI checks the 1-minute load average against `MCI_MAX_LOADAVG` (default `2.50`) and free memory against `MCI_MIN_FREE_RAM_MB` (default `32MB`). If the router is under heavy traffic load, execution is safely deferred.
- **Flash-Wear Protection**:
  To protect the router's NAND flash (`/jffs`), all logs, workspaces, and backups are strictly stored on external USB storage (`/opt/var/merlin-ci`).

---

## 🛠️ Built-in Automation & Self-Healing Jobs

| Job Name | Category | Trigger / Purpose | Automated Action | CI Smoke Test & Verification | Rollback Action |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`amtm-general-autoupdate`** | **Master Addon CI** | Native `amtm updcheck` detects new 3rd-party script releases | Runs targeted `amtmupdate` ONLY on outdated scripts (Skynet, Diversion, FlexQoS, YazFi, etc.) | Validates script syntax (`sh -n`), checks `dnsmasq` & `httpd` | Restores `/jffs/scripts/` snapshot & reloads services |
| **`entware-autoupdate`** | **Package CI** | `opkg list-upgradable` returns packages | Backups `/opt/etc/` configs, upgrades packages | Checks `opkg` database integrity & verifies binary execution | Restores `/opt/etc/` configuration files |
| **`wan-gateway-watchdog`** | **Self-Healing** | Gateway / internet drops while WAN interface is linked | Soft DHCP lease refresh (`udhcpc`) or `service restart_wan` | Verifies multi-target external ping & public DNS resolution | Restores resolv.conf & re-triggers clean WAN restart |
| **`dns-unresponsive-heal`** | **Self-Healing** | `dnsmasq` deadlocks or local queries fail/timeout | Flushes DNS cache, validates config syntax, restarts `dnsmasq` | Verifies local query responsiveness (< 25ms) on LAN / system | Restores backed-up config & restarts dnsmasq |
| **`usb-swap-repair`** | **Self-Healing** | Swap file is inactive in `/proc/swaps` or ghost mounts exist | Tests USB state, resolves ghost mounts, runs `mkswap` & `swapon` | Verifies `/proc/swaps` active & `SwapTotal` > 0 kB | Disables broken swap & logs emergency alert |
| **`usb-storage-fsck-watchdog`**| **Self-Healing** | USB storage partition turns Read-Only (`ro`) | Remounts `rw` or stops services, runs `fsck.ext4`, remounts `rw` | Confirms USB write permissions across all attached drives | Records dmesg diagnostics for manual review |
| **`nvram-jffs-vault`** | **Disaster Recovery**| Scheduled weekly (7 days elapsed since last snapshot) | Dumps sorted NVRAM, static DHCP, and `/jffs/` compressed tarball | Verifies archive integrity with `tar -tzf` & rotates last 4 | Prunes incomplete snapshot |
| **`firewall-leak-audit`** | **Security** | Missing core iptables chains or dropped Skynet rules | Restarts Skynet rules or executes `service restart_firewall` | Confirms netfilter chains (INPUT, FORWARD) & IPSets active | Restores pre-flight `iptables-restore` snapshot |
| **`letsencrypt-cert-watchdog`** | **Security** | SSL certificate expires within 7 days (`openssl -checkend`) | Triggers Let's Encrypt / WebUI renewal (`service restart_httpd`) | Verifies renewed certificate expiration date is > 7 days | Restores previous certificate & restarts web server |
| **`ssh-auth-watchdog`** | **Security** | Repeated failed SSH login attempts detected in syslog | Extracts attacker IPs and adds temporary iptables DROP rules | Confirms iptables INPUT chain is operational with drop rules | N/A (defensive security rule) |
| **Custom Jobs** | **Custom** | Any user-defined shell condition | Custom script execution | User-defined smoke test | User-defined rollback handler |

---

## 🔄 How General Updates Work (`amtm-general-autoupdate.job.sh`)

In the Asuswrt-Merlin and AMTM ecosystem:
1. **The `amtmupdate` Standard**: Third-party AMTM scripts (such as Skynet, Diversion, YazFi, scribe, connmon, ntpMerlin, scMerlin, spdMerlin, etc.) implement a universal non-interactive command parameter: `sh <script> amtmupdate`.
2. **Silent Execution**: When called with `amtmupdate`, scripts check their remote repositories and silently apply updates if a newer version is available, without prompting the user or clearing terminal screens.
3. **CI Pre-Flight & Rollback**: Merlin-CI takes this a step further by snapshotting `/jffs/scripts/` before calling `amtmupdate`. If any updated script introduces a syntax error or causes critical services like `dnsmasq` or `httpd` to crash, Merlin-CI **automatically rolls back** to the working snapshot!

---

## 🚀 Installation

Connect to your router via SSH:

```sh
cd /tmp
git clone https://github.com/TheVoidIL/merlin-ci.git merlin-ci-setup
cd merlin-ci-setup
sh install.sh
```

---

## 💻 Usage

### 1. Interactive AMTM Mode
Type `mci` in any SSH terminal:

```sh
mci
```

```text
  __  __           _ _             ____ ___ 
 |  \/  | ___ _ __| (_)_ __       / ___|_ _|
 | |\/| |/ _ \ '__| | | '_ \ ____| |    | | 
 | |  | |  __/ |  | | | | | |____| |___ | | 
 |_|  |_|\___|_|  |_|_|_| |_|     \____|___|
  Trigger-Driven Router Automation & CI Engine for Asuswrt-Merlin (v1.1.0)
  Developed by The Void
--------------------------------------------------------------------------------
 Device:   RT-AX86U           Firmware:  3004.388.7_0
 Load:     0.18, 0.12, 0.08   Memory:    364 MB free
 Cron:     Active: 0 4 * * *  Last Run:  [SUCCESS] (2026-09-18 04:00:12)
--------------------------------------------------------------------------------
  Configured CI Automation Jobs:

   [1] amtm-general-autoupdate [ENABLED]  Result: [SUCCESS]
       Master update for amtm, Skynet, Diversion & all router scripts
   [2] entware-autoupdate     [ENABLED]  Result: [SUCCESS]
       Auto-updates Entware packages with service smoke tests
   [3] wan-gateway-watchdog   [ENABLED]  Result: [SUCCESS]
       Self-healing watchdog: detects WAN/gateway drops and recovers
   [4] dns-unresponsive-heal  [ENABLED]  Result: [SUCCESS]
       Self-healing watchdog: detects dnsmasq lockup and restarts DNS
   [5] usb-swap-repair        [ENABLED]  Result: [SUCCESS]
       Self-healing watchdog: detects, repairs, and reactivates USB swap

 Actions:
  [1]  Check All Triggers Now (Scan & Auto-Run Updates/Repairs)
  [2]  Force-Run a Specific Job (Manual Override)
  [3]  Enable / Disable a Job
  [4]  Create New Custom CI Job (Wizard)
  [5]  View Job Execution & Rollback Logs
  [6]  Configure Automated Scheduler / Cron (cru)
  [7]  Router Resource Diagnostics & Guardrails
  [8]  Notification Settings (Email / Discord / Telegram)

  [u]  Uninstall Merlin-CI
  [e]  Exit to Shell / AMTM
```

### Notification Channels
Merlin-CI supports three notification channels:
1. **Email (SMTP)**: Direct delivery to your personal email inbox via built-in `curl` or `sendmail` (supports Gmail App Passwords, Outlook, custom SMTP servers).
   - **Auto-Scraper (`[s]` or `mci scrape-email`)**: Automatically discovers and imports existing SMTP credentials already configured in AMTM, WICENS, Diversion, NVRAM, or `/jffs/scripts/`!
2. **Discord Webhooks**: Rich embed messages showing router model, status, and duration.
3. **Telegram Bot**: Instant message notifications.

Email and Webhook settings can be managed via `mci` (option `[8]`) or edited in `/jffs/addons/merlin-ci/merlin-ci.conf`:

```ini
# --- Email (SMTP) Notifications ---
MCI_EMAIL_ENABLED=1
MCI_SMTP_SERVER="smtp.gmail.com"
MCI_SMTP_PORT=465
MCI_SMTP_USER="myrouteralerts@gmail.com"
MCI_SMTP_PASS="xxxx-xxxx-xxxx-xxxx"   # App Password
MCI_SMTP_FROM="router@home.arpa"
MCI_SMTP_TO="myemail@example.com"
MCI_SMTP_TLS=1
```

### 2. Command-Line Interface (CLI)

```sh
# Auto-detect and import SMTP email credentials from AMTM / Asuswrt-Merlin
mci scrape-email

# Run master general update across all AMTM scripts with pre-flight backup & smoke tests
mci run amtm-general-autoupdate -f

# Check all triggers (auto-repairs swap and updates addons if needed)
mci check

# Force-run the USB swap repair job immediately
mci run usb-swap-repair -f

# List all configured jobs and statuses
mci list

# View latest logs
mci logs amtm-general-autoupdate
```

---

## 📄 License
MIT License. Created for the Asuswrt-Merlin community.
