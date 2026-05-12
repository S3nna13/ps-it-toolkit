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
.\Invoke-AutopilotReenroll.ps1
.\Invoke-AutopilotReenroll.ps1 -NewName "WS-SURFACE-042" -Silent
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
.\Invoke-WindowsRepair.ps1          # Interactive menu
.\Invoke-WindowsRepair.ps1 -Tier 1 # Quick fix only
.\Invoke-WindowsRepair.ps1 -Silent  # Full repair, headless (standard RMM run)
```

---

## Clear-Office365Tokens.ps1

Clears cached Microsoft 365 authentication tokens to resolve sign-in loops, token expiry issues, and credential prompts.

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `-ResetProfile` | `switch` | Also removes Outlook profile registry keys |
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
.\Clear-Office365Tokens.ps1
.\Clear-Office365Tokens.ps1 -ResetProfile
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
| `WindowsAndDellUpdate_YYYYMMDD_HHMMSS.log` | Per-run log with timestamps and status |
| `InstalledUpdates_YYYYMMDD.log` | Shared KB audit log — KB number, title, status |

### Example

```powershell
.\Update-WindowsAndDell.ps1
.\Update-WindowsAndDell.ps1 -WindowsOnly
.\Update-WindowsAndDell.ps1 -Silent
```

---

## Sync-SystemTime.ps1

Re-synchronizes the system clock with an NTP server and validates the resulting offset. Designed for MDM-enrolled devices that have accumulated clock drift.

Clock drift causes: Kerberos failures, certificate validation errors, Azure AD sign-in issues, Teams meeting join failures.

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
.\Sync-SystemTime.ps1
.\Sync-SystemTime.ps1 -NTPServer "pool.ntp.org"
.\Sync-SystemTime.ps1 -NTPServer "ntp.corp.example.com" -Silent
```

---

## Invoke-NetworkDiag.ps1

Runs a comprehensive battery of network connectivity, DNS, latency, and configuration checks. In `-Silent` mode, outputs a machine-parseable JSON report.

### Checks performed

1. ICMP ping to 8.8.8.8, 1.1.1.1, time.windows.com
2. DNS resolution for microsoft.com, google.com, github.com, azure.microsoft.com
3. DNS resolver cache health
4. TCP port connectivity: port 53 (DNS), 443 (HTTPS) for key endpoints
5. IP configuration snapshot (adapters, MACs, IPs, DNS servers)
6. Default gateway reachability
7. Winsock catalog integrity

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `-Silent` | `switch` | Headless — outputs JSON report to log instead of console table |
| `-LogPath` | `string` | Log output directory (default: `C:\Logs\ps-it-toolkit`) |

### Example

```powershell
.\Invoke-NetworkDiag.ps1                    # Colorized console summary
.\Invoke-NetworkDiag.ps1 -Silent            # JSON report to log file
```

---

## Test-BackupStatus.ps1

Verifies the health and recent completion status of configured Windows backups. Checks Windows Server Backup catalog, File History, VSS writers, and an optional custom backup path.

### Checks performed

1. **Windows Server Backup** — catalog exists, backup < 3 days old, last job HResult = 0
2. **File History** — configured and last copied < 2 days ago
3. **VSS Writers** — all writers in stable state (state ≠ 1 is flagged)
4. **Custom path** — optional path checked for recent file activity

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `-BackupPath` | `string` | Optional path to a legacy backup destination to also check |
| `-Silent` | `switch` | Suppress console output |
| `-LogPath` | `string` | Log output directory (default: `C:\Logs\ps-it-toolkit`) |

### Example

```powershell
.\Test-BackupStatus.ps1
.\Test-BackupStatus.ps1 -BackupPath "\\nas\backups"
.\Test-BackupStatus.ps1 -Silent
```

---

## Invoke-IntuneRemediation.ps1

Triggers a named Intune proactive remediation script package by invoking its scheduled task directly. Use when a remediation is deployed but waiting for its detection window and you need it to run now.

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `-RemediationName` | `string` | Name of the remediation script package (must match Intune deployment) |
| `-Force` | `switch` | Stop any existing running instance before starting |
| `-Silent` | `switch` | Suppress console output |
| `-LogPath` | `string` | Log output directory (default: `C:\Logs\ps-it-toolkit`) |

### Example

```powershell
.\Invoke-IntuneRemediation.ps1 -RemediationName "Clear-TempFiles"
.\Invoke-IntuneRemediation.ps1 -RemediationName "Fix-PrintSpooler" -Force
```

---

## Clear-PrintSpooler.ps1

Stops the Print Spooler service, deletes all pending print jobs from the spool directory, optionally removes and reinstalls a specific printer driver, restarts the service, and verifies the queue is empty.

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `-DriverName` | `string` | Optional driver name to remove and reinstall after clearing |
| `-Silent` | `switch` | Suppress console output |
| `-LogPath` | `string` | Log output directory (default: `C:\Logs\ps-it-toolkit`) |

### Example

```powershell
.\Clear-PrintSpooler.ps1
.\Clear-PrintSpooler.ps1 -DriverName "HP LaserJet 400 MFP M425"
```

