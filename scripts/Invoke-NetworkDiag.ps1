<#
.SYNOPSIS
    Runs a comprehensive network diagnostics suite and outputs a structured report.
.DESCRIPTION
    Runs a battery of network connectivity, DNS, latency, and configuration checks.
    In -Silent mode, outputs a machine-parseable JSON report; otherwise displays
    a color-coded summary table. Useful for triaging connectivity issues before
    escalating to tier-2.
.PARAMETER Silent
    Headless mode — outputs JSON report to log instead of colorized console table.
.PARAMETER LogPath
    Directory for log files. Defaults to C:\Logs\ps-it-toolkit.
.EXAMPLE
    .\Invoke-NetworkDiag.ps1
.EXAMPLE
    .\Invoke-NetworkDiag.ps1 -Silent
#>

param(
    [switch]$Silent,
    [string]$LogPath = "C:\Logs\ps-it-toolkit"
)

#region Setup
$ErrorActionPreference = "Continue"
$script:ExitCode = 0

if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}
$script:LogFile = Join-Path $LogPath "NetworkDiag_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$script:ReportFile = Join-Path $LogPath "NetworkDiag_Report_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"

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

#region Helper: Test-Port
function Test-Port {
    param([string]$HostName, [int]$Port, [int]$TimeoutMs = 2000)
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $tcp = New-Object System.Net.Sockets.TcpClient
        $connect = $tcp.BeginConnect($HostName, $Port, $null, $null)
        $wait = $connect.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        $sw.Stop()
        if ($wait -and $tcp.Connected) {
            $tcp.Close()
            return @{ Host = $HostName; Port = $Port; Status = "OPEN"; LatencyMs = $sw.ElapsedMilliseconds }
        } else {
            $tcp.Close()
            return @{ Host = $HostName; Port = $Port; Status = "TIMEOUT"; LatencyMs = $null }
        }
    } catch {
        return @{ Host = $HostName; Port = $Port; Status = "ERROR"; LatencyMs = $null }
    }
}
#endregion

Write-Log "=== Network Diagnostics starting ==="

$results = @()

#region 1. Basic Connectivity — ICMP ping
Write-Log "--- Ping tests ---"
$pingTargets = @("8.8.8.8", "1.1.1.1", "time.windows.com")
foreach ($target in $pingTargets) {
    try {
        $ping = Test-Connection -ComputerName $target -Count 2 -ErrorAction SilentlyContinue
        if ($ping) {
            $avg = [Math]::Round(($ping.ResponseTime | Measure-Object -Average).Average, 1)
            $results += @{ Test = "Ping $target"; Result = "PASS"; Detail = "$avg ms avg" }
            Write-Log "Ping $target — PASS ($avg ms)" "OK"
        } else {
            $results += @{ Test = "Ping $target"; Result = "FAIL"; Detail = "No response" }
            Write-Log "Ping $target — FAIL" "ERROR"
        }
    } catch {
        $results += @{ Test = "Ping $target"; Result = "FAIL"; Detail = $_.Exception.Message }
        Write-Log "Ping $target — FAIL: $_" "ERROR"
    }
}
#endregion

#region 2. DNS Resolution
Write-Log "--- DNS resolution tests ---"
$dnsTests = @(
    @{ Hostname = "microsoft.com";        Expected = "20.112.25.93" },
    @{ Hostname = "google.com";          Expected = "142.250.80.46" },
    @{ Hostname = "github.com";          Expected = "140.82.112.4" },
    @{ Hostname = "azure.microsoft.com"; Expected = $null }
)
foreach ($test in $dnsTests) {
    try {
        $resolved = [System.Net.Dns]::GetHostAddresses($test.Hostname)[0].ToString()
        if ($test.Expected -and $resolved -eq $test.Expected) {
            $results += @{ Test = "DNS $($test.Hostname)"; Result = "PASS"; Detail = $resolved }
            Write-Log "DNS $($test.Hostname) — PASS ($resolved)" "OK"
        } elseif ($resolved) {
            $results += @{ Test = "DNS $($test.Hostname)"; Result = "PASS"; Detail = $resolved }
            Write-Log "DNS $($test.Hostname) — PASS ($resolved)" "OK"
        } else {
            $results += @{ Test = "DNS $($test.Hostname)"; Result = "FAIL"; Detail = "No A record" }
            Write-Log "DNS $($test.Hostname) — FAIL" "ERROR"
        }
    } catch {
        $results += @{ Test = "DNS $($test.Hostname)"; Result = "FAIL"; Detail = $_.Exception.Message }
        Write-Log "DNS $($test.Hostname) — FAIL: $_" "ERROR"
    }
}
#endregion

#region 3. DNS Resolver Cache
Write-Log "--- DNS resolver cache check ---"
try {
    $before = (Get-DnsClientCache | Measure-Object).Count
    $null = [System.Net.Dns]::GetHostAddresses("www.microsoft.com")
    $after = (Get-DnsClientCache | Measure-Object).Count
    $results += @{ Test = "DNS Cache"; Result = "PASS"; Detail = "Entries before=$before after=$after" }
    Write-Log "DNS cache — PASS (before=$before, after=$after)" "OK"
} catch {
    $results += @{ Test = "DNS Cache"; Result = "WARN"; Detail = $_.Exception.Message }
    Write-Log "DNS cache — WARN: $_" "WARN"
}
#endregion

