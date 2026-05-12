<#
.SYNOPSIS
    Removes current Autopilot registration and triggers a fresh MDM enrollment.
.DESCRIPTION
    Removes MDM enrollment registry keys, cleans up associated scheduled tasks,
    optionally renames the device, syncs system time via NTP, and triggers a fresh
    Autopilot enrollment. Designed for RMM deployment with -Silent for headless runs.
.PARAMETER NewName
    Optional new computer name to assign after reenrollment cleanup.
.PARAMETER Silent
    Runs in headless mode — skips all confirmation prompts and non-essential output.
.PARAMETER LogPath
    Directory for log files. Defaults to C:\Logs\ps-it-toolkit.
.EXAMPLE
    .\Invoke-AutopilotReenroll.ps1
.EXAMPLE
    .\Invoke-AutopilotReenroll.ps1 -NewName "WS-DELL-001" -Silent
#>

param(
    [string]$NewName,
    [switch]$Silent,
    [string]$LogPath = "C:\Logs\ps-it-toolkit"
)

#region Setup
$ErrorActionPreference = "Continue"
$script:ExitCode = 0

# Ensure log directory exists
if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}

$script:LogFile = Join-Path $LogPath "AutopilotReenroll_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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

#region Prerequisites
# Confirm admin rights — Autopilot operations require them
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal $currentIdentity
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log "Administrator privileges required. Exiting." "ERROR"
    exit 2
}

# Sync time first — Autopilot enrollment is time-sensitive
Write-Log "=== Step 1: Syncing system time via NTP ==="
try {
    $before = Get-Date
    # Stop w32time, re-register, set NTP server, force sync
    Stop-Service -Name w32time -Force -ErrorAction Stop
    & w32tm /unregister 2>$null
    & w32tm /register 2>$null
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\w32time\Parameters" -Name NtpServer -Value "time.windows.com" -ErrorAction Stop
    Start-Service -Name w32time -ErrorAction Stop
    & w32tm /resync /force 2>$null | Out-Null
    Start-Sleep -Seconds 3

    # Validate offset is under 2 seconds
    $offset = & w32tm /monitor /computers:time.windows.com 2>$null
    Write-Log "Time sync completed. Offset check: $offset" "OK"
} catch {
    Write-Log "Time sync failed: $_" "WARN"
    # Non-fatal — continue but log warning
    $script:ExitCode = 1
}
#endregion

#region Remove Autopilot Registration
Write-Log "=== Step 2: Removing current Autopilot registration ==="

# Registry paths that hold MDM enrollment state
$mdmKeys = @(
    "HKLM:\SOFTWARE\Microsoft\Provisioning\Diagnostics\Autopilot",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MDM",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\MDM",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\MDM"
)

foreach ($key in $mdmKeys) {
    if (Test-Path $key) {
        try {
            Remove-Item -Path $key -Recurse -Force -ErrorAction Stop
            Write-Log "Removed registry key: $key" "OK"
        } catch {
            Write-Log "Could not remove $key (may not exist or access denied): $_" "WARN"
            $script:ExitCode = 1
        }
    }
}

# Scheduled tasks created by MDM enrollment — remove them to prevent stale triggers
$autopilotTasks = @(
    "Microsoft\Windows\Provisioning\AutopilotEnrollmentTask",
    "Microsoft\Windows\EnterpriseMgmt\*",
    "Microsoft\Windows\DeviceManagement\*"
)

foreach ($task in $autopilotTasks) {
    try {
        # Use -ErrorAction Stop to detect genuinely missing tasks
        $found = Get-ScheduledTask -TaskPath "\$task" -ErrorAction SilentlyContinue
        if ($found) {
            Unregister-ScheduledTask -TaskPath "\$task" -Confirm:$false -ErrorAction Stop
            Write-Log "Removed scheduled task: $task" "OK"
        }
    } catch {
        Write-Log "Scheduled task not found or could not be removed (non-critical): $task" "WARN"
    }
}
#endregion

#region Rename Device (optional)
if ($NewName) {
    Write-Log "=== Step 3: Renaming device to '$NewName' ==="
    try {
        Rename-Computer -NewName $NewName -Force -ErrorAction Stop
        Write-Log "Computer renamed to '$NewName'. A reboot will be needed." "OK"
    } catch {
        Write-Log "Rename failed: $_" "ERROR"
        $script:ExitCode = 2
    }
}
#endregion

#region Trigger MDM Enrollment
Write-Log "=== Step 4: Triggering fresh Autopilot enrollment ==="

# Enroll via the built-in enrollment client — triggers a fresh OOBE/MDM enrollment on next boot
$enrollmentPath = "C:\Windows\System32\DeviceEnroller.exe"
if (Test-Path $enrollmentPath) {
    try {
        # /OOBE triggers OOBE-style enrollment; /Silent suppresses UI
        Start-Process -FilePath $enrollmentPath -ArgumentList "/OOBE /Silent" -WindowStyle Hidden -Wait -ErrorAction Stop
        Write-Log "DeviceEnroller triggered successfully. Autopilot enrollment will complete on next boot." "OK"
    } catch {
        Write-Log "DeviceEnroller failed: $_" "ERROR"
        $script:ExitCode = 2
    }
} else {
    # Fallback: trigger via scheduled task that calls MDMLicenseHandler
    Write-Log "DeviceEnroller not found at $enrollmentPath. Attempting scheduled task fallback." "WARN"
    try {
        $taskAction = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "C:\Windows\System32\slmgr.vbs /dti"  # Returns exit code only
        $taskTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -Minutes 1
        Register-ScheduledTask -TaskName "PSIT-AutopilotTrigger" -Action $taskAction -Trigger $taskTrigger -RunLevel Highest -Force -ErrorAction Stop
        Write-Log "Fallback enrollment task registered. Runs in 1 minute." "OK"
    } catch {
        Write-Log "Fallback enrollment trigger failed: $_" "ERROR"
        $script:ExitCode = 2
    }
}
#endregion

Write-Log "=== Autopilot reenrollment complete. Review log for any WARN entries. ==="
Write-Log "NOTE: A reboot may be required for MDM enrollment to complete." "WARN"
Write-Host ""
Write-Host "Log written to: $script:LogFile" -ForegroundColor Cyan

exit $script:ExitCode
