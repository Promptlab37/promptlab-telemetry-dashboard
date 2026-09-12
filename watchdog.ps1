# ---------------------------------------------------------------
#  Hlidac telemetrie  (v2 - stranka bezi V TELEFONU)
#
#  Architektura:
#     LibreHardwareMonitor (admin)  ->  cidla, port 8085
#     server.ps1                    ->  port 8099: stranka + /api proxy
#     adb reverse 8099              ->  telefon vidi PC jako svuj localhost
#     aplikace PROMPTLAB (WebView)  ->  vykresluje dashboard nativne
#
#  Diky tomu, ze stranka bezi v telefonu, prezije uspani pocitace:
#  kdyz prestanou chodit data, sama prepne na uspavaci obrazovku
#  a po navratu spusti probouzeci sekvenci.
# ---------------------------------------------------------------
param(
    [int]$IntervalSec = 10,
    [int]$Port        = 8099,
    # Cesty k nastrojum se hledaji samy (Najdi-Adb / Najdi-Lhm nize);
    # parametrem nebo promennou prostredi se daji prebit.
    [string]$AdbExe   = $env:PROMPTLAB_ADB,
    [string]$LhmExe   = $env:PROMPTLAB_LHM,
    [switch]$Once
)

$ErrorActionPreference = 'SilentlyContinue'
$root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$serverPs1 = Join-Path $root 'server.ps1'
$logFile   = Join-Path $root 'watchdog.log'

# Nastroje se hledaji v tomto poradi: parametr / promenna prostredi ->
# standardni umisteni -> PATH. Zadna cesta do domovskeho adresare natvrdo -
# s tou by skript bezel jen na jednom pocitaci.
function Najdi-Adb {
    if ($AdbExe) { return $AdbExe }
    $sdk = if ($env:ANDROID_HOME)          { $env:ANDROID_HOME }
           elseif ($env:ANDROID_SDK_ROOT)  { $env:ANDROID_SDK_ROOT }
           else { Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
    $p = Join-Path $sdk 'platform-tools\adb.exe'
    if (Test-Path $p) { return $p }
    $cmd = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $p            # neexistujici cesta: hlidac ji zaloguje sam
}

function Najdi-Lhm {
    if ($LhmExe) { return $LhmExe }
    # winget ma v nazvu balicku hash zdroje, ktery se muze lisit - proto hvezdicka.
    $kandidati = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\LibreHardwareMonitor.LibreHardwareMonitor_*\LibreHardwareMonitor.exe'),
        (Join-Path $env:ProgramFiles 'LibreHardwareMonitor\LibreHardwareMonitor.exe'),
        (Join-Path $root 'LibreHardwareMonitor\LibreHardwareMonitor.exe')
    )
    foreach ($k in $kandidati) {
        $f = Get-ChildItem $k -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($f) { return $f.FullName }
    }
    return $kandidati[0]
}

$adbExe    = Najdi-Adb
$lhmExe    = Najdi-Lhm
$appPkg    = 'cz.promptlab.telemetry'
$appCmp    = "$appPkg/.MainActivity"

function Log($m) {
    # s datem - bez nej se v logu nedaly odlisit dny (audit 2. 9. 2026)
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Write-Host $line
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

# Jedina instance. Zamerne mutex, NE hledani v prikazovych radkach -
# ten pristup chytal i cizi konzole, ktere nazev skriptu jen zminovaly.
$mutex = New-Object System.Threading.Mutex($false, 'Global\PROMPTLAB-Telemetry-Watchdog')
if (-not $Once -and -not $mutex.WaitOne(0)) {
    Log "Hlidac uz bezi - koncim."
    exit 0
}

# Vyber zarizeni. KLICOVE: kdyz bezi Android emulator, ma adb dve
# zarizeni a KAZDY prikaz skonci chybou "more than one device/emulator".
# Telefon proto adresujeme jmenovite pres -s a emulatory ignorujeme.
$script:adbSel = @()

function Resolve-Phone {
    if (-not (Test-Path $adbExe)) { $script:adbSel = @(); return $false }
    $devs = @()
    foreach ($l in (& $adbExe devices 2>$null)) {
        if ($l -match '^(\S+)\s+device\s*$') {
            $id = $Matches[1]
            if ($id -notmatch '^emulator-') { $devs += $id }
        }
    }
    if ($devs.Count -eq 0) { $script:adbSel = @(); return $false }
    if ($script:adbSel.Count -lt 2 -or $script:adbSel[1] -ne $devs[0]) {
        Log "Telefon vybran: $($devs[0])"
    }
    $script:adbSel = @('-s', $devs[0])
    return $true
}

function Phone-Connected { return (Resolve-Phone) }

function Ensure-Lhm {
    if (Get-Process LibreHardwareMonitor -ErrorAction SilentlyContinue) { return }
    # MUSI bezet se zvysenymi pravy, jinak neprecte teplotni cidla,
    # proto pres naplanovanou ulohu (ta ma RunLevel Highest).
    $task = 'PROMPTLAB-Telemetry-LHM'
    if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) {
        Start-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
        Log "LHM nebezel - spusten pres ulohu $task"
    } else {
        Start-Process -FilePath $lhmExe -ErrorAction SilentlyContinue
        Log "LHM nebezel - spusten primo (uloha chybi!)"
    }
    Start-Sleep -Seconds 2
}

