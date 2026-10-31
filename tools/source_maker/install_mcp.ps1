param([string]$Destination = (Join-Path $env:LOCALAPPDATA 'LumeBox/SourceMaker/mcp'))
$ErrorActionPreference = 'Stop'
if (-not (Get-Command node -ErrorAction SilentlyContinue) -or -not (Get-Command npm -ErrorAction SilentlyContinue)) {
    throw 'Please install Node.js 18 or later, then run this setup again.'
}
npm install --prefix $Destination --no-audit --no-fund '@playwright/mcp@0.0.83'
if ($LASTEXITCODE -ne 0) { throw 'Playwright MCP installation failed' }
Write-Host "Ready: $Destination"
