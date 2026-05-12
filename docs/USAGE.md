# USAGE — ps-it-toolkit

Detailed usage guide for each script.

---

## Invoke-AutopilotReenroll.ps1

Removes MDM/Autopilot enrollment state and triggers a fresh enrollment. Use after device imaging or when the Autopilot profile has drifted.

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `-NewName` | `string` | Optional new computer name to assign after cleanup |
| `-Silent` | `switch` | Suppress console output; logs to file only |
| `-LogPath` | `string` | Log output directory (default: `C:\Logs\ps-it-toolkit`) |

### What it does

1. Validates administrator privileges
2. Syncs system time via NTP (time.windows.com) — enrollment is time-sensitive
3. Removes MDM registry keys under `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MDM`
4. Removes Autopilot scheduled tasks
5. Optionally renames the computer
6. Triggers `DeviceEnroller.exe /OOBE /Silent` to start fresh enrollment

### Example

```powershell
# Basic reenrollment
.\Invoke-AutopilotReenroll.ps1

# With device rename, headless
.\Invoke-AutopilotReenroll.ps1 -NewName "WS-SURFACE-042" -Silent

# After imaging — enroll then rename
.\Invoke-AutopilotReenroll.ps1 -NewName "WS-DELL-001"
```

---

## Invoke-WindowsRepair.ps1

Three-tier repair tool for Windows 10/11. Tiers escalate from quick wins to full component reset.

### Tiers

| Tier | Operations | Use when |
|------|-----------|----------|
| **1 — Quick Fix** | `DISM /RestoreHealth`, `SFC /scannow`, Disk Cleanup | System is slow, apps crash occasionally |
| **2 — Network Reset** | Flush DNS, reset Winsock, release/renew IP, clear ARP | Network connectivity issues, VPN problems |
| **3 — Full Repair** | Tier 1 + Tier 2 + Windows Update component reset + DLL re-registration | Update failures, component store corruption |

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `-Tier` | `int` | Explicitly select tier 1, 2, or 3 (overrides menu) |
| `-Silent` | `switch` | Runs Tier 3 automatically without displaying the menu |
| `-LogPath` | `string` | Log output directory (default: `C:\Logs\ps-it-toolkit`) |

### Example

```powershell
# Interactive menu
.\Invoke-WindowsRepair.ps1

# Quick fix only
.\Invoke-WindowsRepair.ps1 -Tier 1

# Full repair, headless (standard RMM run)
.\Invoke-WindowsRepair.ps1 -Silent

# Network reset only
.\Invoke-WindowsRepair.ps1 -Tier 2
```

---

## Clear-Office365Tokens.ps1

Clears cached Microsoft 365 authentication tokens to resolve sign-in loops, token expiry issues, and credential prompts.

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `-ResetProfile` | `switch` | Also removes Outlook profile registry keys under `HKCU:\SOFTWARE\Microsoft\Office\*\Outlook\Profiles` |
| `-NoRestart` | `switch` | Do not restart Outlook after clearing tokens |
| `-Silent` | `switch` | Suppress console output |
| `-LogPath` | `string` | Log output directory (default: `C:\Logs\ps-it-toolkit`) |

### What it clears

- ADAL token cache: `%LOCALAPPDATA%\Microsoft\ADAL`
- MSAL token cache: `%LOCALAPPDATA%\Microsoft\MSAL`, `%LOCALAPPDATA%\Microsoft\IdentityStore`
- Office Identity cache: `%LOCALAPPDATA%\Microsoft\Office\16.0\Common\Identity`
- Windows Credential Manager: `cmdkey /delete` targets for `MicrosoftOffice16_Data:*`, `MicrosoftOffice15_Data:*`
- Outlook Profiles (when `-ResetProfile` is used)

### Example

```powershell
# Clear tokens, restart Outlook
.\Clear-Office365Tokens.ps1

# Clear tokens and reset Outlook profile (fresh setup on next launch)
.\Clear-Office365Tokens.ps1 -ResetProfile

# Headless token clear without restarting Office
.\Clear-Office365Tokens.ps1 -NoRestart -Silent
```

---

## Update-WindowsAndDell.ps1

Runs Windows Update (via PSWindowsUpdate) and Dell Command Update concurrently and logs all installed KBs to a shared audit file.

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `-WindowsOnly` | `switch` | Skip Dell Command Update |
| `-DellOnly` | `switch` | Skip Windows Update |
| `-Silent` | `switch` | Suppress per-update chatter; summary still shown |
| `-LogPath` | `string` | Log output directory (default: `C:\Logs\ps-it-toolkit`) |

### Output files

| File | Contents |
|------|----------|
| `WindowsAndDellUpdate_YYYYMMDD_HHMMSS.log` | Per-script run log with timestamps and status |
| `InstalledUpdates_YYYYMMDD.log` | Shared KB audit log — KB number, title, status per update, per run |

### Example

```powershell
# Full parallel update (Windows + Dell)
.\Update-WindowsAndDell.ps1

# Windows updates only
.\Update-WindowsAndDell.ps1 -WindowsOnly

# Dell firmware/driver update only (no Windows Update)
.\Update-WindowsAndDell.ps1 -DellOnly

# Headless full update for RMM
.\Update-WindowsAndDell.ps1 -Silent
```

### KB Audit Log format

```
2025-05-12 08:15:00|KB5055528|Windows Security Update|Installed
2025-05-12 08:15:32|KB5056619|Cumulative Update .NET Framework|Installed
```

---

## Sync-SystemTime.ps1

Re-synchronizes the system clock with an NTP server and validates the resulting offset. Designed for MDM-enrolled devices that have accumulated clock drift.

Clock drift causes:
- Kerberos authentication failures
- Certificate validation errors
- Azure AD / Microsoft 365 sign-in issues
- Teams/Skype meeting join failures

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `-NTPServer` | `string` | NTP server hostname (default: `time.windows.com`) |
| `-Silent` | `switch` | Suppress console output |
| `-LogPath` | `string` | Log output directory (default: `C:\Logs\ps-it-toolkit`) |

### Validation

The script validates that the time offset is **under 2 seconds** after sync. If the offset exceeds 2s after 3 attempts, it exits with code `1` (warning) and logs the measured offset.

### Example

```powershell
# Default NTP server
.\Sync-SystemTime.ps1

# Use a public NTP pool
.\Sync-SystemTime.ps1 -NTPServer "pool.ntp.org"

# Corporate NTP server, silent
.\Sync-SystemTime.ps1 -NTPServer "ntp.corp.example.com" -Silent
```

---

## Exit Code Reference

| Code | Meaning | Typical cause |
|------|---------|---------------|
| `0` | Success | All operations completed cleanly |
| `1` | Warning | Partial failure — script recovered or continued but something didn't succeed |
| `2` | Failure | Critical operation failed — admin check, service stop, DISM, NTP server unreachable |
