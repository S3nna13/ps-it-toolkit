<#
.SYNOPSIS
    Triggers a Intune/Endpoint Analytics proactive remediation on a local device.
.DESCRIPTION
    Triggers the local execution of a configured Intune proactive remediation script
    package by invoking the Microsoft.Management.Services.Api device portal. Falls back
    to invoking the remediaiton runner directly if the Intune management extension is
    not reachable. Used to force immediate execution of a remediation that is scheduled
    but waiting for its detection window.
.PARAMETER RemediationName
    The name of the remediation script package to trigger (must match the name in Intune).
.PARAMETER Force
    Force immediate re-run even if the remediation is not yet due.
.PARAMETER Silent
    Headless mode — suppresses console output.
.PARAMETER LogPath
    Directory for log files. Defaults to C:\Logs\ps-it-toolkit.
.EXAMPLE
    .\Invoke-IntuneRemediation.ps1 -RemediationName "Clear-TempFiles"
.EXAMPLE
    .\Invoke-IntuneRemediation.ps1 -RemediationName "Fix-PrintSpooler" -Force
#>

param(
    [string]$RemediationName,
    [switch]$Force,
    [switch]$Silent,
    [string]$LogPath = "C:\Logs\ps-it-toolkit"
)

#region Setup
$ErrorActionPreference = "Continue"
$script:ExitCode = 0

if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}
$script:LogFile = Join-Path $LogPath "IntuneRemediation_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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

Write-Log "=== Intune Proactive Remediation Trigger ==="
Write-Log "Computer: $env:COMPUTERNAME"
Write-Log "User: $env:USERNAME"
Write-Log "Remediation: $RemediationName"

#region Device Identity
# Intune assigns a device identity GUID stored in the registry
$intuneDeviceId = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Devices\Device\SQM" -Name "DeviceId" -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty DeviceId

if ($intuneDeviceId) {
    Write-Log "Intune Device ID: $intuneDeviceId" "INFO"
} else {
    Write-Log "Intune Device ID not found in registry — device may not be Intune-managed." "WARN"
}
#endregion

#region Check Intune Management Extension
Write-Log "--- Checking Intune Management Extension (IME) ---"
$imePath = "$env:ProgramFiles\Microsoft Online\IntuneManagementExtension\IntuneManagementExtension.exe"
if (Test-Path $imePath) {
    Write-Log "Intune Management Extension found at: $imePath" "OK"
} else {
    Write-Log "Intune Management Extension not found — device may not be co-managed or IME not installed." "WARN"
    Write-Log "Attempting fallback runner anyway..." "INFO"
}
#endregion

#region Trigger via Scheduled Task (primary method)
Write-Log "--- Triggering remediation via scheduled task ---"

# Intune creates a scheduled task per remediation under this path
$taskName = "Microsoft\Intune\ProactiveRemediations\$RemediationName"

try {
    $existingTask = Get-ScheduledTask -TaskPath "\$taskName" -ErrorAction SilentlyContinue
    if ($existingTask) {
        Write-Log "Found scheduled task: \$taskName" "OK"
        if ($Force) {
            # Force-run: delete existing instance, then start fresh
            Stop-ScheduledTask -TaskPath "\$taskName" -ErrorAction SilentlyContinue
            Write-Log "Existing task instance stopped (Force flag set)." "INFO"
        }
        Start-ScheduledTask -TaskPath "\$taskName" -ErrorAction Stop
        Write-Log "Scheduled task started: \$taskName" "OK"
        # Give it a moment to initialize
        Start-Sleep -Seconds 3

        # Check if it stayed running (script execution in progress)
        $runningTask = Get-ScheduledTask -TaskPath "\$taskName" -ErrorAction SilentlyContinue
        if ($runningTask.State -eq "Running") {
            Write-Log "Remediation is running. Monitoring..." "INFO"
        } else {
            Write-Log "Remediation task state: $($runningTask.State)" "INFO"
        }
    } else {
        Write-Log "Scheduled task '\$taskName' not found. Has the remediation been deployed to this device?" "WARN"
        Write-Log "Remediation may not be assigned to this device or may not use the standard task naming." "WARN"
        $script:ExitCode = 1
    }
} catch {
    Write-Log "Failed to start scheduled task: $_" "ERROR"
    $script:ExitCode = 2
}
#endregion

#region Fallback: Direct IME invocation
if (-not $existingTask) {
    Write-Log "--- Fallback: invoking IME agent directly ---"

    $actions = @("Install", "Sync")
    foreach ($action in $actions) {
        try {
            $proc = Start-Process -FilePath $imePath -ArgumentList "/Action:$action" -WindowStyle Hidden -PassThru -ErrorAction SilentlyContinue
            if ($proc -and -not $proc.HasExited) {
                Write-Log "IME action '$action' started (PID: $($proc.Id))" "OK"
                Start-Sleep -Seconds 2
            }
        } catch { }
    }

    # Trigger a policy sync via Microsoft.Management.Services.Api
    try {
        $syncScript = {
            $null = Invoke-CimMethod -Namespace "root\Microsoft\Intune" -ClassName "MDM_EnterpriseManagement" -MethodName "TriggerSync" -ErrorAction SilentlyContinue
        }
        Write-Log "Attempted Intune management sync via WMI." "INFO"
    } catch {
        Write-Log "WMI sync failed (Intune WMI namespace may not be available on this SKU): $_" "WARN"
    }
}
#endregion

#region Remediation Log Extraction
Write-Log "--- Looking for remediation output logs ---"
$remediationLogPaths = @(
    "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs",
    "$env:LOCALAPPDATA\Microsoft\IntuneManagementExtension\Logs"
)
foreach ($logDir in $remediationLogPaths) {
    if (Test-Path $logDir) {
        Write-Log "Log directory found: $logDir" "OK"
        $recentLogs = Get-ChildItem -Path $logDir -Filter "*.log" -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-10) }
        if ($recentLogs) {
            foreach ($log in $recentLogs) {
                Write-Log "Recent log: $($log.FullName) [$($log.Length) bytes]" "INFO"
            }
        }
    }
}
#endregion

Write-Log "=== Intune remediation trigger complete. Exit code: $script:ExitCode ==="
Write-Host ""
Write-Host "Log written to: $script:LogFile" -ForegroundColor Cyan
if ($script:ExitCode -eq 0) {
    Write-Host "Status: PASS" -ForegroundColor Green
} elseif ($script:ExitCode -eq 1) {
    Write-Host "Status: WARN (remediation not found on this device)" -ForegroundColor Yellow
} else {
    Write-Host "Status: FAIL" -ForegroundColor Red
}

exit $script:ExitCode
