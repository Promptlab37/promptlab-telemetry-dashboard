# ---------------------------------------------------------------
#  Lokalni server pro dashboard.
#    /       -> dashboard.html
#    /api    -> proxy na LibreHardwareMonitor  (http://localhost:8085/data.json)
#    /limits -> limity Claude a Codexu (limity.json od limity.ps1)
#  Proxy je tu proto, aby stranka i data mely stejny origin (zadne CORS).
# ---------------------------------------------------------------
param(
    [int]$Port    = 8099,
    [int]$LhmPort = 8085
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$page = Join-Path $root 'dashboard.html'

if (-not (Test-Path $page)) { throw "Nenalezen dashboard.html v $root" }

# Detekce necinnosti uzivatele u pocitace. Spolehlivejsi nez hledat
# bezici sporic - reaguje na to, ze uzivatel odesel, a to je presne
# okamzik, kdy ma dashboard prejit do klidoveho rezimu.
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Idle {
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
    [DllImport("kernel32.dll")] public static extern uint GetTickCount();
    [DllImport("user32.dll")]
    public static extern bool SystemParametersInfo(uint a, uint b, ref bool c, uint d);

    public static double Seconds() {
        LASTINPUTINFO li = new LASTINPUTINFO();
        li.cbSize = (uint)Marshal.SizeOf(li);
        if (!GetLastInputInfo(ref li)) return 0;
        return (GetTickCount() - li.dwTime) / 1000.0;
    }
    public static bool ScreenSaverRunning() {
        bool on = false;
        SystemParametersInfo(0x0072, 0, ref on, 0);   // SPI_GETSCREENSAVERRUNNING
        return on;
    }
}
'@ -ErrorAction SilentlyContinue

# Stav pro detekci probuzeni pocitace (viz /state nize).
$script:lastTick = 0
$script:resumeAt = $null

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Dashboard server bezi na http://localhost:$Port/  (data z LHM na portu $LhmPort)"

$wc = New-Object System.Net.WebClient
$wc.Encoding = [System.Text.Encoding]::UTF8

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $res = $ctx.Response
        $path = $req.Url.AbsolutePath

        try {
            if ($path -eq '/api') {
                # proxy na LHM
                try {
                    $rq = [System.Net.HttpWebRequest]::Create("http://localhost:$LhmPort/data.json")
                    $rq.Timeout          = 2000
                    $rq.ReadWriteTimeout = 2000
                    $rp = $rq.GetResponse()
                    $sr = New-Object System.IO.StreamReader($rp.GetResponseStream(), [System.Text.Encoding]::UTF8)
                    $json = $sr.ReadToEnd()
                    $sr.Close(); $rp.Close()
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $res.ContentType = 'application/json; charset=utf-8'
                    $res.StatusCode  = 200
                } catch {
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"error":"LHM nedostupny"}')
                    $res.ContentType = 'application/json; charset=utf-8'
                    $res.StatusCode  = 503
                }
            }
            elseif ($path -eq '/manifest.json') {
                # Diky manifestu jde stranku "Pridat na plochu" a spustit
                # jako PWA na celou obrazovku, bez adresniho radku.
                $json = '{"name":"PROMPTLAB Telemetry","short_name":"Telemetry",' +
                        '"start_url":"/","scope":"/","display":"fullscreen",' +
                        '"orientation":"landscape","background_color":"#000000",' +
                        '"theme_color":"#000000",' +
                        '"icons":[{"src":"/icon.svg","sizes":"any","type":"image/svg+xml","purpose":"any"}]}'
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $res.ContentType = 'application/manifest+json; charset=utf-8'
                $res.StatusCode  = 200
            }
            elseif ($path -eq '/icon.svg') {
                $svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 192 192">' +
                       '<rect width="192" height="192" fill="#000"/>' +
                       '<circle cx="96" cy="96" r="62" fill="none" stroke="#3987e5" stroke-width="13"' +
                       ' stroke-dasharray="292 390" transform="rotate(135 96 96)" stroke-linecap="round"/>' +
                       '<rect x="88" y="34" width="16" height="34" rx="3" fill="#d95926"/></svg>'
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($svg)
                $res.ContentType = 'image/svg+xml; charset=utf-8'
                $res.StatusCode  = 200
            }
            elseif ($path -eq '/log') {
                # Ladici kanal ze stranky v telefonu do logu na pocitaci.
                # Bez nej neni videt, co se na telefonu deje.
                $msg = $req.QueryString['m']
                if ($msg) {
                    Add-Content -Path (Join-Path $root 'watchdog.log') `
                        -Value ("{0}  [telefon] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) `
                        -Encoding UTF8
                }
                $bytes = [System.Text.Encoding]::UTF8.GetBytes('ok')
                $res.ContentType = 'text/plain; charset=utf-8'
                $res.StatusCode  = 200
            }
            elseif ($path -eq '/comfy') {
                # Stav generovani v ComfyUI - zapisuje ho comfy.ps1
                $cf = Join-Path $root 'comfy.json'
                if (Test-Path $cf) {
                    $json = (Get-Content $cf -Raw -ErrorAction SilentlyContinue).Trim()
                    if (-not $json) { $json = '{"running":false}' }
                } else {
                    $json = '{"running":false}'
                }
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.StatusCode  = 200
            }
            elseif ($path -eq '/limits') {
                # Limity Claude a Codexu - zapisuje je limity.ps1
                $lf = Join-Path $root 'limity.json'
                if (Test-Path $lf) {
                    $json = (Get-Content $lf -Raw -ErrorAction SilentlyContinue).Trim()
                    if (-not $json) { $json = '{"claude":null,"codex":null}' }
                } else {
                    $json = '{"claude":null,"codex":null}'
                }
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.StatusCode  = 200
            }
            elseif ($path -eq '/state') {
                $idle = 0.0; $ss = $false
                try { $idle = [Idle]::Seconds() }            catch { }
                try { $ss   = [Idle]::ScreenSaverRunning() }  catch { }

                # PROBUZENI POCITACE.
                # Dotazy chodi z telefonu kazde 2 s. Kdyz mezi dvema dotazy
                # skoci systemovy citac o vic nez minutu, pocitac spal.
                # Po probuzeni je GetLastInputInfo ZASTARALA: zadani hesla na
                # zamykaci obrazovce se do uzivatelske relace nepocita, takze
                # by necinnost hlasila celou delku spanku (mereno 18978 s) a
                # hlidac by telefon nechal spat jako "u pocitace nikdo neni".
                # Po probuzeni proto povazujeme uzivatele za pritomneho.
                try {
                    $tick  = [double][Idle]::GetTickCount()
                    $delta = $tick - [double]$script:lastTick
                    if ($script:lastTick -gt 0 -and $delta -gt 60000) {
                        $script:resumeAt = Get-Date
                    }
                    $script:lastTick = $tick
                } catch { }

                if ($script:resumeAt -and
                    ((Get-Date) - $script:resumeAt).TotalSeconds -lt 180) {
                    $idle = 0.0
                }
                # POZOR: formatovat invariantne - ceska desetinna carka by
                # vyrobila neplatny JSON ({"idle":0,0}).
                # Skutecny limit sporice ctem z registru, aby se prah na
                # telefonu prizpusobil sam, kdyz ho uzivatel ve Windows zmeni.
                $ssTimeout = 0; $ssActive = 0
                try {
                    $k = 'HKCU:\Control Panel\Desktop'
                    $ssTimeout = [int](Get-ItemProperty $k -Name ScreenSaveTimeOut -ErrorAction SilentlyContinue).ScreenSaveTimeOut
                    $ssActive  = [int](Get-ItemProperty $k -Name ScreenSaveActive  -ErrorAction SilentlyContinue).ScreenSaveActive
                } catch { }

                $inv = [System.Globalization.CultureInfo]::InvariantCulture
                $json = '{"idle":' + $idle.ToString('F1', $inv) +
                        ',"screensaver":' + $ss.ToString().ToLower() +
                        ',"ssTimeout":' + $ssTimeout +
                        ',"ssActive":' + $ssActive + '}'
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.StatusCode  = 200
            }
            elseif ($path -eq '/' -or $path -eq '/index.html' -or $path -eq '/dashboard.html') {
                $html  = Get-Content $page -Raw -Encoding UTF8
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
                $res.ContentType = 'text/html; charset=utf-8'
                $res.StatusCode  = 200
            }
            else {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes('404')
                $res.ContentType = 'text/plain; charset=utf-8'
                $res.StatusCode  = 404
            }

            $res.Headers.Add('Cache-Control','no-store')
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
        }
        catch { }
        finally { try { $res.OutputStream.Close() } catch { } }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
}
