$enc = [System.Text.Encoding]::GetEncoding(932)
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("// Generated from Windows code page 932.")
[void]$sb.AppendLine("// Trail index 0 is byte 0x40. Byte 0x7F is omitted.")
[void]$sb.AppendLine("const shiftJisDoubleByte = <int, String>{")
$leads = New-Object System.Collections.Generic.List[int]
0x81..0x9F | ForEach-Object { $leads.Add($_) }
0xE0..0xFC | ForEach-Object { $leads.Add($_) }
foreach ($lead in $leads) {
  $chars = New-Object System.Text.StringBuilder
  foreach ($trail in 0x40..0xFC) {
    if ($trail -eq 0x7F) { continue }
    $text = $enc.GetString([byte[]]($lead, $trail))
    if ($text.Length -ne 1) {
      [void]$chars.Append([char]0xFFFD)
    } else {
      [void]$chars.Append($text[0])
    }
  }
  $literal = $chars.ToString().Replace('\', '\\').Replace("'", "\'").Replace('$', '\$')
  [void]$sb.Append("  ")
  [void]$sb.Append($lead)
  [void]$sb.Append(": '")
  [void]$sb.Append($literal)
  [void]$sb.AppendLine("',")
}
[void]$sb.AppendLine("};")
$path = "D:\1spbfq\video_player_app\lib\features\subtitle_search\subtitle_shift_jis_table.dart"
[System.IO.File]::WriteAllText($path, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
Write-Output ("bytes=" + (Get-Item $path).Length)
