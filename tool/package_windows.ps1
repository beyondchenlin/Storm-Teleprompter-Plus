param(
  [string]$Version = '',
  [ValidateRange(-1, 65535)]
  [int]$BuildNumber = -1,

  [Parameter(Mandatory = $true)]
  [string]$OutputDirectory,

  # Parent directory containing the verified zipformer2-ced model folder.
  [Parameter(Mandatory = $true)]
  [string]$ModelDirectory,

  [string]$CompilerPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows\common.ps1')
$projectRoot = Split-Path -Parent $PSScriptRoot
$sourceCommit = Assert-BKCleanSource -ProjectRoot $projectRoot
$release = Resolve-BKVersion -ProjectRoot $projectRoot -Version $Version -BuildNumber $BuildNumber
$buildDirectory = Join-Path $projectRoot 'build\windows\x64\runner\Release'
$executable = Join-Path $buildDirectory 'BK 提词器.exe'
Assert-BKExecutableBranding -Path $executable -Release $release
[void](Assert-BKPdfiumRuntime -ProjectRoot $projectRoot -BuildDirectory $buildDirectory)

$receiptPath = Join-Path $buildDirectory 'bk-build-receipt.json'
if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
  throw 'A verified build receipt is required. Build with tool/windows/build_release.ps1 first.'
}
$receipt = [IO.File]::ReadAllText($receiptPath) | ConvertFrom-Json
if ($receipt.schemaVersion -ne 1 -or $receipt.sourceCommit -cne $sourceCommit -or
    $receipt.productVersion -cne $release.productVersion) {
  throw 'The build receipt does not match this source commit and version; rebuild first.'
}
$runtimeFiles = @(Get-BKFileManifest -Directory $buildDirectory -RuntimeOnly)
Assert-BKFileManifest -Actual $runtimeFiles -Expected @($receipt.files)
foreach ($name in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
  $path = Join-Path $buildDirectory $name
  Assert-BKOfficialSignature -Path $path -Publisher 'Microsoft Corporation'
  Assert-BKPeX64 -Path $path
}

foreach ($relative in @('lib\favicon.png', 'assets\asr\zipformer2-ced.manifest.json')) {
  $source = Join-Path $projectRoot $relative
  $bundled = Join-Path $buildDirectory (Join-Path 'data\flutter_assets' $relative)
  if ((Get-FileHash -LiteralPath $source).Hash -cne (Get-FileHash -LiteralPath $bundled).Hash) {
    throw "Bundled asset differs from the source: $relative"
  }
}
$model = Read-BKModelManifest -ProjectRoot $projectRoot
$modelSource = Join-Path ([IO.Path]::GetFullPath($ModelDirectory)) $model.modelId
foreach ($entry in $model.files) { Assert-BKModelFile -Path (Join-Path $modelSource $entry.name) -Entry $entry }
$compiler = Find-BKInnoCompiler -ExplicitPath $CompilerPath
if ($null -eq $compiler) { throw 'An official Inno Setup compiler is required. Run tool/windows/ensure_inno.ps1 first.' }

