# Spousti ji naplanovana uloha pri udalosti "system jde spat"
# (Kernel-Power, EventID 42). Zapise priznak, ktery server vydava
# na /state a dashboard podle nej prepne na uspavaci obrazovku.
#
# POZOR na ocekavani: mezi touto udalosti a skutecnym vypnutim USB
# ma Windows radove sekundu. Uspavaci obrazovka se tedy stihne ukazat
# jen kratce - zarucena je az probouzeci sekvence po navratu.
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$flag = Join-Path $root 'sleep.flag'
(Get-Date -Format 'HH:mm') | Out-File -FilePath $flag -Encoding utf8 -Force
Add-Content -Path (Join-Path $root 'watchdog.log') `
    -Value ("{0}  [spanek] priznak zapsan" -f (Get-Date -Format 'HH:mm:ss')) -Encoding UTF8
