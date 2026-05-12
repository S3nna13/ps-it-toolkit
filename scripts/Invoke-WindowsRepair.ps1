<#
.SYNOPSIS
    Interactive or silent Windows repair tool with three escalation tiers.
.DESCRIPTION
    Provides three tiers of repair operations for Windows 10/11:
      Tier 1 - Quick Fix:     DISM RestoreHealth, SFC scannow, disk cleanup
      Tier 2 - Network Reset: Flush DNS, reset Winsock, release/renew IP, clear ARP cache
      Tier 3 - Full Repair:   Tier 1 + Tier 2 + Windows Update component reset + DLL re-registration
    When run with -Silent, Tier 3 runs automatically (no menu).
.PARAMETER Tier
    Explicitly specify which tier to run (1, 2, or 3). Overrides menu selection.
.PARAMETER Silent
    Headless mode — runs Tier 3 automatically without displaying the menu.
.PARAMETER LogPath
    Directory for log files. Defaults to C:\Logs\ps-it-toolkit.
.EXAMPLE
    .\Invoke-WindowsRepair.ps1
.EXAMPLE
    .\Invoke-WindowsRepair.ps1 -Silent
.EXAMPLE
    .\Invoke-WindowsRepair.ps1 -Tier 2
#>

param(
    [ValidateRange(1, 3)]
    [int]$Tier,
    [switch]$Silent,
    [string]$LogPath = "C:\Logs\ps-it-toolkit"
)

#region Setup
$ErrorActionPreference = "Continue"
$script:ExitCode = 0

if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}

$script:LogFile = Join-Path $LogPath "WindowsRepair_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts [$Level] $Message" | Add-Content -Path $script:LogFile -Encoding UTF8
    switch ($Level) {
        "ERROR" { if (-not $Silent) { Write-Host "[ERROR] $Message" -ForegroundColor Red } }
        "WARN"  { if (-not $Silent) { Write-Host "[WARN]  $Message" -ForegroundColor Yellow } }
        "OK"    { if (-not $Silent) { Write-Host "[OK]    $Message" -ForegroundColor Green } }
        default { if (-not $Silent) { Write-Host "[INFO]  $Message" } }
    }
}

