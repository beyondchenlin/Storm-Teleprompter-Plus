$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$iconPath = Join-Path $projectRoot 'assets\branding\BK-Teleprompter-source.png'
$configPath = Join-Path $projectRoot 'flutter_launcher_icons.yaml'

if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) {
  throw "Icon source not found: $iconPath"
}

Push-Location $projectRoot
try {
  dart --packages=.dart_tool/package_config.json tool/prepare_branding_asset.dart
  if ($LASTEXITCODE -ne 0) { throw 'Branding image preparation failed.' }
  dart run flutter_launcher_icons -f $configPath
  if ($LASTEXITCODE -ne 0) { throw 'Platform icon generation failed.' }
  dart --packages=.dart_tool/package_config.json tool/generate_windows_icon.dart
  if ($LASTEXITCODE -ne 0) { throw 'Windows multi-resolution icon generation failed.' }
  Write-Host 'Application icons generated for Android, iOS, Windows, and macOS.'
} finally {
  Pop-Location
}
