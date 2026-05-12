<#
.SYNOPSIS
    Runs Windows Update and Dell Command Update in parallel and logs all results.
.DESCRIPTION
    Uses the PSWindowsUpdate module to install Windows updates and the Dell Command
    Update CLI (dcu-cli.exe) to apply BIOS, firmware, and driver updates. Both
    operations run concurrently when possible. KB numbers and update status are
    logged for audit purposes.
.PARAMETER WindowsOnly
    Run only Windows Update, skip Dell Command Update.
.PARAMETER DellOnly
    Run only Dell Command Update, skip Windows Update.
.PARAMETER Silent
    Headless mode — suppresses per-update console chatter; summary still shown.
.PARAMETER LogPath
    Directory for log files. Defaults to C:\Logs\ps-it-toolkit.
.EXAMPLE
    .\Update-WindowsAndDell.ps1
.EXAMPLE
    .\Update-WindowsAndDell.ps1 -WindowsOnly -Silent
.EXAMPLE
    .\Update-WindowsAndDell.ps1 -DellOnly
#>

param(
    [switch]$WindowsOnly,
    [switch]$DellOnly,
    [switch]$Silent,
    [string]$LogPath = "C:\Logs\ps-it-toolkit"
)

#region Setup
$ErrorActionPreference = "Continue"
$script:ExitCode = 0

if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}

$script:LogFile = Join-Path $LogPath "WindowsAndDellUpdate_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$script:KBLogFile = Join-Path $LogPath "InstalledUpdates_$(Get-Date -Format 'yyyyMMdd').log"

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

#region Helper: Install-WindowsUpdate
function Install-WindowsUpdates {
    Write-Log "=== Windows Update ==="

    # Ensure PSWindowsUpdate module is available
    $module = Get-Module -Name PSWindowsUpdate -ListAvailable
    if (-not $module) {
        Write-Log "PSWindowsUpdate module not found. Installing from gallery..." "WARN"
        try {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction Stop | Out-Null
            Install-Module -Name PSWindowsUpdate -Force -Scope CurrentUser -ErrorAction Stop
            Import-Module PSWindowsUpdate -ErrorAction Stop
            Write-Log "PSWindowsUpdate module installed." "OK"
        } catch {
            Write-Log "Could not install PSWindowsUpdate: $_" "ERROR"
            $script:ExitCode = 2
            return
        }
    } else {
        Import-Module PSWindowsUpdate -ErrorAction SilentlyContinue
    }

    # Fetch available updates (suppress UI noise)
    try {
        Write-Log "Fetching available Windows updates..."
        $updates = Get-WindowsUpdate -ErrorAction Stop | Where-Object { $_.Title -match "KB[0-9]+" }

        if (-not $updates) {
            Write-Log "No Windows updates available." "OK"
            return
        }

        $kbList = $updates | ForEach-Object { $_.Title -replace ".*(KB[0-9]+).*", '$1' }
        Write-Log "Found $($updates.Count) update(s): $($kbList -join ', ')" "INFO"

        # Install all updates — -AcceptAll skips confirmation, -AutoReboot suppresses restart prompt
        # -Install -Silence here means suppress per-update output; summary still shown
        Install-WindowsUpdate -AcceptAll -AutoReboot:$false -Verbose:$false -ErrorAction Stop |
            ForEach-Object {
                $installedKB = $_.Title -replace ".*(KB[0-9]+).*", '$1'
                Write-Log "Installed Windows update: $($_.Title) [$installedKB]" "OK"
                "$([Get-Date]::ToString('yyyy-MM-dd HH:mm:ss'))|$installedKB|$($_.Title)|$($_.Status)" | 
                    Add-Content -Path $script:KBLogFile -Encoding UTF8
            }

        Write-Log "Windows Update complete." "OK"

    } catch {
        Write-Log "Windows Update failed: $_" "ERROR"
        $script:ExitCode = 2
    }
}
#endregion

#region Helper: Install-DellUpdates
function Install-DellUpdates {
    Write-Log "=== Dell Command Update ==="

    # dcu-cli.exe is the Dell Command Update CLI — install location varies
    $dcuPaths = @(
        "C:\Program Files\Dell\CommandUpdate\dcu-cli.exe",
        "${env:ProgramFiles}\Dell\CommandUpdate\dcu-cli.exe",
        "C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe"
    )
    $dcuExe = $dcuPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $dcuExe) {
        Write-Log "Dell Command Update CLI (dcu-cli.exe) not found. Skipping Dell updates." "WARN"
        $script:ExitCode = 1
        return
    }

    Write-Log "Found Dell Command Update at: $dcuExe"

    try {
        # -applyUpdates applies all available updates without prompting
        # -silent suppresses CLI output; -reboot=suppress prevents auto-reboot
        # Output is written to stderr or stdout depending on Dell firmware version — capture both
        $output = & $dcuExe /applyUpdates -silent -reboot=suppress 2>&1 | Out-String
        $exitCode = $LASTEXITCODE

        Write-Log "Dell Command Update output: $output" "INFO"
        Write-Log "Dell Command Update exit code: $exitCode" "INFO"

        if ($exitCode -eq 0) {
            Write-Log "Dell updates applied successfully." "OK"
        } elseif ($exitCode -eq 3010) {
            # 3010 = success but reboot required
            Write-Log "Dell updates applied; a reboot is required to complete." "WARN"
            $script:ExitCode = 1
        } else {
            Write-Log "Dell Command Update failed with exit code: $exitCode" "ERROR"
            $script:ExitCode = 2
        }
    } catch {
        Write-Log "Dell Command Update exception: $_" "ERROR"
        $script:ExitCode = 2
    }
}
#endregion

