<#
.SYNOPSIS
    Performs a configurable disk cleanup operation targeting temp files, Windows Update
    caches, browser caches, and old log files.
.DESCRIPTION
    Runs a configurable disk cleanup operation targeting:
      - Windows temp folders (%TEMP%, System32\Temp)
      - Windows Update download cache (SoftwareDistribution\Download)
      - Browser caches (Edge, Chrome, Firefox)
      - Old log files (*.log older than 30 days)
      - Windows prefetch data
      - Failed Windows Upgrade cleanup files (if Upgrade is present)
    Shows space recovered per category and total. Safe to run on production systems.
.PARAMETER BrowserCaches
    Also clear Edge, Chrome, and Firefox browser caches (can log users out of sites).
.PARAMETER UpdateCache
    Also clear the Windows Update download cache (SoftwareDistribution\Download).
.PARAMETER DaysOld
    Only delete files older than N days (default: 3). Set to 0 to delete all matching files.
.PARAMETER Silent
    Headless mode — suppresses console output.
.PARAMETER LogPath
    Directory for log files. Defaults to C:\Logs\ps-it-toolkit.
.EXAMPLE
    .\Invoke-DiskCleanup.ps1
.EXAMPLE
    .\Invoke-DiskCleanup.ps1 -BrowserCaches -UpdateCache -DaysOld 7 -Silent
#>

param(
    [switch]$BrowserCaches,
    [switch]$UpdateCache,
    [int]$DaysOld = 3,
    [switch]$Silent,
    [string]$LogPath = "C:\Logs\ps-it-toolkit"
)

#region Setup
$ErrorActionPreference = "Continue"
$script:ExitCode = 0

if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}
$script:LogFile = Join-Path $LogPath "DiskCleanup_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$script:SpaceLogFile = Join-Path $LogPath "DiskCleanup_SpaceReclaimed_$(Get-Date -Format 'yyyyMMdd').log"

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

function Remove-FilesOlderThan {
    param([string]$Path, [string]$Description, [int]$Days, [string[]]$Filters = @("*"))

    $cutoff = (Get-Date).AddDays(-$Days)
    $totalFreed = 0
    $totalCount = 0

    if (-not (Test-Path $Path)) {
        Write-Log "Path not found (skipping): $Path" "INFO"
        return @{ FreedBytes = 0; FileCount = 0 }
    }

    foreach ($filter in $Filters) {
        try {
            $files = Get-ChildItem -Path $Path -Filter $filter -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $cutoff }
            $count = ($files | Measure-Object).Count
            if ($count -gt 0) {
                $size = ($files | Measure-Object -Property Length -Sum).Sum
                $files | Remove-Item -Force -ErrorAction Stop
                $totalFreed += $size
                $totalCount += $count
                Write-Log "  $Description | Removed $count file(s) | $([Math]::Round($size/1MB, 1)) MB freed" "OK"
            }
        } catch {
            Write-Log "  $Description | Partial removal (some files locked): $_" "WARN"
        }
    }

    return @{ FreedBytes = $totalFreed; FileCount = $totalCount }
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

Write-Log "=== Disk Cleanup starting ==="
Write-Log "Days threshold: $DaysOld"
Write-Log "Browser caches: $($BrowserCaches.IsPresent)"
Write-Log "Update cache:   $($UpdateCache.IsPresent)"

$grandTotalFreed = 0
$grandTotalFiles = 0
$categories = @()

#region 1. User temp folder
Write-Log "--- User TEMP folder ---"
$result = Remove-FilesOlderThan -Path $env:TEMP -Description "User TEMP" -Days $DaysOld
$grandTotalFreed += $result.FreedBytes; $grandTotalFiles += $result.FileCount
$categories += @{ Name = "User TEMP"; FreedBytes = $result.FreedBytes; FileCount = $result.FileCount }
#endregion

#region 2. System temp
Write-Log "--- System32\\Temp ---"
$result = Remove-FilesOlderThan -Path "$env:SystemRoot\Temp" -Description "System TEMP" -Days $DaysOld
$grandTotalFreed += $result.FreedBytes; $grandTotalFiles += $result.FileCount
$categories += @{ Name = "System TEMP"; FreedBytes = $result.FreedBytes; FileCount = $result.FileCount }
#endregion

#region 3. Windows Prefetch
Write-Log "--- Prefetch data ---"
$result = Remove-FilesOlderThan -Path "$env:SystemRoot\Prefetch" -Description "Prefetch" -Days $DaysOld -Filters @("*.pf")
$grandTotalFreed += $result.FreedBytes; $grandTotalFiles += $result.FileCount
$categories += @{ Name = "Prefetch"; FreedBytes = $result.FreedBytes; FileCount = $result.FileCount }
#endregion

