param(
  [string]$Version = '',
  [ValidateRange(-1, 65535)]
  [int]$BuildNumber = -1,
  [string]$PdfiumRuntimeDirectory = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$sourceCommit = Assert-BKCleanSource -ProjectRoot $projectRoot
$release = Resolve-BKVersion -ProjectRoot $projectRoot -Version $Version -BuildNumber $BuildNumber
$buildDirectory = Join-Path $projectRoot 'build\windows\x64\runner\Release'
$receiptPath = Join-Path $buildDirectory 'bk-build-receipt.json'
$started = [DateTime]::UtcNow.ToString('o')
$pdfiumTemporaryDirectory = $null
$pdfiumRuntimeSource = if ([string]::IsNullOrWhiteSpace($PdfiumRuntimeDirectory)) { $null } else { [IO.Path]::GetFullPath($PdfiumRuntimeDirectory) }
$originalPubHostedUrl = $env:PUB_HOSTED_URL
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'

Push-Location $projectRoot
try {
  if ($null -ne $pdfiumRuntimeSource) {
    # This cache layout belongs to the pinned 0.2.1 build hook; recheck it on upgrade.
    $lockfile = [IO.File]::ReadAllText((Join-Path $projectRoot 'pubspec.lock'))
    $pdfiumPackage = [regex]::Match($lockfile, '(?ms)^  pdfium_dart:\r?\n(?<entry>.*?)(?=^  \S|\z)')
    if (-not $pdfiumPackage.Success -or $pdfiumPackage.Groups['entry'].Value -cnotmatch '(?m)^    version: "0\.2\.1"\r?$') {
      throw 'Verified PDF runtime reuse requires the audited pdfium_dart 0.2.1 build hook.'
    }
    $verifiedPdfium = Assert-BKPdfiumRuntime -ProjectRoot $projectRoot -BuildDirectory $pdfiumRuntimeSource
    if ($verifiedPdfium.path -cne 'pdfium.dll' -or $verifiedPdfium.revision -cne 'chromium/7811') {
      throw 'Recheck the PDF runtime cache contract before changing the pinned revision.'
    }
    $temporaryCandidate = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('BKTeleprompter-pdfium-' + [guid]::NewGuid().ToString('N'))))
    $projectBoundary = [IO.Path]::GetFullPath($projectRoot).TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
    if ($temporaryCandidate.StartsWith($projectBoundary, [StringComparison]::OrdinalIgnoreCase)) {
      throw 'The PDF runtime temporary directory must be outside the source worktree.'
    }
    New-Item -ItemType Directory -Path $temporaryCandidate -ErrorAction Stop | Out-Null
    $pdfiumTemporaryDirectory = $temporaryCandidate
    Copy-Item -LiteralPath (Join-Path $pdfiumRuntimeSource $verifiedPdfium.path) -Destination (Join-Path $pdfiumTemporaryDirectory $verifiedPdfium.path)
    [void](Assert-BKPdfiumRuntime -ProjectRoot $projectRoot -BuildDirectory $pdfiumTemporaryDirectory)
  }
  & flutter clean
  if ($LASTEXITCODE -ne 0) { throw 'Flutter clean failed.' }
  & flutter pub get --enforce-lockfile
  if ($LASTEXITCODE -ne 0) { throw 'Flutter dependency resolution failed.' }
  if ($null -ne $pdfiumTemporaryDirectory) {
    $pdfiumCacheRoot = Join-Path $projectRoot '.dart_tool\hooks_runner\shared\pdfium_dart\build'
    $pdfiumCacheDirectory = Join-Path $pdfiumCacheRoot $verifiedPdfium.revision.Replace('/', '_')
    [IO.Directory]::CreateDirectory($pdfiumCacheDirectory) | Out-Null
    Copy-Item -LiteralPath (Join-Path $pdfiumTemporaryDirectory $verifiedPdfium.path) -Destination (Join-Path $pdfiumCacheDirectory $verifiedPdfium.path)
    [void](Assert-BKPdfiumRuntime -ProjectRoot $projectRoot -BuildDirectory $pdfiumCacheDirectory)
  }
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
  $pdfRuntime = Assert-BKPdfiumRuntime -ProjectRoot $projectRoot -BuildDirectory $buildDirectory
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
    pdfRuntime = $pdfRuntime
    files = $files
  }
  Write-BKJson -Path $receiptPath -Value $receipt
  [pscustomobject]@{product=$receipt.product; productVersion=$receipt.productVersion; sourceCommit=$sourceCommit; receipt=$receiptPath; runtimeFileCount=$files.Count} | ConvertTo-Json
} finally {
  $env:PUB_HOSTED_URL = $originalPubHostedUrl
  try {
    if ($null -ne $pdfiumTemporaryDirectory -and (Test-Path -LiteralPath $pdfiumTemporaryDirectory)) {
      Remove-Item -LiteralPath $pdfiumTemporaryDirectory -Recurse -Force
    }
  } finally {
    Pop-Location
  }
}
