param([switch]$InstallIfMissing)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$compiler = Find-BKInnoCompiler
if ($null -ne $compiler) { $compiler | ConvertTo-Json; return }
if (-not $InstallIfMissing) {
  throw 'A verified official Inno Setup compiler was not found. Run tool/windows/ensure_inno.ps1 -InstallIfMissing to install the pinned official tool for the current user.'
}

$dependency = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'inno-setup.json')) | ConvertFrom-Json
$toolsRoot = Join-Path $env:LOCALAPPDATA 'BKTeleprompter\BuildTools'
$installDirectory = Join-Path $toolsRoot ('InnoSetup-' + $dependency.version)
$downloadDirectory = Join-Path $toolsRoot ('download-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($downloadDirectory) | Out-Null
$installer = Join-Path $downloadDirectory 'innosetup.exe'
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -UseBasicParsing -Uri $dependency.url -OutFile $installer -TimeoutSec 300
  if ((Get-Item -LiteralPath $installer).Length -ne $dependency.bytes -or
      (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant() -cne $dependency.sha256) {
    throw 'The Inno Setup download does not match the immutable official release.'
  }
  Assert-BKOfficialSignature -Path $installer -Publisher $dependency.publisher
  $arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CURRENTUSER', '/NOICONS', ('/DIR="' + $installDirectory + '"'))
  $process = Start-Process -FilePath $installer -ArgumentList $arguments -Wait -PassThru
  if ($process.ExitCode -ne 0) { throw "Official Inno Setup tool installation failed: $($process.ExitCode)" }
  $compiler = Find-BKInnoCompiler -ExplicitPath (Join-Path $installDirectory 'ISCC.exe')
  $compiler | ConvertTo-Json
} finally {
  if (Test-Path -LiteralPath $downloadDirectory) { Remove-Item -LiteralPath $downloadDirectory -Recurse -Force }
}