# Telefon uz neni displej Windows, ale spacedesk si svuj virtualni displej
# drzi i po odpojeni klienta - kurzor by tam porad mohl spadnout.
function Ensure-CursorGuard {
    $g = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
         Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like "*-File*$root\cursorguard.ps1*" }
    if (-not $g) {
        Start-Process powershell -ArgumentList '-NoProfile','-WindowStyle','Hidden',
            '-ExecutionPolicy','Bypass','-File',(Join-Path $root 'cursorguard.ps1')
        Log "Hlidac kurzoru nebezel - spusten"
    }
}

# Sledovani generovani v ComfyUI (zapisuje comfy.json pro /comfy).
function Ensure-Comfy {
    $c = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
         Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like "*-File*$root\comfy.ps1*" }
    if (-not $c) {
        Start-Process powershell -ArgumentList '-NoProfile','-WindowStyle','Hidden',
            '-ExecutionPolicy','Bypass','-File',(Join-Path $root 'comfy.ps1')
        Log "Sledovani ComfyUI nebezelo - spusteno"
    }
}

# Limity Claude a Codexu (zapisuje limity.json pro /limits).
function Ensure-Limity {
    $c = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
         Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like "*-File*$root\limity.ps1*" }
    if (-not $c) {
        Start-Process powershell -ArgumentList '-NoProfile','-WindowStyle','Hidden',
            '-ExecutionPolicy','Bypass','-File',(Join-Path $root 'limity.ps1')
        Log "Sledovani limitu nebezelo - spusteno"
    }
}

function Ensure-Server {
    $s = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
         Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like "*-File*$serverPs1*" }
    if (-not $s) {
        Start-Process powershell -ArgumentList '-NoProfile','-WindowStyle','Hidden',
            '-ExecutionPolicy','Bypass','-File',$serverPs1
        Log "Server nebezel - spusten"
        Start-Sleep -Seconds 1
    }
}

# Presmerovani portu do telefonu. Po odpojeni/pripojeni kabelu nebo po
# probuzeni pocitace zanika, takze se musi obnovovat.
function Ensure-Reverse {
    if (-not (Phone-Connected)) { return $false }
    $list = & $adbExe @script:adbSel reverse --list 2>$null
    if ($list -notmatch "tcp:$Port tcp:$Port") {
        & $adbExe @script:adbSel reverse "tcp:$Port" "tcp:$Port" 2>$null | Out-Null
        Log "adb reverse tcp:$Port obnoveno"
    }
    return $true
}


# Dashboard ma byt v popredi telefonu. Kdyz neni, spustime ho.
# Kolik sekund necinnosti u pocitace znamena "nikdo se nediva".
# Musi souhlasit s SCREEN_OFF v dashboard.html.
$script:IdleOffSec = 300

function Get-PcIdle {
    try {
        $r = Invoke-WebRequest "http://localhost:$Port/state" -UseBasicParsing -TimeoutSec 3
        return [double](($r.Content | ConvertFrom-Json).idle)
    } catch { return -1 }
}

function Ensure-PhoneApp {
    if (-not (Phone-Connected)) { return }

    $pcIdle = Get-PcIdle

    # Kdyz telefon drima: injektaz vstupu MIUI blokuje, ale nase aktivita
    # ma setTurnScreenOn() - staci ji spustit a displej se rozsviti sam.
    # Delame to jen kdyz uzivatel skutecne sedi u pocitace, aby telefon
    # nesvitil zbytecne.
    $wake = & $adbExe @script:adbSel shell dumpsys power 2>$null | Select-String -Pattern 'mWakefulness=(\w+)' | Select-Object -First 1
    if ($wake -and $wake.Matches[0].Groups[1].Value -ne 'Awake') {
        # Telefon spi. Budime ho jen kdyz uzivatel skutecne sedi u pocitace.
        if ($pcIdle -ge 0 -and $pcIdle -lt 25) {
            & $adbExe @script:adbSel shell am start -n $appCmp 2>$null | Out-Null
            Log "Uzivatel se vratil (necinnost $pcIdle s) - budim telefon"
            Start-Sleep -Seconds 3
        }
        return
    }

    # KLICOVE: kdyz u pocitace nikdo neni, aplikaci NESPOUSTET.
    # Kazde spusteni projde onResume(), ktery displeji vrati sviceni -
    # hlidac by tim porad rusil zhasnuti, ktere si stranka vyzadala.
    if ($pcIdle -ge $script:IdleOffSec) {
        if (-not $script:idleQuietLogged) {
            Log "U pocitace nikdo neni (necinnost $pcIdle s) - nechavam telefon byt"
            $script:idleQuietLogged = $true
        }
        return
    }
    $script:idleQuietLogged = $false

    $focus = & $adbExe @script:adbSel shell dumpsys window 2>$null | Select-String -Pattern 'mCurrentFocus' | Select-Object -First 1
    if (-not $focus) { return }

    # Dashboard uz bezi - nic nedelat.
    if ($focus.Line -match [regex]::Escape($appPkg)) { return }

    # KLICOVE PRAVIDLO: obnovujeme JEN z domovske obrazovky nebo ze zamku.
    # Kdyz uzivatel neco dela (Nastaveni, jina aplikace), nesmime mu krast
    # popredi - drive to delalo to, ze si v telefonu nesel nic nastavit.
    $idle = $focus.Line -match 'com\.miui\.home|launcher|NexusLauncher|StatusBar|Keyguard|NotificationShade'
    if (-not $idle) {
        if (-not $script:userBusyLogged) {
            Log "Uzivatel neco dela v telefonu - dashboard neobnovuji"
            $script:userBusyLogged = $true
        }
        return
    }
    $script:userBusyLogged = $false

    # Spousti se VYHRADNE nativni aplikace PROMPTLAB.
    # Zadny prohlizec, zadna PWA - zadna zaloha pres prohlizec.
    & $adbExe @script:adbSel shell am start -n $appCmp 2>$null | Out-Null
    Log "Dashboard nebyl v popredi - spustena aplikace"
    Start-Sleep -Seconds 4
}

