# ---------------------------------------------------------------
#  Hlidac kurzoru.
#  Displej telefonu je pasivni dashboard - kurzor tam nema co delat.
#  Kdykoli kurzor vstoupi do jeho hranic (mysi pres okraj, dotykem na
#  telefonu, nebo pri probuzeni pocitace), okamzite ho vrati zpet na
#  posledni bezpecnou pozici mimo nej.
#  Diky tomu uz nemuze "zmizet".
# ---------------------------------------------------------------
param(
    [int]$PollMs = 120
)

$ErrorActionPreference = 'SilentlyContinue'
$root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$logFile = Join-Path $root 'watchdog.log'

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class CG {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion; public short dmDriverVersion; public short dmSize;
        public short dmDriverExtra; public int dmFields;
        public int dmPositionX; public int dmPositionY;
        public int dmDisplayOrientation; public int dmDisplayFixedOutput;
        public short dmColor; public short dmDuplex; public short dmYResolution;
        public short dmTTOption; public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels; public int dmBitsPerPel; public int dmPelsWidth;
        public int dmPelsHeight; public int dmDisplayFlags; public int dmDisplayFrequency;
        public int dmICMMethod; public int dmICMIntent; public int dmMediaType;
        public int dmDitherType; public int dmReserved1; public int dmReserved2;
        public int dmPanningWidth; public int dmPanningHeight;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]  public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    public static extern bool EnumDisplayDevices(string d, uint i, ref DISPLAY_DEVICE dd, uint f);
    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    public static extern bool EnumDisplaySettings(string d, int m, ref DEVMODE dm);
}
'@

function Log($m) {
    Add-Content -Path $logFile -Value ("{0}  [kurzor] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding UTF8
}

function Get-SpacedeskBounds {
    for ($i = 0; $i -lt 32; $i++) {
        $dd = New-Object CG+DISPLAY_DEVICE
        $dd.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($dd)
        if (-not [CG]::EnumDisplayDevices([NullString]::Value, $i, [ref]$dd, 0)) { break }
        if (($dd.StateFlags -band 0x1) -eq 0) { continue }
        if ($dd.DeviceString -notmatch 'spacedesk') { continue }

        $dm = New-Object CG+DEVMODE
        $dm.dmDeviceName = ""; $dm.dmFormName = ""
        $dm.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($dm)
        if ([CG]::EnumDisplaySettings($dd.DeviceName, -1, [ref]$dm)) {
            return @{
                X1 = $dm.dmPositionX; Y1 = $dm.dmPositionY
                X2 = $dm.dmPositionX + $dm.dmPelsWidth
                Y2 = $dm.dmPositionY + $dm.dmPelsHeight
            }
        }
    }
    return $null
}

# NUTNE: bez tohoto vraci GetCursorPos virtualizovane souradnice a
# porovnani s fyzickymi hranicemi displeje by bylo posunute.
[void][CG]::SetProcessDPIAware()

Add-Type -AssemblyName System.Windows.Forms
$primary = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$safeX = $primary.X + [int]($primary.Width / 2)
$safeY = $primary.Y + [int]($primary.Height / 2)

$bounds       = Get-SpacedeskBounds
$lastRefresh  = Get-Date
$bounced      = 0

Log "start (interval ${PollMs}ms), hlidane pasmo: $(if($bounds){"$($bounds.X1),$($bounds.Y1) - $($bounds.X2),$($bounds.Y2)"}else{'zadne'})"

while ($true) {
    # hranice displeje se meni (odpojeni/pripojeni telefonu) - obcas obnovit
    if (((Get-Date) - $lastRefresh).TotalSeconds -ge 10) {
        $bounds = Get-SpacedeskBounds
        $lastRefresh = Get-Date
    }

    if ($bounds) {
        $p = New-Object CG+POINT
        if ([CG]::GetCursorPos([ref]$p)) {
            $inside = ($p.X -ge $bounds.X1) -and ($p.X -lt $bounds.X2) -and
                      ($p.Y -ge $bounds.Y1) -and ($p.Y -lt $bounds.Y2)
            if ($inside) {
                [void][CG]::SetCursorPos($safeX, $safeY)
                $bounced++
                if ($bounced -eq 1 -or $bounced % 50 -eq 0) {
                    Log "kurzor vracen z displeje telefonu (celkem $bounced x)"
                }
            } else {
                # zapamatuj si bezpecnou pozici, ale jen na hlavnim displeji
                if ($p.X -ge $primary.X -and $p.X -lt ($primary.X + $primary.Width) -and
                    $p.Y -ge $primary.Y -and $p.Y -lt ($primary.Y + $primary.Height)) {
                    $safeX = $p.X; $safeY = $p.Y
                }
            }
        }
    }

    Start-Sleep -Milliseconds $PollMs
}
