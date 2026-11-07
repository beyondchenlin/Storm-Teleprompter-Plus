# Shared validation for local releases and the Windows release workflow.

function Write-BKJson {
  param([string]$Path, [object]$Value)
  [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 15), [Text.UTF8Encoding]::new($false))
}

function Assert-BKCleanSource {
  param([string]$ProjectRoot)
  $changes = @(git -C $ProjectRoot status --porcelain=v1 --untracked-files=all)
  if ($LASTEXITCODE -ne 0 -or $changes.Count -gt 0) {
    throw 'Commit and verify the complete source tree before building or packaging a release.'
  }
  $commit = (git -C $ProjectRoot rev-parse HEAD).Trim()
  if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{40}$') {
    throw 'Cannot identify the source commit.'
  }
  return $commit
}

function Resolve-BKVersion {
  param([string]$ProjectRoot, [string]$Version = '', [int]$BuildNumber = -1)
  $pubspec = [IO.File]::ReadAllText((Join-Path $ProjectRoot 'pubspec.yaml'))
  $match = [regex]::Match($pubspec, '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*(?:#.*)?$')
  if (-not $match.Success) { throw 'pubspec.yaml must declare a numeric version and build number.' }
  if ([string]::IsNullOrWhiteSpace($Version)) { $Version = $match.Groups[1].Value }
  if ($BuildNumber -eq -1) { $BuildNumber = [int]$match.Groups[2].Value }
  if ($Version -cne $match.Groups[1].Value -or $BuildNumber -ne [int]$match.Groups[2].Value) {
    throw 'The requested release version does not match pubspec.yaml.'
  }
  foreach ($part in @($Version.Split('.')) + @($BuildNumber.ToString())) {
    if ([long]$part -lt 0 -or [long]$part -gt 65535) { throw 'Windows version components must be in the range 0..65535.' }
  }
  return [pscustomobject]@{
    version = $Version
    buildNumber = $BuildNumber
    productVersion = "$Version+$BuildNumber"
    fileVersion = "$Version.$BuildNumber"
  }
}

function Assert-BKPeX64 {
  param([string]$Path)
  $stream = [IO.File]::OpenRead($Path)
  try {
    $reader = [IO.BinaryReader]::new($stream)
    if ($reader.ReadUInt16() -ne 0x5A4D) { throw "Not a Windows binary: $Path" }
    $stream.Position = 0x3C
    $peOffset = $reader.ReadInt32()
    if ($peOffset -lt 0 -or $peOffset -gt ($stream.Length - 6)) { throw "Invalid PE header: $Path" }
    $stream.Position = $peOffset
    if ($reader.ReadUInt32() -ne 0x00004550 -or $reader.ReadUInt16() -ne 0x8664) {
      throw "Expected an x64 PE binary: $Path"
    }
  } finally {
    $stream.Dispose()
  }
}

function Assert-BKExecutableBranding {
  param([string]$Path, [object]$Release)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Release executable is missing: $Path" }
  Assert-BKPeX64 -Path $Path
  $metadata = (Get-Item -LiteralPath $Path).VersionInfo
  if ($metadata.ProductName -cne 'BK 提词器' -or
      $metadata.FileDescription -cne 'BK 提词器' -or
      $metadata.OriginalFilename -cne 'BK 提词器.exe' -or
      $metadata.InternalName -cne 'BK 提词器' -or
      $metadata.CompanyName -cne '陈林' -or
      $metadata.LegalCopyright -cne 'Copyright (C) 2026 陈林. MIT License.' -or
      $metadata.Comments -cne '创作者：陈林；联系邮箱：beyond.chenlin@gmail.com') {
    throw 'Executable branding is incomplete.'
  }
  $numericVersion = '{0}.{1}.{2}.{3}' -f $metadata.FileMajorPart, $metadata.FileMinorPart, $metadata.FileBuildPart, $metadata.FilePrivatePart
  if ($metadata.ProductVersion -cne $Release.productVersion -or $numericVersion -cne $Release.fileVersion) {
    throw "Executable version does not match $($Release.productVersion)."
  }
}