---

## Invoke-DiskCleanup.ps1

Performs a configurable disk cleanup targeting temp files, browser caches, Windows Update cache, prefetch data, and old log files. Shows space reclaimed per category and total.

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `-BrowserCaches` | `switch` | Also clear Edge, Chrome, and Firefox caches |
| `-UpdateCache` | `switch` | Also clear Windows Update download cache |
| `-DaysOld` | `int` | Only delete files older than N days (default: 3, 0 = all) |
| `-Silent` | `switch` | Suppress console output |
| `-LogPath` | `string` | Log output directory (default: `C:\Logs\ps-it-toolkit`) |

### What it cleans

- `%TEMP%` and `System32\Temp` (user and system temp)
- `Windows\Prefetch` (prefetch data)
- `*.log` files older than threshold
- `Windows\SoftwareDistribution\Download` (when `-UpdateCache`)
- Chrome, Edge, Firefox browser caches (when `-BrowserCaches`)

### Example

```powershell
.\Invoke-DiskCleanup.ps1
.\Invoke-DiskCleanup.ps1 -BrowserCaches -UpdateCache -DaysOld 7 -Silent
```

---

## Test-ServiceHealth.ps1

Checks the health and startup configuration of a list of Windows services. Validates status, startup type, and critical dependency chains. Designed for scheduled RMM health-check runs.

### Default critical services checked (24)

`WinDefend`, `wscsvc`, `BITS`, `wuauserv`, `Spooler`, `W32Time`, `Dnscache`, `Netlogon`, `eventlog`, `RpcSs`, `Dhcp`, `LanmanServer`, `LanmanWorkstation`, `IKEEXT`, `iphlpsvc`, `PolicyAgent`, `gpsvc`, `SessionEnv`, `TermService`, `UmRdpService`, `MpsSvc`, `TrustedInstaller`, `Winmgmt`

### Dependency chains validated

- `Winmgmt` → `RpcSs`, `DcomLaunch`
- `Spooler` → `RpcSs`
- `WinDefend` → `RpcSs`, `Winmgmt`

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `-ServiceNames` | `string` | Comma-separated list of service names (default: 24 critical services) |
| `-Silent` | `switch` | Suppress console output |
| `-LogPath` | `string` | Log output directory (default: `C:\Logs\ps-it-toolkit`) |

### Example

```powershell
.\Test-ServiceHealth.ps1
.\Test-ServiceHealth.ps1 -ServiceNames "Spooler,W32Time,BITS" -Silent
```

---

## Reset-NetworkAdapter.ps1

Disables and re-enables a specific network adapter, flushes the ARP cache for that adapter, optionally releases/renews DHCP, and verifies basic connectivity is restored. Use to recover from DHCP failures, IP conflicts, or VPN stack corruption without affecting other interfaces.

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `-AdapterName` | `string` | **Required.** Name or partial name of the adapter (supports `*name*` wildcards) |
| `-ReleaseDHCP` | `switch` | Also run `ipconfig /release` and `/renew` on this adapter after reset |
| `-Silent` | `switch` | Suppress console output |
| `-LogPath` | `string` | Log output directory (default: `C:\Logs\ps-it-toolkit`) |

### Example

```powershell
.\Reset-NetworkAdapter.ps1 -AdapterName "Ethernet"
.\Reset-NetworkAdapter.ps1 -AdapterName "Wi-Fi" -ReleaseDHCP
.\Reset-NetworkAdapter.ps1 -AdapterName "VPN" -Silent
```

---

## Reset-ADPassword.ps1

Resets a local Windows account or Active Directory user account password. When no password is provided, generates a secure 16-character random password that meets complexity requirements and logs it. Optionally forces a password change on next logon.

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `-Account` | `string` | **Required.** Username (local: `.\Username` or `Username`; AD: `DOMAIN\Username`) |
| `-NewPassword` | `string` | New password (omit to generate a secure random 16-char password) |
| `-ForceChangeLogon` | `switch` | Force the account to require a password change on next logon |
| `-Silent` | `switch` | Suppress console output |
| `-LogPath` | `string` | Log output directory (default: `C:\Logs\ps-it-toolkit`) |

### Password complexity

Minimum 8 characters, at least one uppercase letter, one lowercase letter, one digit, and one special character (`!@#$%^&*-_+=?`).

### Example

```powershell
# Reset local account, generate random password
.\Reset-ADPassword.ps1 -Account "jsmith"

# Reset AD account with explicit password
.\Reset-ADPassword.ps1 -Account "CORP\jsmith" -NewPassword "N3wP@ssw0rd!" -ForceChangeLogon

# Silent run (generate + log)
.\Reset-ADPassword.ps1 -Account "admin" -Silent
```

---

## Exit Code Reference

| Code | Meaning | Typical cause |
|------|---------|---------------|
| `0` | Success | All operations completed cleanly |
| `1` | Warning | Partial failure — script recovered or continued but something didn't succeed |
| `2` | Failure | Critical operation failed — admin check, service stop, NTP server unreachable |
