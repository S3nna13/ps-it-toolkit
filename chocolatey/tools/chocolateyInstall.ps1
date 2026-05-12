#Requires -Version 5.1
# This is the actual Chocolatey install script — Chocolatey executes this on package install.

$ErrorActionPreference = "Stop"

$toolsPath   = Split-Path -Parent $MyInvocation.MyCommand.Path
$packageRoot = Split-Path -Parent $toolsPath  # root of the package (where this dir lives)
$zipSource   = Join-Path $packageRoot "ps-it-toolkit.zip"

# Default install location
$defaultInstallDir = "C:\Program Files\ps-it-toolkit"
$installDir = if ($env:ChocolateyPackageFolder) { $env:ChocolateyPackageFolder } else { $defaultInstallDir }

Write-Host "Installing ps-it-toolkit to: $installDir"

# Ensure install directory exists
if (-not (Test-Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}

# If a zip was included in the package, extract it
if (Test-Path $zipSource) {
    Expand-Archive -Path $zipSource -DestinationPath $installDir -Force
    Write-Host "Extracted ps-it-toolkit.zip to $installDir"
} else {
    # Fallback: copy scripts dir directly if no zip available (e.g. direct git clone install)
    $srcScripts = Join-Path $packageRoot "scripts"
    $srcDocs    = Join-Path $packageRoot "docs"
    if (Test-Path $srcScripts) {
        Copy-Item -Path $srcScripts -Destination $installDir -Recurse -Force
    }
    if (Test-Path $srcDocs) {
        $destDocs = Join-Path $installDir "docs"
        Copy-Item -Path $srcDocs -Destination $destDocs -Recurse -Force
    }
}

# Add scripts to PATH for convenience (scoped to process — doesn't persist)
$scriptsPath = Join-Path $installDir "scripts"
$env:PATH = "$scriptsPath;$env:PATH"
$env:PS_IT_TOOLKIT_HOME = $installDir

Write-Host "ps-it-toolkit installed successfully."
Write-Host "Scripts: $scriptsPath"
Write-Host ""
Write-Host "Usage examples:"
Write-Host "  .\$scriptsPath\Invoke-WindowsRepair.ps1 -Silent"
Write-Host "  .\$scriptsPath\Invoke-NetworkDiag.ps1"
Write-Host ""
Write-Host "Run 'Get-Help .\$scriptsPath\<ScriptName>.ps1 -Full' for help."
