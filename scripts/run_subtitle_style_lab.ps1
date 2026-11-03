param([switch]$Release)
$ErrorActionPreference = 'Stop'
$projectPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
Push-Location -LiteralPath $projectPath
try {
    $mode = if ($Release) { '--release' } else { '--debug' }
    & flutter run -d windows $mode
    if ($LASTEXITCODE -ne 0) { throw "Flutter exited with code $LASTEXITCODE" }
}
finally {
    Pop-Location
}
