<#
.SYNOPSIS
    Clears cached authentication tokens and optionally Outlook profiles for Microsoft 365.
.DESCRIPTION
    Kills running Office processes, removes ADAL/MSAL token caches from the local app data
    folder, strips cached credentials from Windows Credential Manager (Office 15 and 16
    entries), and optionally resets the Outlook profile. Designed for token fatigue issues
    where sign-in loops or stale cached creds block access.
.PARAMETER ResetProfile
    Also removes Outlook profile registry keys under HKCU (forces a fresh profile setup on next launch).
.PARAMETER NoRestart
    Suppresses the automatic restart of Outlook after token clearing.
.PARAMETER Silent
    Headless mode — suppresses console output.
.PARAMETER LogPath
    Directory for log files. Defaults to C:\Logs\ps-it-toolkit.
.EXAMPLE
    .\Clear-Office365Tokens.ps1
.EXAMPLE
    .\Clear-Office365Tokens.ps1 -ResetProfile -NoRestart
.EXAMPLE
    .\Clear-Office365Tokens.ps1 -Silent -LogPath "D:\Logs\IT"
#>

param(
    [switch]$ResetProfile,
    [switch]$NoRestart,
    [switch]$Silent,
    [string]$LogPath = "C:\Logs\ps-it-toolkit"
)

#region Setup
$ErrorActionPreference = "Continue"
$script:ExitCode = 0

if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}

$script:LogFile = Join-Path $LogPath "O365Tokens_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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

#region Kill Office Processes
Write-Log "=== Step 1: Stopping Office processes ==="

$officeProcesses = @("OUTLOOK", "Teams", "OneDrive", "excel", "winword", "powerpnt", "msproject", "visio")
$failedProcesses = @()

foreach ($proc in $officeProcesses) {
    $found = Get-Process -Name $proc -ErrorAction SilentlyContinue
    if ($found) {
        try {
            Stop-Process -Name $proc -Force -ErrorAction Stop
            Write-Log "Stopped process: $proc" "OK"
        } catch {
            Write-Log "Could not stop $proc: $_" "WARN"
            $failedProcesses += $proc
        }
    }
}

# Brief pause to let handles close
Start-Sleep -Seconds 2
#endregion

#region Clear ADAL and MSAL Token Caches
Write-Log "=== Step 2: Clearing ADAL/MSAL token caches ==="

$adalPaths = @(
    # ADAL (Office 2013-2016)
    "$env:LOCALAPPDATA\Microsoft\ADAL",
    "$env:LOCALAPPDATA\Microsoft\Office\16.0\Common\Identity",
    # MSAL (Office 2019+/Microsoft 365)
    "$env:LOCALAPPDATA\Microsoft\IdentityStore",
    "$env:LOCALAPPDATA\Microsoft\MSAL",
    "$env:LOCALAPPDATA\Microsoft\Office\16.0\MSAL"
)

foreach ($path in $adalPaths) {
    if (Test-Path $path) {
        try {
            Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
            Write-Log "Removed token cache: $path" "OK"
        } catch {
            Write-Log "Could not remove $path: $_" "WARN"
            $script:ExitCode = 1
        }
    } else {
        Write-Log "Token cache not found (skipping): $path" "INFO"
    }
}
#endregion

#region Windows Credential Manager — Office Entries
Write-Log "=== Step 3: Removing cached credentials from Windows Credential Manager ==="

# Use cmdkey to list and remove Office credentials without parsing raw output
function Remove-Credential {
    param([string]$Target)
    try {
        $output = cmdkey.exe /list:MicrosoftOffice* 2>&1 | Out-String
        if ($output -match [regex]::Escape($Target)) {
            cmdkey.exe /delete:$Target 2>$null
            Write-Log "Removed credential: $Target" "OK"
        }
    } catch { }
}

# Credential Manager target names vary by Office version — target the most common patterns
$credTargets = @(
    "MicrosoftOffice16_Data:adalsql",
    "MicrosoftOffice16_Data:identitycrl",
    "MicrosoftOffice15_Data:adalsql",
    "MicrosoftOffice15_Data:identitycrl",
    "MicrosoftOfficeLM"
)

foreach ($target in $credTargets) {
    try {
        # cmdkey /delete returns exit code 1 if target doesn't exist — suppress
        $null = cmdkey.exe /delete:$target 2>$null
        Write-Log "Processed credential: $target" "OK"
    } catch {
        Write-Log "Credential not found or access denied: $target" "WARN"
    }
}
#endregion

#region Outlook Profile Reset (optional)
if ($ResetProfile) {
    Write-Log "=== Step 4: Removing Outlook profile registry keys ==="

    $profileKeys = @(
        "HKCU:\SOFTWARE\Microsoft\Office\16.0\Outlook\Profiles",
        "HKCU:\SOFTWARE\Microsoft\Office\15.0\Outlook\Profiles",
        "HKCU:\SOFTWARE\Microsoft\Office\14.0\Outlook\Profiles"
    )

    foreach ($key in $profileKeys) {
        if (Test-Path $key) {
            try {
                Remove-Item -Path $key -Recurse -Force -ErrorAction Stop
                Write-Log "Removed Outlook profile registry: $key" "OK"
            } catch {
                Write-Log "Could not remove $key: $_" "WARN"
                $script:ExitCode = 1
            }
        }
    }
}
#endregion

#region Restart Outlook
if (-not $NoRestart) {
    Write-Log "=== Step 5: Restarting Outlook ==="
    try {
        Start-Process -FilePath "outlook.exe" -WindowStyle Normal -ErrorAction SilentlyContinue
        Write-Log "Outlook restarted." "OK"
    } catch {
        Write-Log "Outlook restart failed (may not be installed): $_" "WARN"
        $script:ExitCode = 1
    }
} else {
    Write-Log "Outlook restart suppressed (NoRestart flag set)." "INFO"
}
#endregion

Write-Log "=== Token clear complete. ==="
Write-Host ""
Write-Host "Log written to: $script:LogFile" -ForegroundColor Cyan
if ($failedProcesses.Count -gt 0) {
    Write-Host "Note: Some processes may still be running. Review log." -ForegroundColor Yellow
}

exit $script:ExitCode
