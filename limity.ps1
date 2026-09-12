# ---------------------------------------------------------------
#  Limity Claude a Codexu pro dashboard v telefonu.
#
#  Zapisuje limity.json, ktery server.ps1 serviruje na /limits.
#
#  ODKUD SE BEROU (poradi je dulezite, viz README "Limity"):
#
#  Claude
#   1. ~/.claude/status/_limity-claude.json - zapisuje ho statusline.py
#      z JSONu, ktery Claude Code posila status line (rate_limits.five_hour
#      / seven_day: used_percentage, resets_at). Je to ZADARMO a ZIVE:
#      obnovuje ho kazda bezici session pri kazde odpovedi.
#   2. Zaloha: `claude --permission-mode default -p /usage`, kdyz je soubor
#      starsi nez $ClaudeFallbackMin minut a uzivatel je u pocitace.
#      Stoji to ~4 s a zaklada to malou session (transkript + status soubor
#      z hooku), proto se to nedela casteji nez 1x za $ClaudeFallbackMin
#      minut a vubec ne, kdyz u pocitace nikdo neni (dashboard je stejne
#      v klidovem rezimu a limity neukazuje).
#      POZOR: `-p /usage` BEZ uvozovek a --permission-mode default je
#      povinny (viz helper session, limity.sh).
#
#  Codex
#   limity-codex.py --json: zive pres `codex app-server`
#   (account/rateLimits/read - zdarma, bez dotazu na model), zaloha ze
#   souboru relaci. Trva ~1 s, proto se pta kazdy cyklus.
# ---------------------------------------------------------------
param(
    [int]$IntervalSec       = 30,
    [int]$ClaudeFallbackMin = 5,
    [switch]$Once,
    [switch]$ForceUsage      # diagnostika: vynutit zalozni `claude -p /usage`
)

$ErrorActionPreference = 'SilentlyContinue'
$root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$outFile    = Join-Path $root 'limity.json'
$logFile    = Join-Path $root 'watchdog.log'
$codexPy    = Join-Path $root 'limity-codex.py'
$claudeFile = Join-Path $env:USERPROFILE '.claude\status\_limity-claude.json'
$inv        = [System.Globalization.CultureInfo]::InvariantCulture

# claude.exe (Bun) pise UTF-8; bez tohoto by "·" ve vystupu prislo rozbite.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Log($m) {
    Add-Content -Path $logFile -Value ("{0}  [limity] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding UTF8
}

# Jedina instance (mutex, ne hledani v prikazovych radkach - viz README)
$mutex = New-Object System.Threading.Mutex($false, 'Global\PROMPTLAB-Limity')
if (-not $Once -and -not $mutex.WaitOne(0)) { exit 0 }

# Necinnost uzivatele - stejny princip jako v server.ps1. Kdyz u pocitace
# nikdo neni, zalozni dotaz na Clauda se nespousti.
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class IdleLim {
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
    [DllImport("kernel32.dll")] public static extern uint GetTickCount();
    public static double Seconds() {
        LASTINPUTINFO li = new LASTINPUTINFO();
        li.cbSize = (uint)Marshal.SizeOf(li);
        if (!GetLastInputInfo(ref li)) return 0;
        return (GetTickCount() - li.dwTime) / 1000.0;
    }
}
'@ -ErrorAction SilentlyContinue

function Now-Epoch { return [int][Math]::Floor(([DateTimeOffset]::UtcNow).ToUnixTimeSeconds()) }

# ---------------------------------------------------------------- Claude

# Klice odpovidaji status line JSONu (five_hour, seven_day, spend_limit...).
# Popisky si dava stranka, tady jen klice, procenta a cas obnovy.
function Read-ClaudeStatusline {
    if (-not (Test-Path $claudeFile)) { return $null }
    try {
        $raw = Get-Content $claudeFile -Raw -Encoding UTF8
        $d = $raw | ConvertFrom-Json
    } catch { return $null }
    if (-not $d -or -not $d.rate_limits) { return $null }
    $items = @()
    foreach ($p in $d.rate_limits.PSObject.Properties) {
        $w = $p.Value
        if ($null -eq $w -or $null -eq $w.used_percentage) { continue }
        $items += [ordered]@{
            key      = $p.Name
            pct      = [int][Math]::Round([double]$w.used_percentage)
            resetsAt = $(if ($w.resets_at) { [long]$w.resets_at } else { $null })
        }
    }
    if ($items.Count -eq 0) { return $null }
    # five_hour a seven_day napred, ostatni za nimi
    $poradi = @{ five_hour = 0; seven_day = 1 }
    $items = @($items | Sort-Object { if ($poradi.ContainsKey($_.key)) { $poradi[$_.key] } else { 9 } })
    return [ordered]@{
        source = 'statusline'
        at     = [long]$d.at
        model  = [string]$d.model
        items  = $items
    }
}

# "Sep 9, 10:59am" nebo "Sep 9, 11am" (Europe/Prague = mistni cas) -> epocha
function Parse-UsageReset([string]$txt) {
    $t = ($txt -replace '\(.*\)', '').Trim()
    foreach ($f in @('MMM d, h:mmtt', 'MMM d, htt', 'MMM d, h:mm tt', 'MMM d, h tt')) {
        try {
            # rok v textu neni - ParseExact dosadi letosni
            $dt = [DateTime]::SpecifyKind([DateTime]::ParseExact($t, $f, $inv), [DateTimeKind]::Local)
            # obnova je vzdy v budoucnu; kolem Silvestra by chybel rok
            if ($dt -lt (Get-Date).AddDays(-1)) { $dt = $dt.AddYears(1) }
            return ([DateTimeOffset]$dt).ToUnixTimeSeconds()
        } catch { }
    }
    return $null
}

