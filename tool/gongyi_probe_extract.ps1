$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$video = Get-ChildItem 'C:\Users\11\Downloads\Video\SPIDER-MAN*4K.mp4' | Select-Object -First 1
if (-not $video) { Write-Host 'VIDEO NOT FOUND'; exit 2 }
Write-Host "VIDEO: $($video.FullName)"

$outDir = Join-Path $env:TEMP 'gongyi_probe'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$out = Join-Path $outDir 'audio.m4a'

& 'd:\1spbfq\video_player_app\assets\binaries\windows\ffmpeg.exe' -y -i $video.FullName -t 60 -vn -c:a aac -b:a 128k $out 2>&1 | Select-Object -Last 3
$f = Get-Item $out
Write-Host "AUDIO: $($f.FullName) ($($f.Length) bytes)"
