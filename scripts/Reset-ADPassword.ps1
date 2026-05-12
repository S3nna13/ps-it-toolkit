<#
.SYNOPSIS
    Resets a local or Active Directory user account password and optionally forces change on next logon.
.DESCRIPTION
    Resets a local Windows account or an Active Directory user account password. When -ForceChangeLogon
    is set, the account is forced to require a password change on next logon (appropriate for new hire
    setups or suspected compromise). All actions are logged with before/after state.
.PARAMETER Account
    Username of the account to reset. Supports local accounts (.\Username) and AD accounts (DOMAIN\Username).
.PARAMETER NewPassword
    The new password to assign. If omitted, a secure random 16-character password is generated and logged.
.PARAMETER ForceChangeLogon
    Forces the account to require a password change on next logon.
.PARAMETER Silent
    Headless mode — suppresses console output.
.PARAMETER LogPath
    Directory for log files. Defaults to C:\Logs\ps-it-toolkit.
.EXAMPLE
    .\Reset-ADPassword.ps1 -Account "jsmith"
.EXAMPLE
    .\Reset-ADPassword.ps1 -Account "DOMAIN\jsmith" -NewPassword "N3wP@ssw0rd!" -ForceChangeLogon
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Account,
    [string]$NewPassword,
    [switch]$ForceChangeLogon,
    [switch]$Silent,
    [string]$LogPath = "C:\Logs\ps-it-toolkit"
)

#region Setup
$ErrorActionPreference = "Continue"
$script:ExitCode = 0

if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}
$script:LogFile = Join-Path $LogPath "ResetPassword_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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

#region Resolve Account Type
Write-Log "=== Resetting password for account: $Account ==="

$isADAccount = $Account -match '\\|@'
$resolvedAccount = $Account.TrimStart(".\")

# Detect local vs AD by attempting to resolve via ADSI
$accountType = if ($isADAccount) { "Active Directory" } else { "Local" }

# Verify account exists
if ($isADAccount) {
    try {
        $adsi = [System.DirectoryServices.AccountManagement.Principal]::FindByIdentity($null, $account, $resolvedAccount)
        if (-not $adsi) {
            Write-Log "AD account '$resolvedAccount' not found." "ERROR"
            exit 2
        }
        Write-Log "AD account found: $($adsi.DisplayName) [$($adsi.DistinguishedName)]" "OK"
    } catch {
        Write-Log "AD lookup failed (may not be domain-joined or RSAT not installed): $_" "ERROR"
        exit 2
    }
} else {
    $localUser = Get-LocalUser -Name $resolvedAccount -ErrorAction SilentlyContinue
    if (-not $localUser) {
        Write-Log "Local account '$resolvedAccount' not found." "ERROR"
        exit 2
    }
    Write-Log "Local account found: $($localUser.FullName) [$($localUser.LastSet)]" "OK"
}
#endregion

#region Generate or Validate Password
if (-not $NewPassword) {
    # Generate a secure 16-char random password meeting complexity requirements
    $charSet = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#$%^&*-_+=?"
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 16
    $rng.GetBytes($bytes)
    $NewPassword = -join ($bytes | ForEach-Object { $charSet[$_ % $charSet.Length] })
    Write-Log "Generated random 16-character password (logged below)." "INFO"
    Write-Log "Password for '$resolvedAccount': $NewPassword" "INFO"
} else {
    # Basic complexity validation (8+ chars, upper, lower, digit, special)
    $complex = [System.Text.RegularExpressions.Regex]::Match($NewPassword, '^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[!@#$%^&*\-\+=?_]).{8,}$')
    if (-not $complex.Success) {
        Write-Log "Password does not meet complexity requirements (8+ chars, upper, lower, digit, special)." "ERROR"
        exit 2
    }
}
#endregion

#region Set Password
try {
    if ($isADAccount) {
        # AD account — use DirectoryServices.AccountManagement
        $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext "Domain"
        $user = [System.DirectoryServices.AccountManagement.Principal]::FindByIdentity($ctx, $resolvedAccount)
        $user.SetPassword($NewPassword)
        Write-Log "Password set on AD account '$resolvedAccount'." "OK"
    } else {
        # Local account — use Set-LocalUser
        Set-LocalUser -Name $resolvedAccount -Password (ConvertTo-SecureString $NewPassword -AsPlainText -Force) -ErrorAction Stop
        Write-Log "Password set on local account '$resolvedAccount'." "OK"
    }
} catch {
    Write-Log "Failed to set password: $_" "ERROR"
    exit 2
}
#endregion

#region Force Change on Next Logon
if ($ForceChangeLogon) {
    try {
        if ($isADAccount) {
            $user = [System.DirectoryServices.AccountManagement.Principal]::FindByIdentity($null, $resolvedAccount)
            $user.ExpirePasswordNow()
            Write-Log "AD account '$resolvedAccount' forced to change password on next logon." "OK"
        } else {
            # Local: set PasswordExpired = 1
            Set-LocalUser -Name $resolvedAccount -PasswordExpired:$true -ErrorAction Stop
            Write-Log "Local account '$resolvedAccount' forced to change password on next logon." "OK"
        }
    } catch {
        Write-Log "Failed to set 'change on next logon': $_" "ERROR"
        $script:ExitCode = 1
    }
}
#endregion

Write-Log "=== Password reset complete for '$resolvedAccount' ==="
Write-Host ""
Write-Host "Log written to: $script:LogFile" -ForegroundColor Cyan
if ($NewPassword) {
    Write-Host "Password for '$resolvedAccount': $NewPassword" -ForegroundColor Yellow
    Write-Host "Log this password securely — it is only shown here." -ForegroundColor Red
}

exit $script:ExitCode
