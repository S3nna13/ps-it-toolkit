# ps-it-toolkit

Enterprise IT automation scripts for RMM deployment on Windows 10/11.

A curated collection of production-ready PowerShell scripts covering Windows repair, MDM Autopilot lifecycle management, Microsoft 365 token fatigue, system time synchronization, and automated OS/Dell firmware updates.

---

## Scripts

| Script | Description | Key Parameters |
|--------|-------------|-----------------|
| `Invoke-AutopilotReenroll.ps1` | Removes current MDM/Autopilot enrollment, optionally renames the device, and triggers a fresh enrollment | `-NewName`, `-Silent` |
| `Invoke-WindowsRepair.ps1` | Three-tier Windows repair: quick fix, network reset, or full rebuild | `-Tier`, `-Silent` |
| `Clear-Office365Tokens.ps1` | Kills Office processes, clears ADAL/MSAL token caches and Windows Credential Manager entries | `-ResetProfile`, `-NoRestart`, `-Silent` |
| `Update-WindowsAndDell.ps1` | Runs Windows Update and Dell Command Update in parallel; logs all installed KBs | `-WindowsOnly`, `-DellOnly`, `-Silent` |
| `Sync-SystemTime.ps1` | Re-registers w32time with an NTP server, forces a sync, and validates offset < 2s | `-NTPServer`, `-Silent` |

---

## Quick Start

```powershell
# Clone or download the repository
git clone https://github.com/YOUR_HANDLE/ps-it-toolkit.git
cd ps-it-toolkit

# Run a single script (requires admin)
.\scripts\Invoke-WindowsRepair.ps1

# Run with headless / RMM mode
.\scripts\Invoke-WindowsRepair.ps1 -Silent
.\scripts\Invoke-AutopilotReenroll.ps1 -NewName "WS-DELL-001" -Silent

# Run a specific repair tier
.\scripts\Invoke-WindowsRepair.ps1 -Tier 2

# Time sync with custom NTP server
.\scripts\Sync-SystemTime.ps1 -NTPServer "pool.ntp.org"

# Windows updates only (skip Dell)
.\scripts\Update-WindowsAndDell.ps1 -WindowsOnly -Silent
```

---

## RMM Deployment

All scripts support `-Silent` and `-LogPath` for fully unattended execution in RMM tools (Intune, SCCM, ConnectWise, NinjaOne, etc.).

```powershell
# Deploy via Intune / Proactive Remediations
# Run as SYSTEM or logged-on user with admin privileges

# Example: Full Windows repair in silent mode
.\scripts\Invoke-WindowsRepair.ps1 -Silent

# Example: Clear tokens and reset Outlook profile
.\scripts\Clear-Office365Tokens.ps1 -ResetProfile -Silent

# Example: Sync time before Autopilot reenrollment
.\scripts\Sync-SystemTime.ps1 -Silent
.\scripts\Invoke-AutopilotReenroll.ps1 -Silent
```

> **Note:** All scripts require **Administrator privileges**. In RMM contexts, deploy via a privileged account or use a sandboxed admin context.

---

## Requirements

| Requirement | Version |
|-------------|---------|
| PowerShell  | 5.1+    |
| OS          | Windows 10, Windows 11 |
| Rights      | Local Administrator    |
| Network     | Internet access for Windows Update and NTP sync |
| Modules     | `PSWindowsUpdate` for `Update-WindowsAndDell.ps1` (auto-installed if missing) |

---

## Exit Codes

| Code | Meaning |
|------|---------|
| `0`  | Success — all operations completed cleanly |
| `1`  | Warning — completed with non-critical failures (e.g., one network reset step failed, reboot pending) |
| `2`  | Failure — critical operation failed (e.g., admin check, DISM/SFC, NTP server unreachable) |

---

## Logging

All scripts write logs to `C:\Logs\ps-it-toolkit\` by default. Override with `-LogPath`:

```
C:\Logs\ps-it-toolkit\
├── AutopilotReenroll_20250512_143022.log
├── WindowsRepair_20250512_143500.log
├── O365Tokens_20250512_144100.log
├── WindowsAndDellUpdate_20250512_080000.log
├── SyncSystemTime_20250512_120000.log
└── InstalledUpdates_20250512.log   ← shared KB audit log
```

---

## License

[![MIT License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

MIT License — see [LICENSE](LICENSE) for full terms.
