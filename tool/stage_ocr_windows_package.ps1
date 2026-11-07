param([string]$ProjectPath = '')
$ErrorActionPreference = 'Stop'
$ocrWorkspace = Split-Path -Parent $PSScriptRoot
$ocrProject = if ($ProjectPath) { [IO.Path]::GetFullPath($ProjectPath) } else { $ocrWorkspace }
$ocrRelease = [IO.Path]::GetFullPath((Join-Path $ocrProject 'build/windows/x64/runner/Release'))
$ocrDestination = [IO.Path]::GetFullPath((Join-Path $ocrWorkspace '.artifacts/ocr-upgrade/windows-package'))
$ocrManifest = Join-Path $ocrProject 'build/windows/x64/install_manifest.txt'
if (-not (Test-Path -LiteralPath $ocrManifest)) { throw 'Build Windows Release first.' }

# Install metadata excludes historical downloads and user data in the build
# output. MSBuild copies runner/plugin DLLs without listing all of them here.
$ocrFiles = @(Get-Content -LiteralPath $ocrManifest) +
    @(Get-ChildItem -LiteralPath $ocrRelease -Filter '*.dll' -File | ForEach-Object FullName) +
    @((Join-Path $ocrRelease 'fluent-player.exe'))
foreach ($ocrFile in ($ocrFiles | Sort-Object -Unique)) {
    $ocrAbsolute = [IO.Path]::GetFullPath($ocrFile)
    if (-not $ocrAbsolute.StartsWith($ocrRelease + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Install manifest points outside the release directory.'
    }
    $ocrRelative = [IO.Path]::GetRelativePath($ocrRelease, $ocrAbsolute)
    $ocrTarget = Join-Path $ocrDestination $ocrRelative
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($ocrTarget)) -Force | Out-Null
    Copy-Item -LiteralPath $ocrAbsolute -Destination $ocrTarget -Force
}
Write-Output $ocrDestination
