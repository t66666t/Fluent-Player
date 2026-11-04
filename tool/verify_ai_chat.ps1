param(
  [string]$FlutterRoot = 'D:\FlutterSDK\flutter',
  [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$dartCommand = Join-Path $FlutterRoot 'bin\dart.bat'
$flutterCommand = Join-Path $FlutterRoot 'bin\flutter.bat'
if (!(Test-Path -LiteralPath $dartCommand) -or !(Test-Path -LiteralPath $flutterCommand)) {
  throw "Flutter SDK missing: $FlutterRoot"
}

Push-Location $projectRoot
try {
  $aiTests = @(Get-ChildItem -LiteralPath 'test' -Filter 'ai_*_test.dart' |
    Sort-Object Name | ForEach-Object { Join-Path 'test' $_.Name })
  & $dartCommand format 'lib/features/ai_chat' @aiTests
  if ($LASTEXITCODE -ne 0) { throw 'AI code formatting failed.' }
  & $flutterCommand analyze --no-pub 'lib/features/ai_chat' @aiTests
  if ($LASTEXITCODE -ne 0) { throw 'AI static analysis failed.' }
  & $flutterCommand test --no-pub @aiTests
  if ($LASTEXITCODE -ne 0) { throw 'AI tests failed.' }
  if (!$SkipBuild) {
    & $flutterCommand build windows --debug --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Windows build failed.' }
  }
  Write-Host 'AI verification completed.'
} finally {
  Pop-Location
}