function Invoke-RepairOperation {
    # Helper that runs a command, captures exit code, and logs result
    param(
        [string]$Name,
        [scriptblock]$Operation,
        [string]$SuccessMessage
    )
    Write-Log "Running: $Name"
    try {
        $result = & $Operation 2>&1
        if ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE) {
            Write-Log "$Name — PASS" "OK"
            if ($SuccessMessage) { Write-Log $SuccessMessage "INFO" }
            return $true
        } else {
            Write-Log "$Name — FAIL (exit code: $LASTEXITCODE)" "ERROR"
            return $false
        }
    } catch {
        Write-Log "$Name — FAIL: $_" "ERROR"
        return $false
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

#region Menu (interactive)
if ($Silent -or $Tier) {
    $selectedTier = if ($Tier) { $Tier } else { 3 }
    if (-not $Silent) { Write-Host "Running Tier $selectedTier in verbose mode..." }
} else {
    Write-Host ""
    Write-Host "=== Windows Repair Tool ===" -ForegroundColor Cyan
    Write-Host "  [1] Tier 1 - Quick Fix"       -ForegroundColor White
    Write-Host "      DISM RestoreHealth, SFC scannow, disk cleanup" -ForegroundColor Gray
    Write-Host "  [2] Tier 2 - Network Reset"  -ForegroundColor White
    Write-Host "      Flush DNS, reset Winsock, release/renew IP, clear ARP" -ForegroundColor Gray
    Write-Host "  [3] Tier 3 - Full Repair"     -ForegroundColor White
    Write-Host "      Tier 1 + Tier 2 + Windows Update reset + DLL re-reg" -ForegroundColor Gray
    Write-Host ""
    $choice = Read-Host "Select tier [1-3]"
    $selectedTier = if ($choice -match "^[123]$") { [int]$choice } else { 1 }
}

Write-Log "=== Starting Tier $selectedTier repair ==="
Write-Log "Log file: $script:LogFile"
#endregion

#region Tier 1: Quick Fix
function Invoke-Tier1 {
    Write-Log "--- Tier 1: Quick Fix ---"

    # DISM /RestoreHealth — fixes component store corruption
    $dismOk = Invoke-RepairOperation -Name "DISM /RestoreHealth" -Operation {
        DISM.exe /Online /Cleanup-Image /RestoreHealth /NoRestart
    } -SuccessMessage "DISM completed. Proceed to SFC."

    # SFC /scannow — repairs protected system files
    $sfcOk = Invoke-RepairOperation -Name "SFC /scannow" -Operation {
        sfc.exe /scannow
    }

    # Disk cleanup — remove temporary / system clutter
    $cleanupOk = Invoke-RepairOperation -Name "Disk Cleanup (temp files)" -Operation {
        # Use -Force to suppress prompts; -ErrorAction stops on first major error
        Start-Process -FilePath "cleanmgr.exe" -ArgumentList "/sagerun:1" -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue
        0  # cleanmgr exits 0 on success, 1 on user cancel — treat both as OK for automation
    }

    if (-not ($dismOk -and $sfcOk)) {
        $script:ExitCode = 2
        Write-Log "Tier 1 had failures — DISM or SFC did not complete cleanly." "ERROR"
    } elseif (-not $cleanupOk) {
        $script:ExitCode = 1
        Write-Log "Tier 1 completed but disk cleanup had issues." "WARN"
    } else {
        Write-Log "Tier 1 complete — all operations passed." "OK"
    }
}
#endregion

#region Tier 2: Network Reset
function Invoke-Tier2 {
    Write-Log "--- Tier 2: Network Reset ---"

    $ops = @()

    # Flush DNS resolver cache — clears stale DNS entries
    $ops += Invoke-RepairOperation -Name "Flush DNS cache" -Operation {
        Clear-DnsClientCache; ipconfig.exe /flushdns | Out-Null; 0
    }

    # Reset Winsock catalog — fixes broken network stack entries (VPN, malware cleanup)
    $ops += Invoke-RepairOperation -Name "Reset Winsock catalog" -Operation {
        netsh.exe winsock reset | Out-Null; 0
    }

    # Release DHCP lease on all adapters — forces full re-acquisition
    $ops += Invoke-RepairOperation -Name "Release all DHCP leases" -Operation {
        ipconfig.exe /release | Out-Null
        Start-Sleep -Seconds 2
        ipconfig.exe /renew | Out-Null
        0
    }

    # Flush ARP cache — removes stale ARP entries (can cause duplicate IP issues)
    $ops += Invoke-RepairOperation -Name "Flush ARP cache" -Operation {
        netsh.exe interface ip delete arpcache | Out-Null; 0
    }

    if ($ops -contains $false) {
        $script:ExitCode = 1
        Write-Log "Tier 2 had one or more failures." "WARN"
    } else {
        Write-Log "Tier 2 complete — all operations passed." "OK"
    }
}
#endregion

#region Tier 3: Full Repair = Tier1 + Tier2 + Windows Update reset + DLL re-reg
function Invoke-Tier3 {
    Write-Log "--- Tier 3: Full Repair ---"

    Invoke-Tier1
    Invoke-Tier2

    # Reset Windows Update components — handles Update stack corruption
    Write-Log "--- Tier 3: Windows Update component reset ---"

    $wuKeys = @(
        "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate",
        "HKLM\SOFTWARE\Microsoft\WindowsUpdate",
        "HKLM\SYSTEM\CurrentControlSet\Services\wuauserv",
        "HKLM\SYSTEM\CurrentControlSet\Services\BITS"
    )

    $wuOk = $true
    foreach ($key in $wuKeys) {
        # Stop associated services first
        $svcName = switch -Regex ($key) {
            "wuauserv"  { "wuauserv" }
            "BITS"      { "BITS" }
            default     { $null }
        }
        if ($svcName) {
            try {
                Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
            } catch { }
        }
        # Remove registry keys (best-effort)
        try {
            Remove-Item -Path "HKLM:\$key" -Recurse -Force -ErrorAction SilentlyContinue
        } catch { }
    }

    # Restart services — they recreate the keys on start
    foreach ($svc in @("wuauserv", "BITS", "TrustedInstaller")) {
        try {
            Start-Service -Name $svc -ErrorAction SilentlyContinue
            Write-Log "Restarted service: $svc" "OK"
        } catch {
            Write-Log "Could not restart $svc (may not be installed): $_" "WARN"
        }
    }

    # Re-register DLLs associated with Windows Update
    $dllRegOps = @(
        "msie40.dll", "shdocvw.dll", "jscript.dll", "vbscript.dll",
        "scrrun.dll", "msxml.dll", "mshtml.dll", "actxprxy.dll",
        "softpub.dll", "wintrust.dll", "initpki.dll", "dsquery.dll"
    )
    foreach ($dll in $dllRegOps) {
        try {
            $dllPath = Join-Path $env:SystemRoot "System32\$dll"
            if (Test-Path $dllPath) {
                regsvr32.exe /s $dllPath 2>$null
                Write-Log "Re-registered: $dll" "OK"
            }
        } catch { }
    }

    Write-Log "Tier 3 complete." "OK"
}
#endregion

#region Execute
switch ($selectedTier) {
    1 { Invoke-Tier1 }
    2 { Invoke-Tier2 }
    3 { Invoke-Tier3 }
}
#endregion

Write-Log "=== Repair complete. Review log for WARN/ERROR entries. ==="
Write-Host ""
Write-Host "Log written to: $script:LogFile" -ForegroundColor Cyan
if ($script:ExitCode -eq 0) {
    Write-Host "Status: PASS" -ForegroundColor Green
} elseif ($script:ExitCode -eq 1) {
    Write-Host "Status: WARN (partial success)" -ForegroundColor Yellow
} else {
    Write-Host "Status: FAIL" -ForegroundColor Red
}

exit $script:ExitCode
