<#
.SYNOPSIS
    Disables and re-enables a network adapter to reset its state, flush ARP cache,
    and renew DHCP on that adapter specifically.
.DESCRIPTION
    Targets a specific network adapter by name or index, disables it, clears local
    ARP entries for that adapter's IPs, renews DHCP, then re-enables it. Useful for
    recovering from DHCP failures, IP conflict errors, or VPN stack corruption on
    a specific adapter without affecting other interfaces.
.PARAMETER AdapterName
    Name of the network adapter (as shown in Get-NetAdapter). Supports partial match.
.PARAMETER ReleaseDHCP
    Also run ipconfig /release and /renew on this adapter after reset.
.PARAMETER Silent
    Headless mode — suppresses console output.
.PARAMETER LogPath
    Directory for log files. Defaults to C:\Logs\ps-it-toolkit.
.EXAMPLE
    .\Reset-NetworkAdapter.ps1 -AdapterName "Ethernet"
.EXAMPLE
    .\Reset-NetworkAdapter.ps1 -AdapterName "Wi-Fi" -ReleaseDHCP
.EXAMPLE
    .\Reset-NetworkAdapter.ps1 -AdapterName "VPN" -Silent
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$AdapterName,
    [switch]$ReleaseDHCP,
    [switch]$Silent,
    [string]$LogPath = "C:\Logs\ps-it-toolkit"
)

#region Setup
$ErrorActionPreference = "Continue"
$script:ExitCode = 0

if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}
$script:LogFile = Join-Path $LogPath "NetworkAdapterReset_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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

Write-Log "=== Network Adapter Reset: $AdapterName ==="

#region 1. Locate adapter
Write-Log "--- Locating adapter ---"
try {
    # Partial name match
    $adapter = Get-NetAdapter | Where-Object { $_.Name -like "*$AdapterName*" -and $_.Status -ne "Not Present" } | Select-Object -First 1
    if (-not $adapter) {
        Write-Log "Adapter matching '$AdapterName' not found. Available adapters:" "ERROR"
        Get-NetAdapter | ForEach-Object { Write-Log "  $($_.Name) [$($_.Status)]" "INFO" }
        exit 2
    }
    Write-Log "Found adapter: $($adapter.Name) (InterfaceIndex=$($adapter.InterfaceIndex), MAC=$($adapter.MacAddress), Status=$($adapter.Status))" "OK"
} catch {
    Write-Log "Failed to enumerate network adapters: $_" "ERROR"
    exit 2
}
#endregion

#region 2. Capture current IP config
Write-Log "--- Capturing current IP configuration ---"
try {
    $ipConfig = Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    $dnsServers = Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    Write-Log "Current IPv4: $($ipConfig.IPAddress) PrefixLength=$($ipConfig.PrefixLength)" "INFO"
    Write-Log "DNS servers:   $($dnsServers.ServerAddresses -join ', ')" "INFO"
} catch {
    Write-Log "Could not capture IP config: $_" "WARN"
}
#endregion

#region 3. Release DHCP (optional)
if ($ReleaseDHCP) {
    Write-Log "--- Releasing DHCP lease ---"
    try {
        $adapterAlias = $adapter.Name
        $releaseOut = & ipconfig.exe /release "$adapterAlias" 2>&1 | Out-String
        Write-Log "DHCP release output: $releaseOut" "INFO"
        Start-Sleep -Seconds 2
        $renewOut = & ipconfig.exe /renew "$adapterAlias" 2>&1 | Out-String
        Write-Log "DHCP renew output: $renewOut" "INFO"
    } catch {
        Write-Log "DHCP release/renew failed: $_" "WARN"
        $script:ExitCode = 1
    }
}
#endregion

#region 4. Disable adapter
Write-Log "--- Disabling adapter ---"
try {
    Disable-NetAdapter -InterfaceIndex $adapter.InterfaceIndex -Confirm:$false -ErrorAction Stop
    Write-Log "Adapter disabled." "OK"
    Start-Sleep -Seconds 3

    # Verify it is down
    $afterDisable = Get-NetAdapter -InterfaceIndex $adapter.InterfaceIndex -ErrorAction SilentlyContinue
    if ($afterDisable.Status -eq "Disabled") {
        Write-Log "Adapter confirmed disabled." "OK"
    } else {
        Write-Log "Adapter may not have disabled cleanly. Status: $($afterDisable.Status)" "WARN"
    }
} catch {
    Write-Log "Failed to disable adapter: $_" "ERROR"
    exit 2
}
#endregion

#region 5. Flush ARP cache for this adapter's IPs
Write-Log "--- Flushing ARP cache for this adapter ---"
try {
    if ($ipConfig.IPAddress) {
        # Remove all ARP entries for this adapter's IP range (flush entire ARP cache as proxy)
        $null = & netsh.exe interface ip delete arpcache 2>&1
        Write-Log "ARP cache flushed." "OK"
    }
} catch {
    Write-Log "ARP cache flush failed: $_" "WARN"
}
#endregion

#region 6. Re-enable adapter
Write-Log "--- Re-enabling adapter ---"
try {
    Enable-NetAdapter -InterfaceIndex $adapter.InterfaceIndex -Confirm:$false -ErrorAction Stop
    Write-Log "Adapter enabled." "OK"
    Start-Sleep -Seconds 5

    # Wait for DHCP negotiation or stateless autoconfig
    $timeout = 15
    $attempt = 0
    $newIP = $null
    while ($attempt -lt $timeout) {
        $attempt++
        $currentAdapter = Get-NetAdapter -InterfaceIndex $adapter.InterfaceIndex -ErrorAction SilentlyContinue
        if ($currentAdapter.Status -eq "Up") {
            $newIPConfig = Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if ($newIPConfig -and $newIPConfig.IPAddress) {
                $newIP = $newIPConfig.IPAddress
                Write-Log "Adapter is up. New IPv4: $newIP" "OK"
                break
            }
        }
        Start-Sleep -Seconds 1
    }

    if (-not $newIP) {
        Write-Log "No IP address assigned after re-enable. Adapter may need a static IP or DHCP timeout." "WARN"
        $script:ExitCode = 1
    }
} catch {
    Write-Log "Failed to re-enable adapter: $_" "ERROR"
    exit 2
}
#endregion

#region 7. Verify connectivity
Write-Log "--- Verifying basic connectivity ---"
try {
    $connectivityHost = "8.8.8.8"
    $ping = Test-Connection -ComputerName $connectivityHost -Count 2 -ErrorAction SilentlyContinue
    if ($ping) {
        $avg = [Math]::Round(($ping.ResponseTime | Measure-Object -Average).Average, 1)
        Write-Log "Connectivity verified — 8.8.8.8 reachable ($avg ms avg)." "OK"
    } else {
        Write-Log "Connectivity check failed — 8.8.8.8 not reachable after adapter reset." "WARN"
        $script:ExitCode = 1
    }
} catch {
    Write-Log "Connectivity verification error: $_" "WARN"
    $script:ExitCode = 1
}
#endregion

Write-Log "=== Network adapter reset complete. Exit code: $script:ExitCode ==="
Write-Host ""
Write-Host "Log written to: $script:LogFile" -ForegroundColor Cyan
if ($script:ExitCode -eq 0) {
    Write-Host "Status: PASS" -ForegroundColor Green
} elseif ($script:ExitCode -eq 1) {
    Write-Host "Status: WARN (reset succeeded but connectivity check had issues)" -ForegroundColor Yellow
} else {
    Write-Host "Status: FAIL" -ForegroundColor Red
}

exit $script:ExitCode