function Get-BKFileManifest {
  param([string]$Directory, [switch]$RuntimeOnly)
  $root = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
  if ($RuntimeOnly) {
    foreach ($required in @('BK 提词器.exe', 'flutter_windows.dll', 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll', 'data\app.so', 'data\icudtl.dat')) {
      if (-not (Test-Path -LiteralPath (Join-Path $root $required) -PathType Leaf)) {
        throw "Required runtime file is missing: $required"
      }
    }
    $files = @((Get-Item -LiteralPath (Join-Path $root 'BK 提词器.exe')))
    $files += @(Get-ChildItem -LiteralPath $root -File -Filter '*.dll')
    $files += @(Get-ChildItem -LiteralPath (Join-Path $root 'data') -File -Recurse)
  } else {
    $files = @(Get-ChildItem -LiteralPath $root -File -Recurse)
  }
  foreach ($file in $files | Sort-Object FullName) {
    if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Release payload must not contain linked files: $($file.FullName)"
    }
    [pscustomobject]@{
      path = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
      bytes = $file.Length
      sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
  }
}

function Assert-BKFileManifest {
  param([object[]]$Actual, [object[]]$Expected)
  if ($Actual.Count -ne $Expected.Count) { throw 'Runtime files differ from the verified build receipt; rebuild first.' }
  $index = @{}
  foreach ($entry in $Expected) {
    if ($index.ContainsKey($entry.path)) { throw 'Duplicate file in the build receipt.' }
    $index[$entry.path] = $entry
  }
  foreach ($entry in $Actual) {
    $expectedEntry = $index[$entry.path]
    if ($null -eq $expectedEntry -or $entry.bytes -ne $expectedEntry.bytes -or $entry.sha256 -cne $expectedEntry.sha256) {
      throw "Runtime file does not match the verified build receipt: $($entry.path)"
    }
  }
}

function Read-BKModelManifest {
  param([string]$ProjectRoot)
  $path = Join-Path $ProjectRoot 'assets\asr\zipformer2-ced.manifest.json'
  $manifest = [IO.File]::ReadAllText($path) | ConvertFrom-Json
  if ($manifest.schemaVersion -ne 1 -or $manifest.modelId -cne 'zipformer2-ced' -or
      $manifest.modelFamily -cne 'zipformer' -or $manifest.sampleRate -ne 16000 -or @($manifest.files).Count -ne 4) {
    throw 'Unsupported Chinese speech model manifest.'
  }
  $roles = @{}
  $names = @{}
  foreach ($file in $manifest.files) {
    if ($file.role -notin @('encoder', 'decoder', 'joiner', 'tokens') -or $roles.ContainsKey($file.role) -or
        $file.name -notmatch '^[A-Za-z0-9_.-]+$' -or $file.name -in @('.', '..') -or $names.ContainsKey($file.name) -or
        $file.bytes -le 0 -or $file.sha256 -cnotmatch '^[0-9a-f]{64}$') {
      throw 'Invalid file identity in the Chinese speech model manifest.'
    }
    $roles[$file.role] = $true
    $names[$file.name] = $true
    $uri = [uri]$file.url
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -cne 'https') { throw 'Model downloads must use explicit HTTPS URLs.' }
  }
  return $manifest
}

function Assert-BKModelFile {
  param([string]$Path, [object]$Entry)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required model file is missing: $($Entry.name)" }
  if ((Get-Item -LiteralPath $Path).Length -ne $Entry.bytes -or
      (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Entry.sha256) {
    throw "Chinese model identity verification failed: $($Entry.name)"
  }
}

function Assert-BKOfficialSignature {
  param([string]$Path, [string]$Publisher)
  $signature = Get-AuthenticodeSignature -LiteralPath $Path
  $actualPublisher = if ($signature.SignerCertificate) {
    $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
  } else { '' }
  $publisherMatches = $actualPublisher -ceq $Publisher
  if ($Publisher -ceq 'Microsoft Corporation' -and $signature.SignerCertificate) {
    # Current VC runtimes are signed by Microsoft's software compatibility publisher.
    $publisherMatches = ($actualPublisher -ceq 'Microsoft Corporation' -or
      $actualPublisher -ceq 'Microsoft Windows Software Compatibility Publisher') -and
      $signature.SignerCertificate.Subject -cmatch '(^|,\s*)O=Microsoft Corporation(,|$)'
  }
  if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
      $null -eq $signature.SignerCertificate -or
      -not $publisherMatches) {
    throw "The official publisher signature is not valid: $Path"
  }
}

