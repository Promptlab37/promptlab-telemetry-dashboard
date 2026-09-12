@echo off
REM Zapne hlidace zpatky. Hlida, ze bezi LHM, server a adb reverse,
REM a obnovuje dashboard - ale JEN kdyz je telefon na domovske obrazovce.
schtasks /run /tn "PROMPTLAB-Telemetry-Watchdog" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Start-Sleep -Seconds 3; Write-Host ''; Write-Host '  Hlidac spusten.' -ForegroundColor Green; Write-Host ''"
timeout /t 3 >nul
