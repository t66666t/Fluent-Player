param(
    [string]$OutputDirectory = '',
    [switch]$VerifyLegacyQuoting
)
$ErrorActionPreference = 'Stop'
$taskWorkspace = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $taskWorkspace 'build/windows_process_argument_tests'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$taskVswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$taskVs = & $taskVswhere -latest -prerelease -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $taskVs) { throw 'Visual Studio C++ build tools not found.' }
$taskVc = Get-ChildItem -LiteralPath (Join-Path $taskVs 'VC/Tools/MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1
$taskSdkRoot = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots').KitsRoot10
$taskSdkVersion = (Get-ChildItem -LiteralPath (Join-Path $taskSdkRoot 'Include') -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
$taskCompiler = Join-Path $taskVc.FullName 'bin/Hostx64/x64/cl.exe'
$taskExe = Join-Path $OutputDirectory 'windows_process_arguments_test.exe'
$taskArguments = @('/nologo', '/std:c++17', '/EHsc', '/MD', '/W4', '/WX', '/utf-8', '/DUNICODE', '/D_UNICODE')
if ($VerifyLegacyQuoting) { $taskArguments += '/DVERIFY_LEGACY_QUOTING' }
foreach ($taskInclude in @($taskWorkspace, (Join-Path $taskVc.FullName 'include'), "$taskSdkRoot/Include/$taskSdkVersion/ucrt", "$taskSdkRoot/Include/$taskSdkVersion/shared", "$taskSdkRoot/Include/$taskSdkVersion/um")) {
    $taskArguments += @('/I', $taskInclude)
}
$taskArguments += @("/Fo$OutputDirectory/", "/Fe$taskExe", (Join-Path $taskWorkspace 'test/native/windows_process_arguments_test.cpp'), '/link', "/LIBPATH:$($taskVc.FullName)/lib/x64", "/LIBPATH:$taskSdkRoot/Lib/$taskSdkVersion/um/x64", "/LIBPATH:$taskSdkRoot/Lib/$taskSdkVersion/ucrt/x64", 'shell32.lib')
& $taskCompiler @taskArguments
if ($LASTEXITCODE -ne 0) { throw "Native argument test compilation failed: $LASTEXITCODE" }
& $taskExe
if ($LASTEXITCODE -ne 0) { throw "Native argument round trip failed: $LASTEXITCODE" }
