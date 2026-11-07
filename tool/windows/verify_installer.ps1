param(
  [Parameter(Mandatory = $true)]
  [string]$InstallerPath,
  [Parameter(Mandatory = $true)]
  [string]$ReleaseManifestPath,
  [Parameter(Mandatory = $true)]
  [string]$TestRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Run the installer verification from a non-administrator PowerShell session.'
}
$installer = (Get-Item -LiteralPath $InstallerPath).FullName
$release = [IO.File]::ReadAllText((Get-Item -LiteralPath $ReleaseManifestPath).FullName) | ConvertFrom-Json
if ($release.schemaVersion -ne 1 -or $release.distribution -cne 'windows-x64-installer' -or
    (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant() -cne $release.installer.sha256) {
  throw 'Installer identity does not match the release manifest.'
}
$root = [IO.Path]::GetFullPath($TestRoot)
if (Test-Path -LiteralPath $root) { throw 'Use a new, empty test root.' }
$registry = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\BeyondChenlin.BKTeleprompter_is1'
$desktopLink = Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'BK 提词器.lnk'
$menuDirectory = Join-Path ([Environment]::GetFolderPath('Programs')) 'BK 提词器'
if ((Test-Path -LiteralPath $registry) -or (Test-Path -LiteralPath $desktopLink) -or (Test-Path -LiteralPath $menuDirectory)) {
  throw 'A BK installation or shortcut already exists. Isolated verification refuses to replace it.'
}
$userData = Join-Path $env:LOCALAPPDATA 'BKTeleprompter\app_data'
$dataExisted = Test-Path -LiteralPath $userData -PathType Container
$dataBefore = @()
if ($dataExisted) { $dataBefore = @(Get-BKFileManifest -Directory $userData) }
$appDirectory = Join-Path $root '安装目录 中文'
[IO.Directory]::CreateDirectory($root) | Out-Null

function Invoke-BKSetupCheck {
  param([string]$Path, [string[]]$Arguments)
  $process = Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru
  if ($process.ExitCode -ne 0) { throw "Installer process failed with exit code $($process.ExitCode). Inspect the test logs." }
}

function Assert-BKInstalledPayload {
  foreach ($entry in $release.files) {
    $path = Join-Path $appDirectory $entry.path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -ne $entry.bytes -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.sha256) {
      throw "Installed payload mismatch: $($entry.path)"
    }
  }
  $marker = [IO.File]::ReadAllText((Join-Path $appDirectory 'bk-installed.json')) | ConvertFrom-Json
  if ($marker.schemaVersion -ne 1 -or $marker.mode -cne 'installed') { throw 'Installed-mode marker is invalid.' }
  $registration = Get-ItemProperty -LiteralPath $registry
  if ($registration.InstallLocation.TrimEnd('\') -ine $appDirectory.TrimEnd('\') -or
      $registration.Publisher -cne '陈林' -or $registration.DisplayVersion -cne $release.version) {
    throw 'The single-user uninstall registration is incorrect.'
  }
  foreach ($link in @($desktopLink, (Join-Path $menuDirectory 'BK 提词器.lnk'))) {
    if (-not (Test-Path -LiteralPath $link -PathType Leaf)) { throw "Shortcut is missing: $link" }
    $shell = New-Object -ComObject WScript.Shell
    try {
      $shortcut = $shell.CreateShortcut($link)
      if ($shortcut.TargetPath -ine (Join-Path $appDirectory 'BK 提词器.exe')) { throw "Shortcut target is incorrect: $link" }
    } finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
  }
  foreach ($name in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    $path = Join-Path $appDirectory $name
    Assert-BKOfficialSignature -Path $path -Publisher 'Microsoft Corporation'
    Assert-BKPeX64 -Path $path
  }
}

$baseArguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOCLOSEAPPLICATIONS', '/NORESTARTAPPLICATIONS', '/TASKS="desktopicon"')
Invoke-BKSetupCheck -Path $installer -Arguments ($baseArguments + @(('/DIR="' + $appDirectory + '"'), ('/LOG="' + (Join-Path $root 'install.log') + '"')))
Assert-BKInstalledPayload

# This unowned file simulates data that an older portable version left beside the app.
$sentinelDirectory = Join-Path $appDirectory 'app_data'
[IO.Directory]::CreateDirectory($sentinelDirectory) | Out-Null
$sentinel = Join-Path $sentinelDirectory 'installer-preservation-check.txt'
[IO.File]::WriteAllText($sentinel, 'BK installer verification: preserve unowned files.', [Text.UTF8Encoding]::new($false))
$sentinelHash = (Get-FileHash -LiteralPath $sentinel).Hash

# No /DIR on the second installation: this checks the stable AppId and reuse of the prior location.
Invoke-BKSetupCheck -Path $installer -Arguments ($baseArguments + @('/LOG="' + (Join-Path $root 'upgrade.log') + '"'))
Assert-BKInstalledPayload
if ((Get-FileHash -LiteralPath $sentinel).Hash -cne $sentinelHash) { throw 'Cover installation modified an unowned file.' }

Invoke-BKSetupCheck -Path (Join-Path $appDirectory 'unins000.exe') -Arguments @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', ('/LOG="' + (Join-Path $root 'uninstall.log') + '"'))
if ((Test-Path -LiteralPath $registry) -or (Test-Path -LiteralPath $desktopLink) -or (Test-Path -LiteralPath $menuDirectory)) {
  throw 'Uninstallation did not remove its own registration or shortcuts.'
}
foreach ($entry in $release.files) {
  if (Test-Path -LiteralPath (Join-Path $appDirectory $entry.path)) { throw "Uninstallation retained an installed payload file: $($entry.path)" }
}
if (-not (Test-Path -LiteralPath $sentinel) -or (Get-FileHash -LiteralPath $sentinel).Hash -cne $sentinelHash) {
  throw 'Uninstallation did not preserve the unowned file.'
}
if ((Test-Path -LiteralPath $userData -PathType Container) -ne $dataExisted) { throw 'Installer changed the existence of the user data directory.' }
if ($dataExisted) {
  Assert-BKFileManifest -Actual @(Get-BKFileManifest -Directory $userData) -Expected @($dataBefore)
}
$report = [ordered]@{
  schemaVersion = 1
  sourceCommit = $release.sourceCommit
  installerSha256 = $release.installer.sha256
  nonAdministrator = $true
  unicodeInstallDirectory = $appDirectory
  verifiedPayloadFiles = @($release.files).Count
  shortcutsVerified = $true
  repeatedInstallReusedDirectory = $true
  uninstallationVerified = $true
  unownedFilePreserved = $true
  userDataUnchanged = $true
  appLaunched = $false
  completedUtc = [DateTime]::UtcNow.ToString('o')
}
Write-BKJson -Path (Join-Path $root 'installer-verification.json') -Value $report
$report | ConvertTo-Json
