<#
.SYNOPSIS
    Synchronizes local system time with an NTP server and validates offset.
.DESCRIPTION
    Stops the w32time service, re-registers it with a configurable NTP server,
    forces an immediate sync, and validates that the resulting time offset is
    within 2 seconds. Useful for MDM-enrolled devices that develop clock drift,
    which can cause Kerberos failures, certificate issues, and Azure AD sign-in problems.
.PARAMETER NTPServer
    NTP server to use. Defaults to time.windows.com.
.PARAMETER Silent
    Headless mode — suppresses console output.
.PARAMETER LogPath
    Directory for log files. Defaults to C:\Logs\ps-it-toolkit.
.EXAMPLE
    .\Sync-SystemTime.ps1
.EXAMPLE
    .\Sync-SystemTime.ps1 -NTPServer "pool.ntp.org"
.EXAMPLE
    .\Sync-SystemTime.ps1 -NTPServer "time.google.com" -Silent
#>

param(
    [string]$NTPServer = "time.windows.com",
    [switch]$Silent,
    [string]$LogPath = "C:\Logs\ps-it-toolkit"
)

#region Setup
$ErrorActionPreference = "Continue"
$script:ExitCode = 0

if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}

$script:LogFile = Join-Path $LogPath "SyncSystemTime_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts [$Level] $Message" | Add-Content -Path $script:LogFile -Encoding UTF8
    if (-not $Silent) {
        switch ($Level) {
            "ERROR" { Write-Host "[ERROR] $Message" -ForegroundColor Red }
            "WARN"  { Write-Host "[WARN]  $Message" -ForegroundColor Yellow }
            "OK"    { Write-Host "[OK]    $Message" -ForegroundColor Green }
            default { Write-Host "[INFO]  $Message" }
        }
    }
}
#endregion

#region Admin Check
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal $currentIdentity
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log "Administrator privileges required. Exiting." "ERROR"
    exit 2
}
#endregion

#region Capture Before State
$beforeTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$beforeUtc  = [DateTime]::UtcNow.ToString("yyyy-MM-dd HH:mm:ss")
Write-Log "=== Time Sync starting ==="
Write-Log "Current local time : $beforeTime"
Write-Log "Current UTC time    : $beforeUtc"
Write-Log "Target NTP server  : $NTPServer"
#endregion

#region Stop and Re-register w32time Service
Write-Log "--- Stopping w32time service ---"
try {
    Stop-Service -Name w32time -Force -ErrorAction Stop
    Write-Log "w32time service stopped." "OK"
} catch {
    Write-Log "Failed to stop w32time: $_" "ERROR"
    exit 2
}

# Unregister removes current configuration
Write-Log "--- Unregistering w32time ---"
$null = & w32tm.exe /unregister 2>&1
Write-Log "w32time unregistered." "INFO"

# Re-register rebuilds the service with defaults
Write-Log "--- Re-registering w32time ---"
try {
    $null = & w32tm.exe /register 2>&1
    Write-Log "w32time re-registered." "OK"
} catch {
    Write-Log "Failed to re-register w32time: $_" "ERROR"
    exit 2
}
#endregion

#region Configure NTP Server
Write-Log "--- Configuring NTP server to: $NTPServer ---"

$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\w32time\Parameters"
try {
    # Set the NTP server source
    Set-ItemProperty -Path $regPath -Name NtpServer -Value $NTPServer -ErrorAction Stop
    # Set type to NTP (client mode)
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\w32time\Parameters" -Name Type -Value "NTP" -ErrorAction Stop
    # Set AnnounceFlags to 5 (0x5 = always sync, peer)
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\w32time\Config" -Name AnnounceFlags -Value 5 -ErrorAction Stop
    Write-Log "NTP server configured: $NTPServer" "OK"
} catch {
    Write-Log "Failed to configure NTP registry settings: $_" "ERROR"
    $script:ExitCode = 2
}
#endregion

#region Start Service and Force Sync
Write-Log "--- Starting w32time service ---"
try {
    Start-Service -Name w32time -ErrorAction Stop
    Write-Log "w32time service started." "OK"
} catch {
    Write-Log "Failed to start w32time: $_" "ERROR"
    exit 2
}

Write-Log "--- Forcing immediate NTP sync ---"
# /resync forces an immediate synchronization attempt
$syncOutput = & w32tm.exe /resync /force 2>&1 | Out-String
Write-Log "Resync output: $syncOutput" "INFO"
#endregion

#region Wait and Validate
Start-Sleep -Seconds 5

Write-Log "--- Validating time offset ---"
$offsetOk = $false
$attempts = 0

while ($attempts -lt 3) {
    $attempts++
    try {
        # Query the current time offset from the configured NTP server
        # /stripchart outputs a line like: "Sampling from time.windows.com, 0.0s offset"
        $stripOut = & w32tm.exe /stripchart /computer:$NTPServer /dataonly /samples:1 2>&1 | Out-String

        if ($stripOut -match "offset\s+([-0-9.]+)s") {
            $offsetSec = [Math]::Abs([double]$matches[1])
            Write-Log "Measured offset: $([Math]::Round($offsetSec, 3))s" "INFO"

            if ($offsetSec -lt 2.0) {
                Write-Log "Offset within tolerance (< 2s): PASS" "OK"
                $offsetOk = $true
                break
            } else {
                Write-Log "Offset still high ($([Math]::Round($offsetSec, 3))s). Retrying in 5s..." "WARN"
                Start-Sleep -Seconds 5
            }
        } else {
            Write-Log "Could not parse offset from stripchart output. Raw: $stripOut" "WARN"
            break
        }
    } catch {
        Write-Log "Offset check failed: $_" "WARN"
        break
    }
}

if (-not $offsetOk) {
    Write-Log "Time offset validation did not reach < 2s after $attempts attempt(s)." "WARN"
    $script:ExitCode = 1
}
#endregion

#region Final State
$afterTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$afterUtc  = [DateTime]::UtcNow.ToString("yyyy-MM-dd HH:mm:ss")

Write-Log "=== Time Sync complete ==="
Write-Log "Local time before : $beforeTime"
Write-Log "Local time after  : $afterTime"
Write-Log "UTC time before   : $beforeUtc"
Write-Log "UTC time after    : $afterUtc"

Write-Host ""
Write-Host "Log written to: $script:LogFile" -ForegroundColor Cyan
if ($offsetOk) {
    Write-Host "Status: PASS — offset within 2 seconds" -ForegroundColor Green
} elseif ($script:ExitCode -eq 0) {
    Write-Host "Status: PASS" -ForegroundColor Green
} elseif ($script:ExitCode -eq 1) {
    Write-Host "Status: WARN — offset check did not converge" -ForegroundColor Yellow
} else {
    Write-Host "Status: FAIL" -ForegroundColor Red
}

exit $script:ExitCode
