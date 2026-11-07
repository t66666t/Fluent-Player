param(
    [Parameter(Mandatory = $true)][string]$VideoPath,
    [Parameter(Mandatory = $true)][string]$FfmpegPath
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$video = Get-Item -LiteralPath $VideoPath | Select-Object -First 1
if (-not $video) { Write-Host 'VIDEO NOT FOUND'; exit 2 }
Write-Host "VIDEO: $($video.FullName)"

$outDir = Join-Path $env:TEMP 'gongyi_probe'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$out = Join-Path $outDir 'audio.m4a'

& $FfmpegPath -y -i $video.FullName -t 60 -vn -c:a aac -b:a 128k $out 2>&1 | Select-Object -Last 3
$f = Get-Item $out
Write-Host "AUDIO: $($f.FullName) ($($f.Length) bytes)"
