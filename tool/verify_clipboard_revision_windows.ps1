param([string]$VisualStudioPath = '', [string]$SdkVersion = '')
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
if (-not $VisualStudioPath) {
  $taskVswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
  $VisualStudioPath = & $taskVswhere -latest -prerelease -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
}
if (-not $VisualStudioPath) { throw 'Visual Studio C++ build tools not found.' }
$taskVc = Get-ChildItem -LiteralPath (Join-Path $VisualStudioPath 'VC/Tools/MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1
$taskSdkRoot = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots').KitsRoot10
if (-not $SdkVersion) { $SdkVersion = (Get-ChildItem -LiteralPath (Join-Path $taskSdkRoot 'Include') -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name }
$taskOutput = Join-Path $taskRoot 'build/clipboard_revision_tests'
New-Item -ItemType Directory -Force -Path $taskOutput | Out-Null
$taskCompilerBin = Join-Path $taskVc.FullName 'bin/Hostx64/x64'
$taskSavedPath = $env:PATH
Push-Location -LiteralPath $taskRoot
try {
  $env:PATH = "$taskCompilerBin;$(Join-Path $taskRoot 'windows/flutter/ephemeral');$taskSavedPath"
  $taskArguments = @('/nologo', '/std:c++17', '/EHsc', '/MD', '/W4', '/WX', '/wd4100', '/DNOMINMAX', '/DUNICODE', '/D_UNICODE')
  foreach ($taskInclude in @((Join-Path $taskVc.FullName 'include'), "$taskSdkRoot/Include/$SdkVersion/ucrt", "$taskSdkRoot/Include/$SdkVersion/shared", "$taskSdkRoot/Include/$SdkVersion/um", 'windows/flutter/ephemeral/cpp_client_wrapper/include', 'windows/flutter/ephemeral')) {
    $taskArguments += @('/I', $taskInclude)
  }
  $taskExe = Join-Path $taskOutput 'clipboard_revision_test.exe'
  $taskArguments += @("/Fo$taskOutput/", "/Fe$taskExe", 'test/native/clipboard_revision_test.cpp', 'windows/runner/clipboard_revision.cpp', 'windows/flutter/ephemeral/cpp_client_wrapper/standard_codec.cc', 'windows/flutter/ephemeral/cpp_client_wrapper/core_implementations.cc', '/link', "/LIBPATH:$(Join-Path $taskVc.FullName 'lib/x64')", "/LIBPATH:$taskSdkRoot/Lib/$SdkVersion/um/x64", "/LIBPATH:$taskSdkRoot/Lib/$SdkVersion/ucrt/x64", 'windows/flutter/ephemeral/flutter_windows.dll.lib', 'user32.lib', 'advapi32.lib')
  & (Join-Path $taskCompilerBin 'cl.exe') @taskArguments
  if ($LASTEXITCODE -ne 0) { throw "Native compilation failed: $LASTEXITCODE" }
  & $taskExe
  if ($LASTEXITCODE -ne 0) { throw "Native clipboard checks failed: $LASTEXITCODE" }
} finally {
  $env:PATH = $taskSavedPath
  Pop-Location
}