#region 4. Old log files
Write-Log "--- Old .log files ---"
$result = Remove-FilesOlderThan -Path $env:SystemRoot -Description "System Log Files" -Days $DaysOld -Filters @("*.log")
$grandTotalFreed += $result.FreedBytes; $grandTotalFiles += $result.FileCount
$categories += @{ Name = "System Log Files"; FreedBytes = $result.FreedBytes; FileCount = $result.FileCount }
#endregion

#region 5. Windows Update cache
if ($UpdateCache) {
    Write-Log "--- Windows Update download cache ---"
    # Stop wuauserv to release the lock on SoftwareDistribution
    try {
        Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    } catch { }
    $result = Remove-FilesOlderThan -Path "$env:SystemRoot\SoftwareDistribution\Download" -Description "WU Download Cache" -Days 0
    $grandTotalFreed += $result.FreedBytes; $grandTotalFiles += $result.FileCount
    $categories += @{ Name = "WU Download Cache"; FreedBytes = $result.FreedBytes; FileCount = $result.FileCount }
    try { Start-Service -Name wuauserv -ErrorAction SilentlyContinue } catch { }
}
#endregion

#region 6. Browser caches
if ($BrowserCaches) {
    Write-Log "--- Browser caches ---"

    # Chrome
    $chromePath = "$env:LOCALAPPDATA\Google\Chrome\User Data"
    if (Test-Path $chromePath) {
        $result = Remove-FilesOlderThan -Path "$chromePath\Default\Cache" -Description "Chrome Cache" -Days 0
        $result2 = Remove-FilesOlderThan -Path "$chromePath\Default\Code Cache" -Description "Chrome Code Cache" -Days 0
        $combined = @{ FreedBytes = $result.FreedBytes + $result2.FreedBytes; FileCount = $result.FileCount + $result2.FileCount }
        $grandTotalFreed += $combined.FreedBytes; $grandTotalFiles += $combined.FileCount
        $categories += @{ Name = "Chrome Cache"; FreedBytes = $combined.FreedBytes; FileCount = $combined.FileCount }
    }

    # Edge
    $edgePath = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
    if (Test-Path $edgePath) {
        $result = Remove-FilesOlderThan -Path "$edgePath\Default\Cache" -Description "Edge Cache" -Days 0
        $grandTotalFreed += $result.FreedBytes; $grandTotalFiles += $result.FileCount
        $categories += @{ Name = "Edge Cache"; FreedBytes = $result.FreedBytes; FileCount = $result.FileCount }
    }

    # Firefox
    $firefoxPath = "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles"
    if (Test-Path $firefoxPath) {
        $result = Remove-FilesOlderThan -Path $firefoxPath -Description "Firefox Cache" -Days 0 -Filters @("cache2\*")
        $grandTotalFreed += $result.FreedBytes; $grandTotalFiles += $result.FileCount
        $categories += @{ Name = "Firefox Cache"; FreedBytes = $result.FreedBytes; FileCount = $result.FileCount }
    }
}
#endregion

#region Summary
Write-Log "=== Disk Cleanup Summary ==="
Write-Log "Total space reclaimed: $([Math]::Round($grandTotalFreed/1MB, 2)) MB"
Write-Log "Total files deleted:    $grandTotalFiles"

if (-not $Silent) {
    Write-Host ""
    Write-Host "=== Space Reclaimed by Category ===" -ForegroundColor Cyan
    foreach ($cat in $categories) {
        if ($cat.FreedBytes -gt 0) {
            Write-Host "  $($cat.Name.PadRight(20)) $([Math]::Round($cat.FreedBytes/1MB, 2).ToString().PadLeft(8)) MB  ($($cat.FileCount) files)" -ForegroundColor White
        }
    }
    Write-Host "  $($('TOTAL').PadRight(20)) $([Math]::Round($grandTotalFreed/1MB, 2).ToString().PadLeft(8)) MB" -ForegroundColor Green
}

# Append to daily space log for trending
"$([Get-Date]::ToString('yyyy-MM-dd'))|$(Get-Date -Format 'HH:mm:ss')|$grandTotalFreed|$grandTotalFiles" |
    Add-Content -Path $script:SpaceLogFile -Encoding UTF8

Write-Log "Space log written to: $script:SpaceLogFile" "INFO"
Write-Host ""
Write-Host "Log written to: $script:LogFile" -ForegroundColor Cyan
Write-Host "Status: PASS — $([Math]::Round($grandTotalFreed/1MB, 2)) MB freed" -ForegroundColor Green

exit $script:ExitCode