#region Main — Run in Parallel
Write-Log "=== Starting Update Run ==="
Write-Log "WindowsOnly=$WindowsOnly, DellOnly=$DellOnly"

$runWindows = -not $DellOnly
$runDell    = -not $WindowsOnly

# Run both concurrently using background jobs — avoids sequential wait when one is slow
$jobs = @()

if ($runWindows) {
    Write-Log "Queuing Windows Update task..."
    $jobs += Start-Job -Name "WindowsUpdate" -ScriptBlock {
        param($LogPath, $KBLogFile, $Silent)
        # Re-import module in job context
        Import-Module PSWindowsUpdate -ErrorAction SilentlyContinue
        $ErrorActionPreference = "Continue"
        $script:ExitCode = 0
        try {
            $updates = Get-WindowsUpdate | Where-Object { $_.Title -match "KB[0-9]+" }
            if (-not $updates) { 
                "NO_UPDATES" 
                return 
            }
            Install-WindowsUpdate -AcceptAll -AutoReboot:$false -ErrorAction Stop |
                ForEach-Object {
                    $kb = $_.Title -replace ".*(KB[0-9]+).*", '$1'
                    "$([Get-Date]::ToString('yyyy-MM-dd HH:mm:ss'))|$kb|$($_.Title)|$($_.Status)"
                }
        } catch { 
            "ERROR: $_" 
        }
    } -ArgumentList $LogPath, $script:KBLogFile, $Silent
}

if ($runDell) {
    Write-Log "Queuing Dell Update task..."
    $jobs += Start-Job -Name "DellUpdate" -ScriptBlock {
        param($LogPath)
        $ErrorActionPreference = "Continue"
        $dcuPaths = @(
            "C:\Program Files\Dell\CommandUpdate\dcu-cli.exe",
            "C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe"
        )
        $dcuExe = $dcuPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $dcuExe) { "DCU_NOT_FOUND"; return }
        try {
            $out = & $dcuExe /applyUpdates -silent -reboot=suppress 2>&1 | Out-String
            "DCU_OUTPUT:$out`nDCU_EXIT:$LASTEXITCODE"
        } catch { "ERROR: $_" }
    } -ArgumentList $LogPath
}

# Wait for both and stream results
if ($jobs) {
    Write-Log "Waiting for update jobs to complete..." "INFO"
    $jobs | ForEach-Object {
        $result = Receive-Job -Job $_ -Wait -AutoRemoveJob
        switch ($_.Name) {
            "WindowsUpdate" {
                $result | Where-Object { $_ -ne "NO_UPDATES" } | ForEach-Object {
                    $parts = $_ -split '\|'
                    if ($parts[0] -eq "ERROR") {
                        Write-Log "Windows Update error: $($parts[1])" "ERROR"
                        $script:ExitCode = 2
                    } elseif ($_ -ne "NO_UPDATES") {
                        Write-Log "Installed Windows update: $($parts[2]) [$($parts[1])]" "OK"
                        "$($parts[0])|$($parts[1])|$($parts[2])|$($parts[3])" |
                            Add-Content -Path $script:KBLogFile -Encoding UTF8
                    }
                }
                if ($result -eq "NO_UPDATES") {
                    Write-Log "No Windows updates available." "OK"
                }
            }
            "DellUpdate" {
                if ($result -eq "DCU_NOT_FOUND") {
                    Write-Log "Dell Command Update CLI not found. Skipped." "WARN"
                } else {
                    $result -split "`n" | Where-Object { $_ -match "DCU_" } | ForEach-Object {
                        if ($_ -match "DCU_OUTPUT:(.+)") { Write-Log "Dell output: $($matches[1].Trim())" "INFO" }
                        if ($_ -match "DCU_EXIT:(\d+)") { 
                            $ec = [int]$matches[1]
                            if ($ec -eq 0) { Write-Log "Dell updates applied successfully." "OK" }
                            elseif ($ec -eq 3010) { Write-Log "Dell updates applied; reboot required." "WARN"; $script:ExitCode = 1 }
                            else { Write-Log "Dell Command Update exit code: $ec" "ERROR"; $script:ExitCode = 2 }
                        }
                    }
                }
            }
        }
    }
}
#endregion

Write-Log "=== Update run complete. ==="
Write-Host ""
Write-Host "Primary log: $script:LogFile" -ForegroundColor Cyan
Write-Host "KB log:      $script:KBLogFile" -ForegroundColor Cyan
if ($script:ExitCode -eq 0) {
    Write-Host "Status: PASS" -ForegroundColor Green
} elseif ($script:ExitCode -eq 1) {
    Write-Host "Status: WARN (partial — reboot may be needed)" -ForegroundColor Yellow
} else {
    Write-Host "Status: FAIL" -ForegroundColor Red
}

exit $script:ExitCode
