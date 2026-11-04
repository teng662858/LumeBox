[CmdletBinding()]
param([switch]$PrepareNative)
$ErrorActionPreference = 'Stop'
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
  & python tool/prepare_intro_models.py
  if ($LASTEXITCODE -ne 0) { throw 'Intro model asset preparation failed.' }
  & flutter analyze --no-pub --fatal-infos lib test
  if ($LASTEXITCODE -ne 0) { throw 'Static analysis failed; build blocked.' }
  if ($PrepareNative) {
    & pwsh -NoProfile -File third_party/quickjs_engine/tool/build_native.ps1
    if ($LASTEXITCODE -ne 0) { throw 'QuickJS test bridge build failed.' }
    $bridge = Get-ChildItem -LiteralPath third_party/quickjs_engine/native/build -Recurse -Filter quickjs_c_bridge_plugin.dll | Select-Object -First 1
    if (-not $bridge) { throw 'QuickJS bridge missing; native tests must not be silently skipped.' }
    $destination = 'build/windows/x64/runner/Release'
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    Copy-Item -LiteralPath $bridge.FullName -Destination "$destination/quickjs_c_bridge_plugin.dll" -Force
  }
  # Keep the native Rex/QuickJS hosts in a dedicated serial process batch.
  # Both batches are mandatory: no native coverage is skipped.
  & flutter test --no-pub --exclude-tags rex-native-serial --reporter expanded
  if ($LASTEXITCODE -ne 0) { throw 'Regression tests failed; build blocked.' }
  & flutter test --no-pub --tags rex-native-serial --concurrency=1 --reporter expanded
  if ($LASTEXITCODE -ne 0) { throw 'Native Rex regression tests failed; build blocked.' }
} finally {
  Pop-Location
}
