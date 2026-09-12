# ---------------------------------------------------------------
#  Sledovani generovani v ComfyUI.
#
#  Proc takhle a ne pres WebSocket:
#    ComfyUI posila zpravy "progress" i "progress_state" VYHRADNE
#    klientovi, ktery ulohu zadal (send_sync(..., server.client_id)).
#    Cizi posluchac je nikdy nedostane - overeno ve zdrojaku.
#    Zato launcher presmerovava vystup ComfyUI do logu, kde je tqdm
#    ukazatel vzorkovace, a z nej se procenta vycist daji.
#
#  Vysledek zapisuje do comfy.json, ktery serviruje server.ps1 na /comfy.
# ---------------------------------------------------------------
param(
    [int]$ComfyPort  = 8188,
    # Adresar, kam launcher ComfyUI presmerovava svuj vystup (je v nem tqdm
    # ukazatel vzorkovace). Kdyz neni zadany nebo neexistuje, ukazatel
    # generovani se proste neukazuje - nic jineho se nerozbije.
    [string]$LogDir  = $env:PROMPTLAB_COMFY_LOGDIR,
    [int]$IntervalMs = 1000
)

$ErrorActionPreference = 'SilentlyContinue'
$root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$outFile = Join-Path $root 'comfy.json'
$logFile = Join-Path $root 'watchdog.log'

function Log($m) {
    Add-Content -Path $logFile -Value ("{0}  [comfy] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding UTF8
}

# Jedina instance
$mutex = New-Object System.Threading.Mutex($false, 'Global\PROMPTLAB-Comfy-Watcher')
if (-not $mutex.WaitOne(0)) { exit 0 }

Log "sledovani spusteno (port $ComfyPort)"

function Write-State($obj) {
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $json = '{"running":' + $obj.running.ToString().ToLower() +
            ',"queue":'   + $obj.queue +
            ',"percent":' + $obj.percent.ToString('F0', $inv) +
            ',"step":'    + $obj.step +
            ',"steps":'   + $obj.steps +
            ',"eta":"'    + $obj.eta + '"' +
            ',"elapsed":' + $obj.elapsed +
            ',"tiles":'   + $obj.tiles + '}'
    Set-Content -Path $outFile -Value $json -Encoding UTF8
}

# Nejnovejsi log ComfyUI. Pozor: u otevreneho souboru jsou velikost i
# datum v adresari zastarale, proto se rovna podle nazvu (obsahuje datum).
function Get-NewestLog {
    if (-not (Test-Path $LogDir)) { return $null }
    Get-ChildItem $LogDir -Filter 'comfyui_*.log' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
}

# Precte konec logu i kdyz do nej ComfyUI zrovna pise.
function Read-Tail($path, $bytes = 6000) {
    try {
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try {
            $len = $fs.Length
            if ($len -gt $bytes) { [void]$fs.Seek($len - $bytes, 'Begin') }
            $buf = New-Object byte[] ([int][Math]::Min($bytes, $len))
            [void]$fs.Read($buf, 0, $buf.Length)
            return [System.Text.Encoding]::UTF8.GetString($buf)
        } finally { $fs.Close() }
    } catch { return $null }
}

$startedAt = $null
$lastPct   = -1
$lastPctAt = [datetime]::MinValue

while ($true) {
    $st = [pscustomobject]@{
        running = $false; queue = 0; percent = 0.0
        step = 0; steps = 0; eta = ''; elapsed = 0; tiles = 0
    }

    # 1) bezi neco? -> HTTP, funguje bez ohledu na to, kdo ulohu zadal
    try {
        $r = Invoke-WebRequest "http://127.0.0.1:$ComfyPort/prompt" -UseBasicParsing -TimeoutSec 3
        $q = ($r.Content | ConvertFrom-Json).exec_info.queue_remaining
        $st.queue   = [int]$q
        $st.running = ($q -gt 0)
    } catch { $st.running = $false; $st.queue = 0 }

    if ($st.running) {
        if (-not $startedAt) { $startedAt = Get-Date }
        $st.elapsed = [int]((Get-Date) - $startedAt).TotalSeconds

        # 2) procenta z tqdm.
        #    Prednostne primo z ComfyUI (/internal/logs/raw) - nezavisi to
        #    na tom, jak byl ComfyUI spusten, a neresi se zamceny soubor.
        #    Log od launcheru je jen zaloha.
        $tail = $null
        try {
            $lr = Invoke-WebRequest "http://127.0.0.1:$ComfyPort/internal/logs/raw" -UseBasicParsing -TimeoutSec 3
            $entries = ($lr.Content | ConvertFrom-Json).entries
            if ($entries) { $tail = ($entries | ForEach-Object { $_.m }) -join '' }
        } catch { }

        if (-not $tail) {
            $lf = Get-NewestLog
            if ($lf) { $tail = Read-Tail $lf.FullName }
        }

        if ($tail) {
            # tqdm prepisuje tentyz radek NAVRATEM VOZIKU, ne odradkovanim.
            # Bez prevodu by kotva ^ chytila jen prvni aktualizaci (0%).
            $tail = $tail -replace "`r", "`n"

            # Bereme JEN to, co prislo po poslednim "got prompt" - jinak by
            # se cetl dobehly ukazatel z predchozi ulohy a drzel 100 %.
            $gp = $tail.LastIndexOf('got prompt')
            if ($gp -ge 0) { $tail = $tail.Substring($gp) }

            $m = [regex]::Matches($tail, '(?m)^.*?(\d{1,3})%\|[^|]*\|\s*(\d+)/(\d+)\s*\[([\d:]+)<([\d:?]+)')
            if ($m.Count -gt 0) {
                $last  = $m[$m.Count - 1]
                $pct   = [double]$last.Groups[1].Value
                $steps = [int]$last.Groups[3].Value

                # Jednokrokove ukazatele (steps <= 1) se pri dlazdicovem
                # zvetsovani opakuji pro KAZDY dilek a kazdy dobehne na 100 %.
                # Procenta z nich nevypovidaji o celkovem prubehu - misto
                # falesne stovky hlasime neurcity stav a pocitame dilky.
                if ($steps -le 1) {
                    $st.percent = -1
                    $st.step    = 0
                    $st.steps   = 0
                    $st.eta     = ''
                    $st.tiles   = ([regex]::Matches($tail, '(?m)100%\|[^|]*\|\s*1/1')).Count
                } else {
                    $st.percent = $pct
                    $st.step    = [int]$last.Groups[2].Value
                    $st.steps   = $steps
                    $st.eta     = $last.Groups[5].Value
                    $st.tiles   = 0
                }
            } else {
                # uloha bezi, ale zadny vzorkovac zatim nehlasi (nacitani modelu,
                # dekodovani, ukladani) -> neurcity stav, ne nula
                $st.percent = -1
            }
        }
    } else {
        $startedAt = $null; $lastPct = -1
    }

    Write-State $st
    Start-Sleep -Milliseconds $IntervalMs
}
