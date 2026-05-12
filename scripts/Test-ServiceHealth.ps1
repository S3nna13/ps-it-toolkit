<#
.SYNOPSIS
    Checks the health and running status of critical Windows services and dependencies.
.DESCRIPTION
    Queries a configurable list of Windows services, checks their status and startup type,
    validates dependency chains, and reports any stopped or misconfigured services.
    Designed for RMM health-check scripts that run on a schedule and alert on failures.
.PARAMETER ServiceNames
    Comma-separated list of service names to check. Defaults to the critical list below.
.PARAMETER Silent
    Headless mode — suppresses console output; logs results to file only.
.PARAMETER LogPath
    Directory for log files. Defaults to C:\Logs\ps-it-toolkit.
.EXAMPLE
    .\Test-ServiceHealth.ps1
.EXAMPLE
    .\Test-ServiceHealth.ps1 -ServiceNames "Spooler,W32Time,BITS" -Silent
#>

param(
    [string]$ServiceNames,
    [switch]$Silent,
    [string]$LogPath = "C:\Logs\ps-it-toolkit"
)

#region Setup
$ErrorActionPreference = "Continue"
$script:ExitCode = 0

if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}
$script:LogFile = Join-Path $LogPath "ServiceHealth_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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

# Default critical service list
$defaultServices = @(
    "WinDefend",           # Windows Defender
    "wscsvc",              # Windows Security Center
    "WdNisSvc",            # NIS for Windows Defender
    "BITS",                # Background Intelligent Transfer Service
    "wuauserv",            # Windows Update
    "Spooler",             # Print Spooler
    "W32Time",             # Windows Time (NTP)
    "Dnscache",            # DNS Client
    "Netlogon",            # Netlogon (AD domain auth)
    "eventlog",            # Windows Event Log
    "RpcSs",               # RPC Endpoint Mapper
    "Dhcp",                # DHCP Client
    "LanmanServer",        # File and Printer Sharing
    "LanmanWorkstation",   # WebClient (used by some backup agents)
    "IKEEXT",              # IKE and AuthIP IPsec Keying Modules
    "iphlpsvc",            # IP Helper (IPv6 transition)
    "PolicyAgent",         # Group Policy Client
    "gpsvc",               # Group Policy Client
    "SessionEnv",          # Remote Desktop Configuration
    "TermService",         # Remote Desktop Services
    "UmRdpService",        # Remote Desktop Services UserMode Port Redirector
    "MpsSvc",              # Windows Firewall
    "TrustedInstaller",    # Windows Module Installer (Updates)
    "Winmgmt"              # WMI
)

$servicesToCheck = if ($ServiceNames) {
    $ServiceNames -split "," | ForEach-Object { $_.Trim() }
} else {
    $defaultServices
}

Write-Log "=== Service Health Check starting ==="
Write-Log "Services to check: $($servicesToCheck -join ', ')"

$results = @()

foreach ($svcName in $servicesToCheck) {
    try {
        $svc = Get-Service -Name $svcName -ErrorAction Stop
        $startup = (Get-CimInstance -ClassName Win32_Service -Filter "Name='$svcName'" -ErrorAction SilentlyContinue).StartMode

        $status  = $svc.Status
        $start   = $svc.StartType
        $desired = "Running"

        # Evaluate health
        $health = "PASS"
        $reason = ""

        if ($status -ne "Running") {
            $health = "FAIL"
            $reason = "Stopped (expected: Running)"
            $script:ExitCode = 2
        } elseif ($start -eq "Disabled") {
            $health = "FAIL"
            $reason = "Disabled (expected: Auto/Manual)"
            $script:ExitCode = 2
        } elseif ($start -eq "Manual") {
            $health = "WARN"
            $reason = "Manual start (may not auto-start after reboot)"
            if ($script:ExitCode -eq 0) { $script:ExitCode = 1 }
        }

        $results += @{
            Name         = $svc.DisplayName
            ServiceName  = $svcName
            Status       = $status
            StartType    = $start
            Health       = $health
            Reason       = $reason
        }

        if ($health -eq "PASS") {
            Write-Log "$svcName — PASS  | Status=$status StartType=$start" "OK"
        } elseif ($health -eq "WARN") {
            Write-Log "$svcName — WARN  | Status=$status StartType=$start | $reason" "WARN"
        } else {
            Write-Log "$svcName — FAIL  | Status=$status StartType=$start | $reason" "ERROR"
        }
    } catch {
        $results += @{
            Name         = $svcName
            ServiceName  = $svcName
            Status       = "Unknown"
            StartType    = "Unknown"
            Health       = "FAIL"
            Reason       = "Service not found on this system"
        }
        Write-Log "$svcName — FAIL  | Service not found" "ERROR"
        if ($script:ExitCode -eq 0) { $script:ExitCode = 1 }
    }
}

#region Dependency chain check for a few critical services
Write-Log "--- Dependency chain check ---"
$criticalDeps = @{
    "Winmgmt" = @("RpcSs", "DcomLaunch")
    "Spooler" = @("RpcSs")
    "WinDefend" = @("RpcSs", "Winmgmt")
}

foreach ($primary in $criticalDeps.Keys) {
    $deps = $criticalDeps[$primary]
    try {
        $svc = Get-Service -Name $primary -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq "Running") {
            foreach ($dep in $deps) {
                $depSvc = Get-Service -Name $dep -ErrorAction SilentlyContinue
                if ($depSvc -and $depSvc.Status -ne "Running") {
                    Write-Log "Dependency warning: '$primary' depends on '$dep' which is $($depSvc.Status)." "WARN"
                    if ($script:ExitCode -ne 2) { $script:ExitCode = 1 }
                }
            }
        }
    } catch { }
}
#endregion

#region Summary
$passCount = ($results | Where-Object { $_.Health -eq "PASS" }).Count
$warnCount = ($results | Where-Object { $_.Health -eq "WARN" }).Count
$failCount = ($results | Where-Object { $_.Health -eq "FAIL" }).Count

Write-Log "=== Service Health Check complete ==="
Write-Log "PASS: $passCount | WARN: $warnCount | FAIL: $failCount"

if (-not $Silent) {
    Write-Host ""
    Write-Host "=== Service Health Summary ===" -ForegroundColor Cyan
    Write-Host "PASS: $passCount   WARN: $warnCount   FAIL: $failCount" -ForegroundColor $(if ($failCount -eq 0 -and $warnCount -eq 0) { "Green" } elseif ($failCount -eq 0) { "Yellow" } else { "Red" })
    Write-Host ""
    $results | Sort-Object { $_.Health -ne "PASS" }, Health | ForEach-Object {
        $color = switch ($_.Health) { "PASS" { "Green" } "WARN" { "Yellow" } "FAIL" { "Red" } }
        Write-Host "  [$($_.Health.PadRight(4))] $($_.Name.PadRight(40)) $($_.Status) | $($_.StartType)" -ForegroundColor $color
        if ($_.Reason) { Write-Host "           $($_.Reason)" -ForegroundColor Gray }
    }
}

Write-Host ""
Write-Host "Log written to: $script:LogFile" -ForegroundColor Cyan
if ($script:ExitCode -eq 0) {
    Write-Host "Status: PASS — All services healthy" -ForegroundColor Green
} elseif ($script:ExitCode -eq 1) {
    Write-Host "Status: WARN — Some services need attention" -ForegroundColor Yellow
} else {
    Write-Host "Status: FAIL — Critical services are not running" -ForegroundColor Red
}

exit $script:ExitCode
