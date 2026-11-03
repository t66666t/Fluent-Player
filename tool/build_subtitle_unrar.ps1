# Build the extract-only UnRAR bridge for Windows x64.
# Requires MinGW g++. Does not create RAR archives and does not call 7-Zip.
param([string]$Compiler = $env:CXX)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$src = Join-Path $root "third_party\unrar-src\unrar"
$bridge = Join-Path $root "native\subtitle_archive\subtitle_archive_unrar.cpp"
$work = Join-Path $root "build\subtitle_unrar"
$destDir = Join-Path $root "native\subtitle_archive\prebuilt\windows-x64"
$cxx = if ($Compiler) { $Compiler } else { (Get-Command g++ -ErrorAction Stop).Source }
if (-not (Test-Path -LiteralPath $cxx)) { throw "g++ not found at $cxx" }
New-Item -ItemType Directory -Force -Path $work, $destDir | Out-Null

$units = @(
  "rar","strlist","strfn","pathfn","smallfn","global","file","filefn","filcreat",
  "archive","arcread","unicode","system","crypt","crc","rawread","encname","resource",
  "match","timefn","rdwrfn","consio","options","errhnd","rarvm","secpassword",
  "rijndael","getbits","sha1","sha256","blake2s","hash","extinfo","extract","volume",
  "list","find","unpack","headers","threadpool","rs16","cmddata","ui","largepage",
  "filestr","scantree","dll","qopen","recvol","rs","motw","isnt"
)
$flags = @(
  "-c","-O2","-std=c++11","-DRARDLL","-D_FILE_OFFSET_BITS=64","-D_LARGEFILE_SOURCE",
  "-D_M_X64","-DSUBTITLE_UNRAR_NO_SSE","-Wno-switch",
  "-Wno-unused-variable","-Wno-unused-function","-I$src"
)
foreach ($unit in $units) {
  Write-Output "compile $unit"
  & $cxx @flags "-o" (Join-Path $work "$unit.o") (Join-Path $src "$unit.cpp")
  if ($LASTEXITCODE -ne 0) { throw "compile failed: $unit" }
}
Write-Output "compile bridge"
& $cxx @flags "-o" (Join-Path $work "subtitle_archive_unrar.o") $bridge
if ($LASTEXITCODE -ne 0) { throw "bridge compile failed" }
& $cxx -c -O2 -std=c++11 -o (Join-Path $work "comsupp_stub.o") (Join-Path $root "native\subtitle_archive\comsupp_stub.cpp")
if ($LASTEXITCODE -ne 0) { throw "com stub compile failed" }
$objects = Get-ChildItem $work -Filter *.o | Where-Object { $_.Name -ne "subtitle_unrar_tool.o" } | ForEach-Object { $_.FullName }
$dll = Join-Path $destDir "subtitle_unrar.dll"
& $cxx -shared -static-libgcc -static-libstdc++ -o $dll @objects -lole32 -loleaut32 -luuid -lwbemuuid
if ($LASTEXITCODE -ne 0) { throw "link failed" }
Write-Output "built $dll"
& $cxx @flags "-o" (Join-Path $work "subtitle_unrar_tool.o") (Join-Path $root "native\subtitle_archive\subtitle_unrar_tool.cpp")
if ($LASTEXITCODE -ne 0) { throw "tool compile failed" }
$toolObjects = Get-ChildItem $work -Filter *.o | Where-Object { $_.Name -ne "subtitle_archive_unrar.o" } | ForEach-Object { $_.FullName }
$tool = Join-Path $destDir "subtitle_unrar_tool.exe"
& $cxx -static-libgcc -static-libstdc++ -o $tool @toolObjects -lole32 -loleaut32 -luuid -lwbemuuid
if ($LASTEXITCODE -ne 0) { throw "tool link failed" }
Write-Output "built $tool"
Get-Item $dll, $tool | Select-Object FullName, Length
