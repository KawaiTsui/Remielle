$patterns = [char]0xfffd, [char]0x951f, [char]0x9382, [char]0x6e7e, [char]0x9225
$files = Get-ChildItem lib, test -Recurse -File -Include *.dart
$matches = $files | Select-String -Pattern $patterns
if ($matches) {
  $matches | Format-Table Path, LineNumber, Line -AutoSize
  exit 1
}
Write-Output 'Encoding check passed.'