function Read-ClaudeUsage {
    $tmp = Join-Path $env:TEMP 'promptlab-limity-usage.txt'
    Remove-Item $tmp -ErrorAction SilentlyContinue
    # cmd presmeruje SUROVE bajty (UTF-8) do souboru; cteme je pak spravne.
    $p = Start-Process -FilePath 'cmd.exe' `
        -ArgumentList ('/c claude --permission-mode default -p /usage > "{0}" 2>&1' -f $tmp) `
        -WorkingDirectory $env:USERPROFILE -WindowStyle Hidden -PassThru
    if (-not $p.WaitForExit(60000)) {
        # vlastni proces, ktery jsme sami spustili - smi se ukoncit (i s claude.exe pod nim)
        & taskkill.exe /PID $p.Id /T /F | Out-Null
        Log "claude -p /usage neodpovedel do 60 s - ukoncen"
        return $null
    }
    if (-not (Test-Path $tmp)) { return $null }
    $lines = Get-Content $tmp -Encoding UTF8
    $items = @()
    foreach ($l in $lines) {
        # "Current week (all models): 22% used · resets Sep 9, 10:59am (Europe/Prague)"
        if ($l -match '^\s*(.+?):\s+(\d+)%\s+used\b.*?\bresets\s+(.+)$') {
            $popis = $Matches[1]; $pct = [int]$Matches[2]; $kdy = $Matches[3]
            $key = $null
            if ($popis -match '^Current session') { $key = 'five_hour' }
            elseif ($popis -match '^Current week \(all models\)') { $key = 'seven_day' }
            elseif ($popis -match '^Current week \((.+)\)') { $key = 'seven_day_' + ($Matches[1].ToLower() -replace '[^a-z0-9]+', '_') }
            else { $key = ($popis.ToLower() -replace '[^a-z0-9]+', '_') }
            $items += [ordered]@{ key = $key; pct = $pct; resetsAt = (Parse-UsageReset $kdy) }
        }
    }
    if ($items.Count -eq 0) { Log "claude -p /usage nevratil zadne limity"; return $null }
    return [ordered]@{ source = 'usage'; at = (Now-Epoch); model = ''; items = $items }
}

# ----------------------------------------------------------------- Codex

function Read-Codex {
    if (-not (Test-Path $codexPy)) { return $null }
    $tmp = Join-Path $env:TEMP 'promptlab-limity-codex.txt'
    Remove-Item $tmp -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath 'python' -ArgumentList ('"{0}" --json' -f $codexPy) `
        -WorkingDirectory $root -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $tmp
    if (-not $p.WaitForExit(40000)) {
        & taskkill.exe /PID $p.Id /T /F | Out-Null
        Log "limity-codex.py neodpovedel do 40 s - ukoncen"
        return $null
    }
    try {
        $d = (Get-Content $tmp -Raw -Encoding UTF8) | ConvertFrom-Json
    } catch { return $null }
    if (-not $d -or -not $d.source) { return $null }
    $items = @()
    foreach ($w in $d.windows) {
        $items += [ordered]@{
            key      = [string]$w.key
            pct      = [int]$w.pct
            resetsAt = $(if ($w.resetsAt) { [long]$w.resetsAt } else { $null })
            stale    = [bool]$w.stale
        }
    }
    return [ordered]@{ source = [string]$d.source; at = [long]$d.at; items = $items }
}

# ----------------------------------------------------------------- smycka

$script:lastFallback = 0
$script:lastClaudeSource = ''
$script:lastCodexSource  = ''
$script:lastClaude = $null

Log "sledovani limitu spusteno (kazdych $IntervalSec s)"

while ($true) {
    $now = Now-Epoch

    # --- Claude ---
    $claude = Read-ClaudeStatusline
    $stari  = if ($claude) { $now - [long]$claude.at } else { [int]::MaxValue }
    $idle   = 0.0
    try { $idle = [IdleLim]::Seconds() } catch { }
    if ($ForceUsage -or ($stari -gt ($ClaudeFallbackMin * 60) -and $idle -lt 120 -and
        ($now - $script:lastFallback) -gt ($ClaudeFallbackMin * 60))) {
        $script:lastFallback = $now
        $u = Read-ClaudeUsage
        if ($u) { $claude = $u; $script:lastClaude = $u }
    }
    # Kdyz statusline soubor chybi a zaloha se ted nespoustela, drzime
    # posledni zalozni vysledek - lepsi stary udaj s casem nez nic.
    if (-not $claude -and $script:lastClaude) { $claude = $script:lastClaude }

    # --- Codex ---
    $codex = Read-Codex

    # --- zapis ---
    $obj = [ordered]@{
        checkedAt = $now
        claude    = $claude
        codex     = $codex
    }
    try {
        $json = $obj | ConvertTo-Json -Depth 6 -Compress
        Set-Content -Path $outFile -Value $json -Encoding UTF8
    } catch { Log "zapis limity.json selhal: $_" }

    $cs = if ($claude) { $claude.source } else { '-' }
    $xs = if ($codex)  { $codex.source }  else { '-' }
    if ($cs -ne $script:lastClaudeSource -or $xs -ne $script:lastCodexSource) {
        Log "zdroje: claude=$cs codex=$xs"
        $script:lastClaudeSource = $cs; $script:lastCodexSource = $xs
    }

    if ($Once) { break }
    Start-Sleep -Seconds $IntervalSec
}
