$ErrorActionPreference = "Stop"

# Remove PATH entry (best-effort)
if ($env:PS_IT_TOOLKIT_HOME) {
    $scriptsPath = Join-Path $env:PS_IT_TOOLKIT_HOME "scripts"
    $env:PATH = ($env:PATH -split ';' | Where-Object { $_ -ne $scriptsPath }) -join ';'
    $env:PS_IT_TOOLKIT_HOME = $null
}