Log "=== Hlidac v2 nastartoval (interval ${IntervalSec}s) ==="

# --- RYCHLY START ---
# Telefon nahodime jako UPLNE PRVNI, jeste nez se ceka na LHM a server.
# Driv se cekalo 6 s na LHM a 3 s na server, a teprve pak prisel telefon -
# po prihlaseni to znamenalo skoro 10 s cerne obrazovky.
# Aplikace si stranku dotahne sama, az server nabehne (RetryClient v APK).
if (Phone-Connected) {
    & $adbExe @script:adbSel reverse "tcp:$Port" "tcp:$Port" 2>$null | Out-Null
    & $adbExe @script:adbSel shell am start -n $appCmp 2>$null | Out-Null
    Log "Rychly start: aplikace v telefonu spustena jako prvni"
} else {
    # Bez tohoto radku byl log po startu uplne ticho: $hadPhone zacina
    # na $false, takze se nikdy nevypsalo ani "Telefon odpojen" a nebylo
    # poznat, ze duvod cerneho telefonu je proste nepripojene USB.
    Log "TELEFON NEVIDIM pres USB (adb devices je prazdne) - zkontroluj kabel, port a povoleni ladeni v telefonu"
}

$lastTick   = Get-Date
$hadPhone   = $false
$noPhoneLog = Get-Date          # kdy se naposled pripomnelo chybejici USB

do {
    try {
        # Velka mezera mezi pruchody = pocitac spal.
        $now = Get-Date
        $gap = ($now - $lastTick).TotalSeconds
        $lastTick = $now
        if ($gap -gt ($IntervalSec + 45)) {
            Log "PROBUZENI: mezera $([int]$gap) s"
            Start-Sleep -Seconds 8       # nez se USB znovu vycisli
            if (Test-Path $adbExe) {
                & $adbExe @script:adbSel reverse --remove-all 2>$null | Out-Null
                & $adbExe @script:adbSel reverse "tcp:$Port" "tcp:$Port" 2>$null | Out-Null
                # Cerstve nacteni stranky: obnovi i zamek proti zhasnuti
                # displeje (Wake Lock se pri skryti dokumentu uvolnuje).
                # Spousti se VYHRADNE nativni aplikace. Zadny prohlizec.
                & $adbExe @script:adbSel shell am force-stop $appPkg 2>$null | Out-Null
                Start-Sleep -Seconds 2
                & $adbExe @script:adbSel shell am start -n $appCmp 2>$null | Out-Null
                Log "Aplikace v telefonu znovu spustena"
            }
        }

        Ensure-Lhm
        Ensure-Server
        Ensure-CursorGuard
        Ensure-Comfy
        Ensure-Limity

        $phone = Ensure-Reverse
        if ($phone -and -not $hadPhone) { Log "Telefon pripojen" }
        elseif (-not $phone -and $hadPhone) { Log "Telefon odpojen" }
        $hadPhone = $phone

        # Pripominka po 5 minutach, aby v logu bylo videt, ze hlidac zije
        # a jen mu chybi telefon - ne ze se sam nespustil.
        if ($phone) { $noPhoneLog = Get-Date }
        elseif (((Get-Date) - $noPhoneLog).TotalSeconds -ge 300) {
            $noPhoneLog = Get-Date
            Log "TELEFON PORAD NEVIDIM pres USB - hlidac bezi, ceka na pripojeni"
        }

        if ($phone) { Ensure-PhoneApp }
    }
    catch { Log "CHYBA: $($_.Exception.Message)" }

    if (-not $Once) { Start-Sleep -Seconds $IntervalSec }
} while (-not $Once)