#region 4. TCP Port Connectivity
Write-Log "--- TCP port checks ---"
$portTests = @(
    @{ Host = "8.8.8.8";       Port = 53;   Name = "Google DNS" },
    @{ Host = "1.1.1.1";        Port = 53;   Name = "Cloudflare DNS" },
    @{ Host = "outlook.office365.com"; Port = 443; Name = "Microsoft 365" },
    @{ Host = "github.com";     Port = 443;  Name = "GitHub" },
    @{ Host = "www.microsoft.com"; Port = 443; Name = "Microsoft CDN" }
)
foreach ($t in $portTests) {
    $r = Test-Port -HostName $t.Host -Port $t.Port
    $status = if ($r.Status -eq "OPEN") { "PASS" } elseif ($r.Status -eq "TIMEOUT") { "WARN" } else { "FAIL" }
    $detail = if ($r.LatencyMs) { "$($r.Status) $($r.LatencyMs)ms" } else { $r.Status }
    $results += @{ Test = "TCP $($t.Name) $($t.Host):$($t.Port)"; Result = $status; Detail = $detail }
    if ($status -eq "PASS") { Write-Log "TCP $($t.Host):$($t.Port) — PASS ($($r.LatencyMs)ms)" "OK" }
    elseif ($status -eq "WARN") { Write-Log "TCP $($t.Host):$($t.Port) — TIMEOUT" "WARN"; $script:ExitCode = 1 }
    else { Write-Log "TCP $($t.Host):$($t.Port) — FAIL" "ERROR"; $script:ExitCode = 1 }
}
#endregion

#region 5. Current IP Configuration
Write-Log "--- IP configuration snapshot ---"
try {
    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | ForEach-Object {
        $ip = Get-NetIPAddress -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $dns = Get-DnsClientServerAddress -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        @{
            Name       = $_.Name
            MacAddress = $_.MacAddress
            LinkSpeed  = $_.LinkSpeed
            IPv4       = if ($ip) { $ip.IPAddress } else { "N/A" }
            DNS        = if ($dns) { $dns.ServerAddresses -join ", " } else { "N/A" }
        }
    }
    foreach ($a in $adapters) {
        Write-Log "Adapter: $($a.Name) | MAC: $($a.MacAddress) | Speed: $($a.LinkSpeed) | IPv4: $($a.IPv4) | DNS: $($a.DNS)" "INFO"
        $results += @{ Test = "Adapter $($a.Name)"; Result = "INFO"; Detail = "IPv4=$($a.IPv4) DNS=$($a.DNS)" }
    }
} catch {
    Write-Log "Failed to retrieve IP configuration: $_" "ERROR"
}
#endregion

#region 6. Default Gateway
Write-Log "--- Default gateway check ---"
try {
    $gw = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gw) {
        $pingGw = Test-Connection -ComputerName $gw.NextHop -Count 2 -ErrorAction SilentlyContinue
        if ($pingGw) {
            $results += @{ Test = "Default Gateway $($gw.NextHop)"; Result = "PASS"; Detail = "Reachable" }
            Write-Log "Default gateway $($gw.NextHop) — PASS" "OK"
        } else {
            $results += @{ Test = "Default Gateway $($gw.NextHop)"; Result = "FAIL"; Detail = "Unreachable" }
            Write-Log "Default gateway $($gw.NextHop) — FAIL (no ping response)" "ERROR"
            $script:ExitCode = 1
        }
    } else {
        $results += @{ Test = "Default Gateway"; Result = "FAIL"; Detail = "No default route found" }
        Write-Log "Default gateway — FAIL: no default route" "ERROR"
        $script:ExitCode = 1
    }
} catch {
    Write-Log "Gateway check failed: $_" "ERROR"
}
#endregion

#region 7. Winsock Catalog
Write-Log "--- Winsock catalog check ---"
try {
    $winsock = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services\Winsock2\Parameters" -ErrorAction SilentlyContinue
    if ($winsock) {
        $results += @{ Test = "Winsock Catalog"; Result = "PASS"; Detail = "Catalog present" }
        Write-Log "Winsock catalog — PASS" "OK"
    } else {
        $results += @{ Test = "Winsock Catalog"; Result = "WARN"; Detail = "Catalog not found" }
        Write-Log "Winsock catalog — WARN" "WARN"
    }
} catch {
    $results += @{ Test = "Winsock Catalog"; Result = "WARN"; Detail = $_.Exception.Message }
    Write-Log "Winsock catalog — WARN: $_" "WARN"
}
#endregion

#region Output
$report = @{
    Timestamp   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Hostname    = $env:COMPUTERNAME
    Domain      = $env:USERDOMAIN
    ExitCode    = $script:ExitCode
    Results     = $results
}

if ($Silent) {
    $report | ConvertTo-Json -Depth 5 | Add-Content -Path $script:ReportFile -Encoding UTF8
    Write-Log "JSON report written to: $script:ReportFile" "INFO"
} else {
    Write-Host ""
    Write-Host "=== Network Diagnostic Summary ===" -ForegroundColor Cyan
    Write-Host ""
    $passCount = ($results | Where-Object { $_.Result -eq "PASS" }).Count
    $failCount = ($results | Where-Object { $_.Result -eq "FAIL" }).Count
    $warnCount = ($results | Where-Object { $_.Result -eq "WARN" }).Count
    Write-Host "PASS: $passCount   WARN: $warnCount   FAIL: $failCount" -ForegroundColor $(if ($failCount -eq 0) { "Green" } else { "Yellow" })
    Write-Host ""
    $results | ForEach-Object {
        $color = switch ($_.Result) { "PASS" { "Green" } "WARN" { "Yellow" } "FAIL" { "Red" } default { "White" } }
        Write-Host "  [$($_.Result.PadRight(4))] $($_.Test)" -ForegroundColor $color
        Write-Host "           $($_.Detail)" -ForegroundColor Gray
    }
}

Write-Log "=== Network diagnostics complete ==="
Write-Host ""
Write-Host "Log written to: $script:LogFile" -ForegroundColor Cyan

exit $script:ExitCode
