# ps-it-toolkit

Enterprise IT automation scripts for RMM deployment on Windows 10/11.

A curated collection of production-ready PowerShell scripts covering Windows repair, MDM Autopilot lifecycle management, Microsoft 365 token fatigue, system time synchronization, automated OS/Dell firmware updates, network diagnostics, backup verification, Intune remediation, and more.

[![CI](https://github.com/S3nna13/ps-it-toolkit/actions/workflows/ci.yml/badge.svg)](https://github.com/S3nna13/ps-it-toolkit/actions/workflows/ci.yml)
[![MIT License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

---

## Scripts (13 total)

| Script | Description | Key Parameters |
|--------|-------------|-----------------|
| `Invoke-AutopilotReenroll.ps1` | Removes current MDM/Autopilot enrollment and triggers a fresh enrollment | `-NewName`, `-Silent` |
| `Invoke-WindowsRepair.ps1` | Three-tier Windows repair: quick fix, network reset, or full rebuild | `-Tier`, `-Silent` |
| `Clear-Office365Tokens.ps1` | Kills Office processes, clears ADAL/MSAL token caches and Windows Credential Manager entries | `-ResetProfile`, `-NoRestart`, `-Silent` |
| `Update-WindowsAndDell.ps1` | Runs Windows Update and Dell Command Update in parallel; logs all installed KBs | `-WindowsOnly`, `-DellOnly`, `-Silent` |
| `Sync-SystemTime.ps1` | Re-registers w32time with an NTP server, forces a sync, and validates offset < 2s | `-NTPServer`, `-Silent` |
| `Invoke-NetworkDiag.ps1` | Comprehensive network diagnostics: ping, DNS, TCP ports, IP config, gateway | `-Silent` |
| `Test-BackupStatus.ps1` | Checks Windows Server Backup, File History, VSS writers, and optional custom path | `-BackupPath`, `-Silent` |
| `Invoke-IntuneRemediation.ps1` | Triggers an Intune proactive remediation by scheduled task name | `-RemediationName`, `-Force`, `-Silent` |
| `Clear-PrintSpooler.ps1` | Stops spooler, deletes queue files, optionally reinstalls a driver, restarts service | `-DriverName`, `-Silent` |
| `Invoke-DiskCleanup.ps1` | Removes temp files, browser caches, update cache, old logs; shows space reclaimed | `-BrowserCaches`, `-UpdateCache`, `-DaysOld`, `-Silent` |
| `Test-ServiceHealth.ps1` | Checks 24 critical Windows services (status, startup type, dependency chains) | `-ServiceNames`, `-Silent` |
| `Reset-NetworkAdapter.ps1` | Disables/re-enables a specific adapter, flushes ARP, renews DHCP, verifies connectivity | `-AdapterName`, `-ReleaseDHCP`, `-Silent` |
| `Reset-ADPassword.ps1` | Resets local or AD account password, generates secure random password, optional force change on logon | `-Account`, `-NewPassword`, `-ForceChangeLogon`, `-Silent` |

---

## Quick Start

```powershell
# Clone the repository
git clone https://github.com/S3nna13/ps-it-toolkit.git
cd ps-it-toolkit

# Run a single script (requires admin)
.\scripts\Invoke-WindowsRepair.ps1

# Silent / RMM mode
.\scripts\Invoke-WindowsRepair.ps1 -Silent
.\scripts\Invoke-AutopilotReenroll.ps1 -NewName "WS-DELL-001" -Silent

# Network diagnostics
.\scripts\Invoke-NetworkDiag.ps1 -Silent | ConvertFrom-Json  # machine-parseable output

# Service health check
.\scripts\Test-ServiceHealth.ps1 -Silent

# Time sync
.\scripts\Sync-SystemTime.ps1 -NTPServer "pool.ntp.org"
```

---

## RMM Deployment

All scripts support `-Silent` and `-LogPath` for fully unattended execution in RMM tools (Intune, SCCM, ConnectWise, NinjaOne, etc.).

```powershell
# Full Windows repair in silent mode
.\scripts\Invoke-WindowsRepair.ps1 -Silent

# Clear tokens and reset Outlook profile
.\scripts\Clear-Office365Tokens.ps1 -ResetProfile -Silent

# Sync time, then re-enroll Autopilot
.\scripts\Sync-SystemTime.ps1 -Silent
.\scripts\Invoke-AutopilotReenroll.ps1 -Silent

# Network adapter reset (e.g. after VPN crash)
.\scripts\Reset-NetworkAdapter.ps1 -AdapterName "VPN" -ReleaseDHCP -Silent

# Disk cleanup with browser caches and update cache
.\scripts\Invoke-DiskCleanup.ps1 -BrowserCaches -UpdateCache -DaysOld 7 -Silent
```

> **Note:** All scripts require **Administrator privileges**. In RMM contexts, deploy via a privileged account or use a sandboxed admin context.

---

## Requirements

| Requirement | Version |
|-------------|---------|
| PowerShell  | 5.1+    |
| OS          | Windows 10, Windows 11 |
| Rights      | Local Administrator    |
| Network     | Internet access for Windows Update, NTP sync, and network diagnostics |
| Modules     | `PSWindowsUpdate` for `Update-WindowsAndDell.ps1` (auto-installed if missing) |

---

## Exit Codes

| Code | Meaning |
|------|---------|
| `0`  | Success — all operations completed cleanly |
| `1`  | Warning — completed with non-critical failures (e.g. one step failed, reboot pending) |
| `2`  | Failure — critical operation failed (e.g. admin check, service stop, NTP server unreachable) |

---

## Logging

All scripts write logs to `C:\Logs\ps-it-toolkit\` by default. Override with `-LogPath`.

```
C:\Logs\ps-it-toolkit\
├── AutopilotReenroll_20250512_143022.log
├── WindowsRepair_20250512_143500.log
├── O365Tokens_20250512_144100.log
├── WindowsAndDellUpdate_20250512_080000.log
├── SyncSystemTime_20250512_120000.log
├── NetworkDiag_20250512_130000.log
├── NetworkDiag_Report_20250512_130000.json   ← JSON report (Silent mode)
├── BackupStatus_20250512_090000.log
├── IntuneRemediation_20250512_091500.log
├── PrintSpooler_20250512_092000.log
├── DiskCleanup_20250512_093000.log
├── DiskCleanup_SpaceReclaimed_20250512.log    ← daily space trend log
├── ServiceHealth_20250512_100000.log
├── NetworkAdapterReset_20250512_101500.log
└── ResetPassword_20250512_102000.log
```

---

## CI/CD

- **PSScriptAnalyzer** runs on every push and PR (errors only)
- **GitHub Actions Release** — tag with `v*` to auto-create a GitHub release with zip artifact

---

## Installing via Chocolatey (coming soon)

```powershell
choco install ps-it-toolkit -y
```

---

## License

[![MIT License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

MIT License — see [LICENSE](LICENSE) for full terms.