function Find-BKInnoCompiler {
  param([string]$ExplicitPath = '')
  if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
    if (-not (Test-Path -LiteralPath $ExplicitPath -PathType Leaf)) { throw "ISCC.exe was not found: $ExplicitPath" }
    $candidates = @([IO.Path]::GetFullPath($ExplicitPath))
  } else {
    $candidates = @(Get-Command ISCC.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
    foreach ($base in @($env:LOCALAPPDATA, $env:ProgramFiles, [Environment]::GetEnvironmentVariable('ProgramFiles(x86)'))) {
      if ([string]::IsNullOrWhiteSpace($base)) { continue }
      foreach ($suffix in @('Inno Setup 6\ISCC.exe', 'Inno Setup 7\ISCC.exe', 'Programs\Inno Setup 6\ISCC.exe', 'Programs\Inno Setup 7\ISCC.exe', 'BKTeleprompter\BuildTools\InnoSetup-6.7.3\ISCC.exe')) {
        $candidates += Join-Path $base $suffix
      }
    }
  }
  $path = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
  if ($null -eq $path) { return $null }
  Assert-BKOfficialSignature -Path $path -Publisher 'Pyrsys B.V.'
  $engine = Join-Path (Split-Path -Parent $path) 'ISCmplr.dll'
  Assert-BKOfficialSignature -Path $engine -Publisher 'Pyrsys B.V.'
  return [pscustomobject]@{
    path = $path
    name = 'Inno Setup'
    publisher = 'Pyrsys B.V.'
    compilerSha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    engineSha256 = (Get-FileHash -LiteralPath $engine -Algorithm SHA256).Hash.ToLowerInvariant()
  }
}

function Copy-BKVisualCRuntime {
  param([string]$BuildDirectory)
  $vswhere = Join-Path ([Environment]::GetEnvironmentVariable('ProgramFiles(x86)')) 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { throw 'Official Visual Studio redistributable discovery requires vswhere.exe.' }
  $installation = @(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
  if ($LASTEXITCODE -ne 0 -or $installation.Count -ne 1) { throw 'Cannot find the official Visual Studio C++ build tools.' }
  $redistRoot = Join-Path $installation[0] 'VC\Redist\MSVC'
  $versions = @(Get-ChildItem -LiteralPath $redistRoot -Directory | Where-Object { $_.Name -match '^\d+\.\d+\.\d+(?:\.\d+)?$' } | Sort-Object { [version]$_.Name } -Descending)
  $crt = $null
  foreach ($version in $versions) {
    $x64 = Join-Path $version.FullName 'x64'
    if (Test-Path -LiteralPath $x64 -PathType Container) {
      $crt = Get-ChildItem -LiteralPath $x64 -Directory -Filter 'Microsoft.VC*.CRT' | Select-Object -First 1
      if ($null -ne $crt) { break }
    }
  }
  if ($null -eq $crt) { throw 'The official x64 Visual C++ redistributable directory was not found.' }
  foreach ($name in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $crt.FullName $name) -PathType Leaf)) { throw "Required Microsoft runtime is missing: $name" }
  }
  $copied = @()
  foreach ($file in Get-ChildItem -LiteralPath $crt.FullName -Filter '*.dll' -File) {
    Assert-BKOfficialSignature -Path $file.FullName -Publisher 'Microsoft Corporation'
    Assert-BKPeX64 -Path $file.FullName
    $destination = Join-Path $BuildDirectory $file.Name
    Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
    if ((Get-FileHash -LiteralPath $file.FullName).Hash -cne (Get-FileHash -LiteralPath $destination).Hash) { throw "Runtime copy failed: $($file.Name)" }
    $copied += $file.Name
  }
  return [pscustomobject]@{
    source = 'Microsoft Visual Studio VC/Redist/MSVC/x64'
    version = (Get-Item -LiteralPath (Join-Path $crt.FullName 'msvcp140.dll')).VersionInfo.FileVersion
    redistDirectoryVersion = $version.Name
    architecture = 'x64'
    publisher = 'Microsoft Corporation'
    files = $copied
  }
}
