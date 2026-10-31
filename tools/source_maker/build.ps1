param([string]$Name = 'LumeBox-SourceMaker-0.8.2')
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    python -m pip install -r requirements.txt
    if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed' }
    python -m unittest discover -s tests -v
    if ($LASTEXITCODE -ne 0) { throw 'Tests failed; build stopped' }
    $runtimeAsset = Join-Path $PSScriptRoot 'runtime.js'
    $pythonAsset = Join-Path $PSScriptRoot 'python_runtime.py'
    $catAsset = Join-Path $PSScriptRoot 'cat_runtime.cjs'
    $htmlAsset = Join-Path $PSScriptRoot 'html_rules.js'
    $actionsAsset = Join-Path $PSScriptRoot 'page_actions.js'
    $apiAsset = Join-Path $PSScriptRoot 'api_runtime.js'
    $yeguoAsset = Join-Path $PSScriptRoot 'yeguo_runtime.js'
    $dramaAsset = Join-Path $PSScriptRoot 'drama_runtime.js'
    $gazeAsset = Join-Path $PSScriptRoot 'gaze_runtime.js'
    $structuredAsset = Join-Path $PSScriptRoot 'structured_rules.js'
    python -m PyInstaller --noconfirm --clean --onefile --windowed --name $Name --collect-data certifi --collect-all webview --collect-all playwright --collect-all patchright --collect-all browserforge --collect-all apify_fingerprint_datapoints --collect-all curl_cffi --collect-all selenium --collect-all scrapy --collect-all scrapling --collect-all tld --recursive-copy-metadata scrapling --recursive-copy-metadata scrapy --copy-metadata lxml --hidden-import webview.platforms.edgechromium --add-data "$runtimeAsset;." --add-data "$pythonAsset;." --add-data "$catAsset;." --add-data "$htmlAsset;." --add-data "$actionsAsset;." --add-data "$apiAsset;." --add-data "$dramaAsset;." --add-data "$yeguoAsset;." --add-data "$structuredAsset;." --add-data "$gazeAsset;." --distpath '../../build/source-maker' --workpath '../../build/source-maker-work' --specpath '../../build/source-maker-work' app.py
    if ($LASTEXITCODE -ne 0) { throw 'Packaging failed' }
    Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.md' | Where-Object { $_.Name -notin @('AGENTS.md', 'RESUME.md') } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination ../../build/source-maker/ -Force
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'install_mcp.ps1') -Destination ../../build/source-maker/ -Force
    if ($Name -ne 'LumeBox-SourceMaker') {
        Copy-Item -LiteralPath "../../build/source-maker/$Name.exe" -Destination ../../build/source-maker/LumeBox-SourceMaker.exe -Force
    }
    Write-Host "Ready: build/source-maker/$Name.exe"
} finally {
    Pop-Location
}
