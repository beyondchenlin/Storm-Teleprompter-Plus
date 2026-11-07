param(
  [Parameter(Mandatory = $true)]
  [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$manifest = Read-BKModelManifest -ProjectRoot $projectRoot
$root = [IO.Path]::GetFullPath($OutputDirectory)
$directory = Join-Path $root $manifest.modelId
[IO.Directory]::CreateDirectory($directory) | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$oldProgress = $ProgressPreference
$ProgressPreference = 'SilentlyContinue'
try {
  foreach ($entry in $manifest.files) {
    $destination = Join-Path $directory $entry.name
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
      Assert-BKModelFile -Path $destination -Entry $entry
      continue
    }
    $temporary = Join-Path $directory ('.download-' + [guid]::NewGuid().ToString('N'))
    try {
      Write-Host "Downloading the verified Chinese model: $($entry.name)"
      Invoke-WebRequest -UseBasicParsing -Uri $entry.url -OutFile $temporary -TimeoutSec 300
      Assert-BKModelFile -Path $temporary -Entry $entry
      [IO.File]::Move($temporary, $destination)
    } finally {
      if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
  }
  [pscustomobject]@{modelId=$manifest.modelId; modelDirectory=$directory; modelRoot=$root; manifestSha256=(Get-FileHash -LiteralPath (Join-Path $projectRoot 'assets\asr\zipformer2-ced.manifest.json')).Hash.ToLowerInvariant(); verifiedFiles=@($manifest.files).Count} | ConvertTo-Json
} finally {
  $ProgressPreference = $oldProgress
}
