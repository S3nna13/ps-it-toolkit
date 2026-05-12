<#
.SYNOPSIS
    Verifies the health and recent completion status of configured Windows backups.
.DESCRIPTION
    Checks Windows Server Backup, File History, and VSS (Volume Shadow Copy) writers.
    Reports backup age, last result code, next scheduled run, and any failed VSS writers.
    Exits 0 if all checks pass, 1 if warnings, 2 if failures.
.PARAMETER BackupPath
    Optional path to a legacy third-party backup destination to also check.
.PARAMETER Silent
    Headless mode — suppresses console output.
.PARAMETER LogPath
    Directory for log files. Defaults to C:\Logs\ps-it-toolkit.
.EXAMPLE
    .\Test-BackupStatus.ps1
.EXAMPLE
    .\Test-BackupStatus.ps1 -Silent
.EXAMPLE
    .\Test-BackupStatus.ps1 -BackupPath "\\nas\backups"
#>

param(
    [string]$BackupPath,
    [switch]$Silent,
    [string]$LogPath = "C:\Logs\ps-it-toolkit"
)

#region Setup
$ErrorActionPreference = "Continue"
$script:ExitCode = 0

if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}
$script:LogFile = Join-Path $LogPath "BackupStatus_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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

Write-Log "=== Backup Status Check starting ==="

#region 1. Windows Server Backup (WBAdmin)
Write-Log "--- Windows Server Backup check ---"
$wSBFailed = $false

try {
    # Get the most recent backup catalog
    $wbCatalog = Get-WBBackupCatalog -ErrorAction SilentlyContinue
    if ($wbCatalog) {
        $latestBackup = $wbCatalog | Sort-Object -Property LastBackup -Descending | Select-Object -First 1
        if ($latestBackup) {
            $ageDays = ((Get-Date) - $latestBackup.LastBackup).Days
            Write-Log "Last WSB backup: $($latestBackup.LastBackup) ($ageDays days ago)" "INFO"

            if ($ageDays -gt 3) {
                Write-Log "WSB backup is $ageDays days old (threshold: 3 days)." "ERROR"
                $script:ExitCode = 2
                $wSBFailed = $true
            } elseif ($ageDays -gt 1) {
                Write-Log "WSB backup is $ageDays days old (threshold: 1 day)." "WARN"
                if ($script:ExitCode -ne 2) { $script:ExitCode = 1 }
            } else {
                Write-Log "WSB backup is current (< 1 day old)." "OK"
            }
        }
    } else {
        Write-Log "No Windows Server Backup catalog found." "WARN"
        if ($script:ExitCode -ne 2) { $script:ExitCode = 1 }
    }
} catch {
    # WSB may not be installed on client SKUs — this is not a failure
    Write-Log "Windows Server Backup not available on this SKU: $_" "INFO"
}

# Get last backup result
try {
    $wbHistory = Get-WBJob -Previous 1 -ErrorAction SilentlyContinue
    if ($wbHistory) {
        Write-Log "Last WSB job: $($wbHistory.JobState) — ExitCode=$($wbHistory.HResult) StartTime=$($wbHistory.StartTime)" "INFO"
        if ($wbHistory.HResult -ne 0) {
            Write-Log "Last WSB job failed with HResult=$($wbHistory.HResult)." "ERROR"
            $script:ExitCode = 2
            $wSBFailed = $true
        }
    }
} catch { }
#endregion

#region 2. File History (Windows 8+)
Write-Log "--- File History check ---"
try {
    $fhConfig = Get-FileHistoryConfiguration -ErrorAction SilentlyContinue
    if ($fhConfig) {
        Write-Log "File History is configured. Last copy: $($fhConfig.LastCopiedFileTime)" "INFO"
        if ($fhConfig.LastCopiedFileTime) {
            $fhAge = ((Get-Date) - $fhConfig.LastCopiedFileTime).Days
            if ($fhAge -gt 2) {
                Write-Log "File History backup is $fhAge days old." "ERROR"
                if ($script:ExitCode -ne 2) { $script:ExitCode = 2 }
            }
        }
    } else {
        Write-Log "File History is not configured." "WARN"
        if ($script:ExitCode -eq 0) { $script:ExitCode = 1 }
    }
} catch {
    Write-Log "File History check failed: $_" "WARN"
}
#endregion

#region 3. VSS Writers (critical for backup integrity)
Write-Log "--- Volume Shadow Copy Service (VSS) writers ---"
$vssOutput = vssadmin list writers 2>&1 | Out-String
$script:VssFailed = $false

# Parse "Writer name:" blocks — look for state != 1 (Stable)
$writerBlocks = $vssOutput -split "(?=\[Writer\])" | Where-Object { $_ -match "Writer name:" }
foreach ($block in $writerBlocks) {
    if ($block -match "Writer name:\s+`"(.+?)`"\s+Writer Id:\s+\{(.+?)\}\s+Last error:\s+(.+?)\s+State:\s+(\d+)") {
        $name = $matches[1]
        $state = [int]$matches[4]
        $lastError = $matches[3].Trim()

        # State 1 = Stable [No Error]. State 5 = Waiting for completion. Others = problem.
        if ($state -ne 1 -and $state -ne 5) {
            Write-Log "VSS Writer '$name' is in state $state (last error: $lastError)" "ERROR"
            $script:VssFailed = $true
            $script:ExitCode = 2
        }
    }
}

if (-not $script:VssFailed) {
    Write-Log "All VSS writers are stable." "OK"
}
#endregion

#region 4. Third-party / custom backup path (if provided)
if ($BackupPath) {
    Write-Log "--- Custom backup path check: $BackupPath ---"
    if (Test-Path $BackupPath) {
        # Get the most recently modified item as proxy for backup recency
        $latestItem = Get-ChildItem -Path $BackupPath -Recurse -ErrorAction SilentlyContinue |
            Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
        if ($latestItem) {
            $ageDays = ((Get-Date) - $latestItem.LastWriteTime).Days
            Write-Log "Custom backup path — latest item: $($latestItem.FullName) ($ageDays days ago)" "INFO"
            if ($ageDays -gt 3) {
                Write-Log "Custom backup path has no recent backups ($ageDays days)." "ERROR"
                if ($script:ExitCode -ne 2) { $script:ExitCode = 2 }
            } elseif ($ageDays -gt 1) {
                Write-Log "Custom backup path is $ageDays days old." "WARN"
                if ($script:ExitCode -eq 0) { $script:ExitCode = 1 }
            } else {
                Write-Log "Custom backup path is current." "OK"
            }
        }
    } else {
        Write-Log "Custom backup path not accessible: $BackupPath" "ERROR"
        $script:ExitCode = 2
    }
}
#endregion

Write-Log "=== Backup status check complete. Exit code: $script:ExitCode ==="
Write-Host ""
Write-Host "Log written to: $script:LogFile" -ForegroundColor Cyan

if ($script:ExitCode -eq 0) {
    Write-Host "Status: PASS — All backup checks healthy" -ForegroundColor Green
} elseif ($script:ExitCode -eq 1) {
    Write-Host "Status: WARN — One or more backup checks returned warnings" -ForegroundColor Yellow
} else {
    Write-Host "Status: FAIL — One or more backup checks failed" -ForegroundColor Red
}

exit $script:ExitCode
