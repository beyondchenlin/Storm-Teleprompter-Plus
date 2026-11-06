param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^\d+\.\d+\.\d+$')]
  [string]$Version,

  [Parameter(Mandatory = $true)]
  [string]$OutputDirectory,

  # Optional directory containing the zipformer2-ced model folder.
  [string]$ModelDirectory = ''
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$buildDirectory = Join-Path $projectRoot 'build\windows\x64\runner\Release'
$executable = Join-Path $buildDirectory 'BK103.exe'
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
  throw 'Build BK103 for Windows in release mode before packaging.'
}
$metadata = (Get-Item -LiteralPath $executable).VersionInfo
if ($metadata.ProductName -cne 'BK103' -or
    $metadata.FileDescription -cne 'BK103' -or
    $metadata.OriginalFilename -cne 'BK103.exe' -or
    $metadata.InternalName -cne 'BK103') {
  throw 'Executable branding is incomplete.'
}
if ($metadata.ProductVersion -notmatch ('^' + [regex]::Escape($Version) + '(?:\+|\s|$)')) {
  throw "Executable version does not match $Version."
}
$bundledIcon = Join-Path $buildDirectory 'data\flutter_assets\lib\favicon.png'
if ((Get-FileHash -LiteralPath $bundledIcon).Hash -ne
    (Get-FileHash -LiteralPath (Join-Path $projectRoot 'lib\favicon.png')).Hash) {
  throw 'Bundled icon does not match the source artwork; rebuild first.'
}

$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($outputRoot) | Out-Null
$packageName = "BK103-$Version-windows-x64"
$packageDirectory = Join-Path $outputRoot $packageName
$archive = Join-Path $outputRoot "$packageName.zip"
$checksumFile = "$archive.sha256"
if ((Test-Path -LiteralPath $packageDirectory) -or (Test-Path -LiteralPath $archive) -or (Test-Path -LiteralPath $checksumFile)) {
  throw 'The requested package already exists; choose a new output directory.'
}
$sourceChanges = @(git -C $projectRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $sourceChanges.Count -gt 0) {
  throw 'Commit and verify the complete source tree before packaging.'
}
$workRoot = Join-Path $outputRoot ('.' + $packageName + '-' + [guid]::NewGuid().ToString('N'))
$stage = Join-Path $workRoot $packageName
$temporaryArchive = Join-Path $workRoot "$packageName.zip"
$temporaryChecksum = "$temporaryArchive.sha256"
$publishedPaths = [Collections.Generic.List[string]]::new()
[IO.Directory]::CreateDirectory($stage) | Out-Null
try {
  # Explicit allowlist: never package a stale executable, app_data, or build logs.
  Copy-Item -LiteralPath $executable -Destination (Join-Path $stage 'BK103.exe')
  Get-ChildItem -LiteralPath $buildDirectory -File -Filter '*.dll' |
    Copy-Item -Destination $stage
  Copy-Item -LiteralPath (Join-Path $buildDirectory 'data') -Destination $stage -Recurse
  Copy-Item -LiteralPath (Join-Path $projectRoot 'LICENSE') -Destination $stage

  $modelFiles = @()
  if (-not [string]::IsNullOrWhiteSpace($ModelDirectory)) {
    $modelSource = Join-Path $ModelDirectory 'zipformer2-ced'
    $modelDestination = Join-Path $stage 'app_data\asr_models\zipformer2-ced'
    [IO.Directory]::CreateDirectory($modelDestination) | Out-Null
    $modelFiles = @(
      'decoder-epoch-99-avg-1.onnx',
      'encoder-epoch-99-avg-1.onnx',
      'joiner-epoch-99-avg-1.onnx',
      'tokens.txt'
    )
    foreach ($name in $modelFiles) {
      $source = Join-Path $modelSource $name
      if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or
          (Get-Item -LiteralPath $source).Length -eq 0) {
        throw "Required model file is missing or empty: $source"
      }
      $destination = Join-Path $modelDestination $name
      Copy-Item -LiteralPath $source -Destination $destination
      if ((Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $destination).Hash) {
        throw "Model copy verification failed: $name"
      }
    }
  }

  $modelNote = if ($modelFiles.Count -gt 0) {
    '本包包含中文语音模型，可在语音设置中选择中文模型。'
  } else {
    '语音跟读前，请在语音设置中下载或导入模型。'
  }
  $instructions = @"
BK103（智能提词器）$Version

1. 将整个压缩包解压到有写入权限的文件夹，再打开 BK103.exe（启动程序）。
2. 请保留同目录的动态库和 data（程序资源）文件夹，不要只移动启动程序。
3. $modelNote
4. 稿件、设置和模型保存在 app_data（应用数据）文件夹。升级前先关闭软件并备份该文件夹，解压新版后再复制到新目录。
5. 本分发包不含个人稿件、设置或运行日志。
6. 阅读提示：提词画面齿轮中可调整当前字颜色及 0%～15% 放大；设置会自动保存。

许可证与原作者署名见 LICENSE（许可证）文件。
"@
  [IO.File]::WriteAllText((Join-Path $stage '使用说明.txt'), $instructions, [Text.UTF8Encoding]::new($true))
  $manifest = @(Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object FullName | ForEach-Object {
    [pscustomobject]@{
      path = $_.FullName.Substring($stage.Length + 1).Replace('\', '/')
      bytes = $_.Length
      sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
  })
  $sourceCommit = (git -C $projectRoot rev-parse HEAD).Trim()
  if ($LASTEXITCODE -ne 0) { throw 'Cannot identify the source commit.' }
  $summary = [pscustomobject]@{
    product = 'BK103'
    version = $Version
    sourceCommit = $sourceCommit
    modelIncluded = $modelFiles.Count -gt 0
    files = $manifest
  }
  [IO.File]::WriteAllText((Join-Path $stage 'BK103-manifest.json'), ($summary | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
  Compress-Archive -LiteralPath $stage -DestinationPath $temporaryArchive -CompressionLevel Optimal
  $archiveHash = (Get-FileHash -LiteralPath $temporaryArchive -Algorithm SHA256).Hash.ToLowerInvariant()
  [IO.File]::WriteAllText($temporaryChecksum, "$archiveHash  $packageName.zip`n", [Text.UTF8Encoding]::new($false))
  # Publish only completed artifacts. These APIs refuse to overwrite another run.
  [IO.Directory]::Move($stage, $packageDirectory)
  $publishedPaths.Add($packageDirectory)
  [IO.File]::Move($temporaryArchive, $archive)
  $publishedPaths.Add($archive)
  [IO.File]::Move($temporaryChecksum, $checksumFile)
  $publishedPaths.Add($checksumFile)
  [pscustomobject]@{
    product = 'BK103'
    version = $Version
    archive = $archive
    archiveBytes = (Get-Item -LiteralPath $archive).Length
    sha256 = $archiveHash
    fileCount = $manifest.Count + 1
    modelIncluded = $modelFiles.Count -gt 0
  } | ConvertTo-Json
} catch {
  foreach ($createdPath in $publishedPaths) {
    if (Test-Path -LiteralPath $createdPath) {
      Remove-Item -LiteralPath $createdPath -Recurse -Force
    }
  }
  throw
} finally {
  if (Test-Path -LiteralPath $workRoot) {
    Remove-Item -LiteralPath $workRoot -Recurse -Force
  }
}
