param(
  [string]$Version = '',
  [ValidateRange(-1, 65535)]
  [int]$BuildNumber = -1
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$sourceCommit = Assert-BKCleanSource -ProjectRoot $projectRoot
$release = Resolve-BKVersion -ProjectRoot $projectRoot -Version $Version -BuildNumber $BuildNumber
$buildDirectory = Join-Path $projectRoot 'build\windows\x64\runner\Release'
$receiptPath = Join-Path $buildDirectory 'bk-build-receipt.json'
$started = [DateTime]::UtcNow.ToString('o')
$originalPubHostedUrl = $env:PUB_HOSTED_URL
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'

Push-Location $projectRoot
try {
  & flutter clean
  if ($LASTEXITCODE -ne 0) { throw 'Flutter clean failed.' }
  & flutter pub get --enforce-lockfile
  if ($LASTEXITCODE -ne 0) { throw 'Flutter dependency resolution failed.' }
  if ((Assert-BKCleanSource -ProjectRoot $projectRoot) -cne $sourceCommit) { throw 'The source changed before compilation.' }
  $arguments = @(
    'build', 'windows', '--release', '--no-pub',
    "--build-name=$($release.version)",
    "--build-number=$($release.buildNumber)",
    "--dart-define=APP_VERSION=$($release.version)",
    "--dart-define=APP_SOURCE_COMMIT=$sourceCommit"
  )
  & flutter @arguments
  if ($LASTEXITCODE -ne 0) { throw 'Flutter Windows release build failed.' }
  $runtime = Copy-BKVisualCRuntime -BuildDirectory $buildDirectory
  Assert-BKExecutableBranding -Path (Join-Path $buildDirectory 'BK 提词器.exe') -Release $release
  $files = @(Get-BKFileManifest -Directory $buildDirectory -RuntimeOnly)
  if ((Assert-BKCleanSource -ProjectRoot $projectRoot) -cne $sourceCommit) { throw 'The source changed during compilation; no receipt was issued.' }
  $flutterVersion = (& flutter --version --machine | Out-String).Trim() | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0) { throw 'Cannot record the Flutter SDK version.' }
  $receipt = [ordered]@{
    schemaVersion = 1
    product = 'BK 提词器'
    version = $release.version
    buildNumber = $release.buildNumber
    productVersion = $release.productVersion
    sourceCommit = $sourceCommit
    startedUtc = $started
    completedUtc = [DateTime]::UtcNow.ToString('o')
    flutter = $flutterVersion
    visualCRuntime = $runtime
    files = $files
  }
  Write-BKJson -Path $receiptPath -Value $receipt
  [pscustomobject]@{product=$receipt.product; productVersion=$receipt.productVersion; sourceCommit=$sourceCommit; receipt=$receiptPath; runtimeFileCount=$files.Count} | ConvertTo-Json
} finally {
  $env:PUB_HOSTED_URL = $originalPubHostedUrl
  Pop-Location
}
