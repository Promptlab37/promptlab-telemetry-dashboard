@echo off
REM Vypne hlidace. Telefon pak nikdo nepresmerovava a muzes si v nem
REM v klidu cokoli nastavit. Dashboard bezi dal, jen se sam neobnovuje.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$me=$PID; Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -like '*-File*another_phone\watchdog.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }; Write-Host ''; Write-Host '  Hlidac zastaven. Telefon je volny.' -ForegroundColor Green; Write-Host ''"
timeout /t 3 >nul
