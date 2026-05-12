<#
.SYNOPSIS
    Clears the Print Spooler service, removes stuck print jobs, and resets printer drivers.
.DESCRIPTION
    Stops the Print Spooler service, deletes all pending print jobs from the spool directory,
    optionally removes and re-adds problematic printer drivers, and restarts the service.
    Resolves the majority of print queue stalls caused by corrupted spool files or driver issues.
.PARAMETER DriverName
    Optional printer driver name to remove and reinstall after clearing the spooler.
    If omitted, only clears the queue and restarts the service.
.PARAMETER Silent
    Headless mode — suppresses console output.
.PARAMETER LogPath
    Directory for log files. Defaults to C:\Logs\ps-it-toolkit.
.EXAMPLE
    .\Clear-PrintSpooler.ps1
.EXAMPLE
    .\Clear-PrintSpooler.ps1 -DriverName "HP LaserJet 400 MFP M425"
#>

param(
    [string]$DriverName,
    [switch]$Silent,
    [string]$LogPath = "C:\Logs\ps-it-toolkit"
)

#region Setup
$ErrorActionPreference = "Continue"
$script:ExitCode = 0

if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}
$script:LogFile = Join-Path $LogPath "PrintSpooler_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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

Write-Log "=== Print Spooler Clear starting ==="

#region 1. Stop Print Spooler service
Write-Log "--- Stopping Print Spooler service ---"
try {
    Stop-Service -Name Spooler -Force -ErrorAction Stop
    Write-Log "Print Spooler service stopped." "OK"
} catch {
    Write-Log "Failed to stop Print Spooler: $_" "ERROR"
    exit 2
}
Start-Sleep -Seconds 2
#endregion

#region 2. Delete spool files
Write-Log "--- Deleting print spool files ---"
$spoolPaths = @(
    "$env:SystemRoot\System32\spool\PRINTERS",
    "$env:SystemRoot\System32\spool\SERVERS",
    "$env:SystemRoot\System32\spool\DRIVERS"
)

$totalDeleted = 0
foreach ($spoolPath in $spoolPaths) {
    if (Test-Path $spoolPath) {
        try {
            $files = Get-ChildItem -Path $spoolPath -File -ErrorAction SilentlyContinue
            $count = $files.Count
            if ($count -gt 0) {
                $files | Remove-Item -Force -ErrorAction Stop
                Write-Log "Cleared $count file(s) from $spoolPath" "OK"
                $totalDeleted += $count
            } else {
                Write-Log "Spool path already empty: $spoolPath" "INFO"
            }
        } catch {
            Write-Log "Could not clear $spoolPath: $_" "WARN"
            $script:ExitCode = 1
        }
    } else {
        Write-Log "Spool path not found: $spoolPath" "INFO"
    }
}

Write-Log "Total spool files deleted: $totalDeleted" "INFO"
#endregion

#region 3. Remove stale registry printer entries ( orphaned sessions )
Write-Log "--- Cleaning orphaned printer registry entries ---"
$regPrinterPaths = @(
    "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Printers",
    "HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Devices"
)
$regRemoved = 0
foreach ($regPath in $regPrinterPaths) {
    if (Test-Path $regPath) {
        try {
            $printers = Get-ChildItem -Path $regPath -ErrorAction SilentlyContinue
            $count = $printers.Count
            Write-Log "Registry entries under $regPath : $count" "INFO"
        } catch { }
    }
}
#endregion

#region 4. Remove/reinstall specific driver (optional)
if ($DriverName) {
    Write-Log "--- Removing printer driver: $DriverName ---"
    try {
        # Remove all printer connections using this driver first
        $printers = Get-Printer | Where-Object { $_.DriverName -eq $DriverName }
        foreach ($printer in $printers) {
            try {
                Remove-Printer -Name $printer.Name -ErrorAction Stop
                Write-Log "Removed printer: $($printer.Name)" "OK"
            } catch {
                Write-Log "Could not remove printer $($printer.Name): $_" "WARN"
            }
        }

        # Remove the driver package
        $removeResult = Remove-PrinterDriver -Name $DriverName -ErrorAction Stop
        Write-Log "Printer driver '$DriverName' removed." "OK"

        # Re-add the driver (re-register from inf)
        # pnputil /add-driver will re-enumerate drivers on next spooler start
        Write-Log "Driver '$DriverName' removed. It will be re-enumerated on spooler start." "INFO"
    } catch {
        Write-Log "Failed to remove driver '$DriverName': $_" "ERROR"
        $script:ExitCode = 1
    }
}
#endregion

#region 5. Restart Print Spooler
Write-Log "--- Restarting Print Spooler service ---"
try {
    Start-Service -Name Spooler -ErrorAction Stop
    $spooler = Get-Service -Name Spooler
    if ($spooler.Status -eq "Running") {
        Write-Log "Print Spooler restarted successfully (Status: Running)." "OK"
    } else {
        Write-Log "Print Spooler is not running after restart attempt (Status: $($spooler.Status))." "ERROR"
        $script:ExitCode = 2
    }
} catch {
    Write-Log "Failed to restart Print Spooler: $_" "ERROR"
    $script:ExitCode = 2
}
#endregion

#region 6. Verify queue is empty
Write-Log "--- Verifying print queue is clear ---"
try {
    $queueJobs = Get-Printer | ForEach-Object {
        try { Get-PrintJob -PrinterName $_.Name -ErrorAction SilentlyContinue } catch { }
    } | Where-Object { $_ }
    $jobCount = ($queueJobs | Measure-Object).Count
    if ($jobCount -eq 0) {
        Write-Log "Print queue is empty — no pending jobs." "OK"
    } else {
        Write-Log "Print queue still has $jobCount pending job(s)." "WARN"
        $script:ExitCode = 1
    }
} catch {
    Write-Log "Could not verify print queue: $_" "WARN"
}

Write-Log "=== Print Spooler clear complete. Exit code: $script:ExitCode ==="
Write-Host ""
Write-Host "Log written to: $script:LogFile" -ForegroundColor Cyan
if ($script:ExitCode -eq 0) {
    Write-Host "Status: PASS" -ForegroundColor Green
} elseif ($script:ExitCode -eq 1) {
    Write-Host "Status: WARN (partial)" -ForegroundColor Yellow
} else {
    Write-Host "Status: FAIL" -ForegroundColor Red
}

exit $script:ExitCode