$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$packageName = "BK 提词器-$($release.version)-windows-x64"
$installerName = "$packageName-setup.exe"
$releaseManifestName = "$packageName-release.json"
$installer = Join-Path $outputRoot $installerName
$checksumFile = "$installer.sha256"
$releaseManifestPath = Join-Path $outputRoot $releaseManifestName
foreach ($path in @($installer, $checksumFile, $releaseManifestPath)) {
  if (Test-Path -LiteralPath $path) { throw 'The requested release already exists; choose a new output directory.' }
}
[IO.Directory]::CreateDirectory($outputRoot) | Out-Null
$workRoot = Join-Path $outputRoot ('.installer-' + [guid]::NewGuid().ToString('N'))
$stage = Join-Path $workRoot 'payload'
$compileOutput = Join-Path $workRoot 'output'
[IO.Directory]::CreateDirectory($stage) | Out-Null
[IO.Directory]::CreateDirectory($compileOutput) | Out-Null
$publishedPaths = [Collections.Generic.List[string]]::new()
try {
  # Copy only the exact files recorded by the clean build, never a user's app_data.
  foreach ($entry in $runtimeFiles) {
    $source = Join-Path $buildDirectory $entry.path
    $destination = Join-Path $stage $entry.path
    [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination
  }
  Copy-Item -LiteralPath (Join-Path $projectRoot 'LICENSE') -Destination $stage
  Copy-Item -LiteralPath $receiptPath -Destination $stage
  $notices = Join-Path $stage 'third_party'
  [IO.Directory]::CreateDirectory($notices) | Out-Null
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'windows\THIRD_PARTY_NOTICES.txt') -Destination $notices
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'windows\vendor\InnoSetup-LICENSE.txt') -Destination $notices
  foreach ($name in @('Apache-2.0.txt', 'ChineseModel-README.md', 'ChineseModel-SOURCE.txt', 'model-license-source.json')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('windows\vendor\' + $name)) -Destination $notices
  }
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'windows\vendor\pdfium') -Destination (Join-Path $notices 'pdfium') -Recurse
  Copy-Item -LiteralPath (Join-Path $projectRoot 'docs\pdf-import-notices.md') -Destination $notices
  $modelDestination = Join-Path $stage ('bundled_models\' + $model.modelId)
  [IO.Directory]::CreateDirectory($modelDestination) | Out-Null
  foreach ($entry in $model.files) {
    $destination = Join-Path $modelDestination $entry.name
    Copy-Item -LiteralPath (Join-Path $modelSource $entry.name) -Destination $destination
    Assert-BKModelFile -Path $destination -Entry $entry
  }
  $modelManifestPath = Join-Path $projectRoot 'assets\asr\zipformer2-ced.manifest.json'
  Copy-Item -LiteralPath $modelManifestPath -Destination (Join-Path $modelDestination 'model-manifest.json')
  [IO.File]::WriteAllText((Join-Path $stage 'bk-installed.json'), '{"schemaVersion":1,"mode":"installed"}', [Text.UTF8Encoding]::new($false))
  $instructions = @"
BK 提词器 $($release.version)

创作者：陈林
联系邮箱：beyond.chenlin@gmail.com
本产品定制部分版权：Copyright (c) 2026 陈林

1. 支持微软系统 10 的 1903 版及以上，以及微软系统 11 的 64 位环境。
2. 双击安装程序，为当前用户安装，无需管理员权限。通过桌面或开始菜单中的“BK 提词器”打开软件。
3. 安装包已包含“中文语音模型（内置）”。首次使用时，软件会校验并自动准备模型；模型损坏时可从语音设置修复。
4. 默认程序目录：%LOCALAPPDATA%\Programs\BKTeleprompter。
5. 稿件、设置和用户模型保存在：%LOCALAPPDATA%\BKTeleprompter\app_data。请在文件管理器地址栏输入此路径查看。
6. 升级前保存稿件并退出软件，然后运行新版安装程序。升级会沿用安装位置并保留用户数据。
7. 在系统“应用和功能”中卸载，或从开始菜单运行卸载程序。卸载会保留稿件、设置及用户模型；本安装器不会清除它们。
8. 旧便携版的 app_data（应用数据）仍保留在原位置。不要将安装目录选为旧版数据目录，也不要直接删除旧目录；按产品迁移说明备份后迁移。
9. 朗读批注：在编辑器中选中原文字词，点击“添加批注”，填写重读、停顿或语气提示；输入时可在下方实时预览，保存后可点击预览中的字词框继续修改。
10. 文档批注导入：支持 .docx（文字文档格式）和 .pdf（便携式文档格式）中的批注。没有明确字词选区的备注会保留为“待定位”；在正文中选中字词，再进入“批注管理”绑定。
11. 提词页面点击“批注：开／关”显示或隐藏提示。长备注只缩略显示，全文保留；点击备注文字，或长按、右键点击原文字词框，可以查看全文。
12. 编辑页和提词页的调色板按钮可调整“批注外观”：独立字体、自动或 8–36 像素首选字号、常用及自定义颜色，预览后点击“应用”。空间不足会自动缩小并提示实际字号，正文位置不变；应用设置里另有批注默认外观。

本分发包不含个人稿件、设置或运行日志。
开源许可证、上游作者署名和本产品定制部分署名见 LICENSE（许可证）；第三方组件说明见 third_party（第三方说明）目录。
"@
  [IO.File]::WriteAllText((Join-Path $stage '使用说明.txt'), $instructions, [Text.UTF8Encoding]::new($true))
  $payloadManifest = [ordered]@{
    schemaVersion = 1
    product = 'BK 提词器'
    creator = '陈林'
    contactEmail = 'beyond.chenlin@gmail.com'
    version = $release.version
    buildNumber = $release.buildNumber
    sourceCommit = $sourceCommit
    modelId = $model.modelId
    modelManifestSha256 = (Get-FileHash -LiteralPath $modelManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    files = @(Get-BKFileManifest -Directory $stage)
  }
  Write-BKJson -Path (Join-Path $stage 'BK 提词器-manifest.json') -Value $payloadManifest
  $allPayloadFiles = @(Get-BKFileManifest -Directory $stage)
  $compilerArguments = @(
    '/Qp', "/DPayloadDir=$stage", "/DProjectRoot=$projectRoot",
    "/DReleaseVersion=$($release.version)", "/DReleaseBuildNumber=$($release.buildNumber)",
    "/DOutputDirectory=$compileOutput", "/DOutputFilename=$packageName-setup",
    (Join-Path $PSScriptRoot 'windows\installer.iss')
  )
  & $compiler.path @compilerArguments
  if ($LASTEXITCODE -ne 0) { throw "Installer compilation failed: $LASTEXITCODE" }
  $temporaryInstaller = Join-Path $compileOutput $installerName
  $installerMetadata = (Get-Item -LiteralPath $temporaryInstaller).VersionInfo
  # Inno Setup pads fixed-size version-resource strings with ASCII spaces.
  # Remove only U+0020 at the end; keep exact, case-sensitive identity checks.
  $versionResourcePadding = [char[]]@([char]0x20)
  $installerProductName = ([string]$installerMetadata.ProductName).TrimEnd($versionResourcePadding)
  $installerCompanyName = ([string]$installerMetadata.CompanyName).TrimEnd($versionResourcePadding)
  $installerProductVersion = ([string]$installerMetadata.ProductVersion).TrimEnd($versionResourcePadding)
  $installerNumericProductVersion = '{0}.{1}.{2}.{3}' -f $installerMetadata.ProductMajorPart, $installerMetadata.ProductMinorPart, $installerMetadata.ProductBuildPart, $installerMetadata.ProductPrivatePart
  $installerNumericFileVersion = '{0}.{1}.{2}.{3}' -f $installerMetadata.FileMajorPart, $installerMetadata.FileMinorPart, $installerMetadata.FileBuildPart, $installerMetadata.FilePrivatePart
  if ($installerProductName -cne 'BK 提词器' -or $installerCompanyName -cne '陈林' -or
      $installerProductVersion -cne $release.productVersion -or
      $installerNumericProductVersion -cne $release.fileVersion -or
      $installerNumericFileVersion -cne $release.fileVersion) {
    $observed = [ordered]@{product=$installerProductName; company=$installerCompanyName; productVersion=$installerProductVersion; numericProductVersion=$installerNumericProductVersion; numericFileVersion=$installerNumericFileVersion}
    throw ('The compiled installer has incorrect product metadata: ' + ($observed | ConvertTo-Json -Compress))
  }
  if ((Assert-BKCleanSource -ProjectRoot $projectRoot) -cne $sourceCommit) { throw 'The source changed while the installer was being created.' }
  $installerHash = (Get-FileHash -LiteralPath $temporaryInstaller -Algorithm SHA256).Hash.ToLowerInvariant()
  $installerSignature = Get-AuthenticodeSignature -LiteralPath $temporaryInstaller
  $releaseManifest = [ordered]@{
    schemaVersion = 1
    product = 'BK 提词器'
    creator = '陈林'
    contactEmail = 'beyond.chenlin@gmail.com'
    distribution = 'windows-x64-installer'
    version = $release.version
    buildNumber = $release.buildNumber
    sourceCommit = $sourceCommit
    createdUtc = [DateTime]::UtcNow.ToString('o')
    installer = [ordered]@{file=$installerName; bytes=(Get-Item -LiteralPath $temporaryInstaller).Length; sha256=$installerHash; authenticodeStatus=$installerSignature.Status.ToString()}
    installation = [ordered]@{appId='BeyondChenlin.BKTeleprompter'; scope='current-user'; minimumWindowsVersion='10.0.18362'; defaultDirectory='%LOCALAPPDATA%\Programs\BKTeleprompter'; userDataDirectory='%LOCALAPPDATA%\BKTeleprompter\app_data'; preservesUserDataOnUninstall=$true}
    compiler = [ordered]@{name=$compiler.name; publisher=$compiler.publisher; compilerSha256=$compiler.compilerSha256; engineSha256=$compiler.engineSha256}
    model = $model
    files = $allPayloadFiles
  }
  $temporaryManifest = Join-Path $compileOutput $releaseManifestName
  Write-BKJson -Path $temporaryManifest -Value $releaseManifest
  $temporaryChecksum = "$temporaryInstaller.sha256"
  [IO.File]::WriteAllText($temporaryChecksum, "$installerHash  $installerName`n", [Text.UTF8Encoding]::new($false))
  foreach ($pair in @(@($temporaryInstaller, $installer), @($temporaryChecksum, $checksumFile), @($temporaryManifest, $releaseManifestPath))) {
    [IO.File]::Move($pair[0], $pair[1])
    $publishedPaths.Add($pair[1])
  }
  [pscustomobject]@{product='BK 提词器'; version=$release.productVersion; sourceCommit=$sourceCommit; installer=$installer; sha256=$installerHash; manifest=$releaseManifestPath; fileCount=$allPayloadFiles.Count; modelIncluded=$true} | ConvertTo-Json
} catch {
  foreach ($path in $publishedPaths) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
  throw
} finally {
  if (Test-Path -LiteralPath $workRoot) { Remove-Item -LiteralPath $workRoot -Recurse -Force }
}
