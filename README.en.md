[Čeština](README.md) · **English**

# PROMPTLAB · System Telemetry

**An old phone as a permanent instrument panel for your computer.** Temperatures,
load, memory and the remaining limits of your AI tools — in big numbers, readable
across the whole desk, with no cloud and no account. The phone hangs on USB, the
page runs inside it, the computer only sends the data.

![Dashboard on the phone](docs/dashboard.png)

> **Note on language:** the dashboard UI itself is in Czech. Everything in this
> README is translated, but the numbers and status words you will see on the
> phone (`V normě` = normal, `Zvýšená` = elevated, `Vysoká` = high,
> `Kritická` = critical) stay Czech unless you edit `dashboard.html`.

---

## What it does

- **CPU/GPU temperature and load** on two large gauges, always with a written
  status (Normal / Elevated / High / Critical) — never colour alone.
- **System memory and VRAM**, including free space and a peak marker.
- **Remaining Claude Code and Codex limits** (optional, see below).
- **ComfyUI generation progress** (optional) — only appears while something is
  actually being generated.
- **Calm mode** when you walk away from the computer: the panels step back,
  a clock and two large numbers remain, and the image drifts slowly for the
  sake of the OLED.
- **Survives the computer going to sleep**: the page runs in the phone, so when
  the data stops it switches itself to a "System asleep" screen and plays the
  boot sequence again when you return.
- **Turns the display on** when you come back to the computer — a browser cannot
  do that, which is why there is a tiny app of its own (one WebView, two Java
  files).

The whole thing is one HTML page with no library at all, a few PowerShell
scripts and an APK a few dozen kB in size. No build system, no dependencies,
no sign-up.

---

## How it works

```
LibreHardwareMonitor (as admin)  →  reads sensors, HTTP on port 8085
server.ps1                       →  port 8099: page + /api + /state + /limits
limity.ps1                       →  Claude and Codex limits  → limity.json
comfy.ps1                        →  generation progress      → comfy.json
adb reverse tcp:8099             →  the phone sees the PC as its own localhost
PROMPTLAB app (WebView)          →  renders the dashboard natively, fullscreen
watchdog.ps1                     →  watches all of the above and wakes the phone
```

Two decisions behind it:

- **The page runs in the phone, not on the PC.** That is what lets it survive
  the computer going to sleep: when the data stops arriving, it switches over
  by itself and waits for the return.
- **A custom app instead of a browser.** Chrome will not go fullscreen without
  a user gesture (and you cannot trigger that gesture through `adb`), and a page
  in a browser cannot turn the display on. An Activity can do both, without any
  special permissions.

---

## What you need

| | |
|---|---|
| **Computer** | Windows 10/11, PowerShell 5.1 (ships with the system) |
| **Sensors** | [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) — `winget install LibreHardwareMonitor.LibreHardwareMonitor` |
| **Phone** | Android 7+ (API 24), developer options and USB debugging enabled |
| **Tools** | `adb` from [platform-tools](https://developer.android.com/tools/releases/platform-tools) |
| **Building the app** | Android SDK build-tools 34 + JDK (whatever Android Studio installs is enough) — only if you want to build the APK yourself |
| **Tests** | Node.js (for `tests/` only) |

Tested on a Xiaomi 11T Pro (AMOLED, 6.67"), but nothing in the code is tied to
that model. The page is designed for a 2400 × 1080 area and rescales itself.

---

## Installation

**1. LibreHardwareMonitor.** Install it, run it **as administrator** (without
that it will not read the temperature sensors) and under
`Options → Remote Web Server` enable the server on port **8085**. Verify it in
a browser: `http://localhost:8085/data.json`.

**2. Download this repository** anywhere, for example `C:\telemetry`.

**3. Connect the phone over USB**, confirm debugging on it and verify:

```powershell
adb devices          # exactly one device must show up in state "device"
```

**4. Install the app on the phone.** Either build the APK:

```powershell
.\app\build.ps1      # aapt2 + javac + d8 + apksigner, no Gradle
```

…or try the dashboard in the phone's browser first (`adb reverse tcp:8099
tcp:8099` and `http://localhost:8099` in Chrome) — it just will not be
fullscreen and will not wake itself.

> Xiaomi/MIUI blocks the **first** install over USB
> (`INSTALL_FAILED_USER_RESTRICTED`). Either enable "Install via USB" in
> developer options, or install the APK once by hand from the phone's file
> manager. Later updates go through with `adb install -r`.

**5. Start the watchdog:**

```powershell
.\watchdog.ps1
```

The watchdog starts `server.ps1` itself, restores `adb reverse`, brings the app
to the foreground on the phone and keeps it all running. You can also open the
dashboard on the PC: `http://localhost:8099`.

**6. Automatic start (optional).** This exact pair of tasks works well:

```powershell
# 1) LibreHardwareMonitor - needs elevation, otherwise there are no temperatures
$lhm = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\LibreHardwareMonitor.LibreHardwareMonitor_*\LibreHardwareMonitor.exe").FullName
Register-ScheduledTask -TaskName 'PROMPTLAB-Telemetry-LHM' `
  -Trigger (New-ScheduledTaskTrigger -AtLogOn) `
  -Action  (New-ScheduledTaskAction -Execute $lhm) `
  -Principal (New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest)

# 2) Watchdog - ordinary rights are enough
Register-ScheduledTask -TaskName 'PROMPTLAB-Telemetry-Watchdog' `
  -Trigger (New-ScheduledTaskTrigger -AtLogOn) `
  -Action  (New-ScheduledTaskAction -Execute 'powershell.exe' `
             -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PWD\watchdog.ps1`"")
```

The watchdog also benefits from a second trigger "on wake from sleep" (Task
Scheduler → on event, log `System`, source `Kernel-Power`, ID 107).
`START-hlidac.cmd` and `STOP-hlidac.cmd` are manual switches for these tasks.

---

## Configuration

Nothing is configured in files — everything is either a script parameter or an
environment variable, so the repository is usable straight after cloning.

| Script | Parameters (defaults) |
|---|---|
| `server.ps1` | `-Port 8099`, `-LhmPort 8085` |
| `watchdog.ps1` | `-IntervalSec 10`, `-Port 8099`, `-AdbExe`, `-LhmExe`, `-Once` |
| `limity.ps1` | `-IntervalSec 30`, `-ClaudeFallbackMin 5`, `-Once`, `-ForceUsage` |
| `comfy.ps1` | `-ComfyPort 8188`, `-LogDir`, `-IntervalMs 1000` |

| Environment variable | Purpose |
|---|---|
| `ANDROID_HOME` / `ANDROID_SDK_ROOT` | where the Android SDK is (otherwise `%LOCALAPPDATA%\Android\Sdk`) |
| `JAVA_HOME` | JDK for building the APK (otherwise the JBR from Android Studio) |
| `PROMPTLAB_ADB` / `PROMPTLAB_LHM` | direct path to `adb.exe` / `LibreHardwareMonitor.exe` |
| `PROMPTLAB_COMFY_LOGDIR` | directory with the ComfyUI launcher logs |
| `CODEX_SESSIONS` / `CODEX_EXE_GLOB` | where `limity-codex.py` should look for Codex |

The dashboard's behaviour thresholds (when calm mode starts, when the screen
goes off) are at the top of `dashboard.html` as `IDLE_ENTER` and `SCREEN_OFF`.
The idle threshold also adapts to the actual Windows screensaver limit.

---

## Claude Code and Codex limits (optional)

The bottom row of the dashboard shows how much is left in each limit window —
a large number, a written status (Free / Running low / On the edge / Exhausted),
a bar that drains like fuel, and the reset time. Without these tools the row
simply stays empty and the rest of the dashboard carries on.

**Claude Code** sends JSON to the status line, and it contains `rate_limits`
(`five_hour`, `seven_day`: `used_percentage`, `resets_at`). All you need is to
save them to a file from your own status line — it is free and live, and it
refreshes with every reply from any running session. A ready-made example:
[`examples/statusline-limity.py`](examples/statusline-limity.py).

```
your statusline        →  ~/.claude/status/_limity-claude.json
limity-codex.py --json →  codex app-server (account/rateLimits/read)
limity.ps1 (every 30 s)→  limity.json
server.ps1             →  /limits
dashboard.html         →  checkLimits() every 10 s
```

When the status-line file is older than 5 minutes **and you are at the
computer**, `limity.ps1` asks once every 5 minutes for a fallback through
`claude -p /usage`. Codex is asked through `codex app-server` over JSON-RPC
(this costs no tokens); when it does not answer, the last known limits are
taken from the session files.

Diagnostics: `.\limity.ps1 -Once -ForceUsage` and `http://localhost:8099/limits`.

---

## Display states and OLED protection

| State | Trigger | What happens |
|---|---|---|
| **Work** | user at the PC | full dashboard, live data |
| **Calm** | idle ≥ screensaver limit | panels step back, the "organism" appears |
| **Return** | mouse movement | a shockwave from the centre, panels come back |
| **PC asleep** | connection lost | gauges to zero, "System asleep" screen |
| **Wake-up** | data returns | boot sequence, gauges rise from zero |

```
180 s idle      →  calm mode (content at 42 %, drifting slowly)
300 s idle      →  the page goes black and releases the display lock
+ phone's limit →  the phone turns the screen off by itself
mouse movement  →  the watchdog starts the activity within 10 s → screen on
```

Under the black nothing is drawn at all and `body.oled-off *` stops CSS
animations too — a hidden element would otherwise keep waking the phone's GPU.
**These protections reduce the burn-in risk, they do not remove it.** With
a static dashboard on an OLED it is worth leaving the phone its own short screen
timeout and turning off "keep screen on while charging".

---

## Files

| File | What it does |
|---|---|
| `dashboard.html` | Looks and logic — one page, no library. |
| `server.ps1` | Port 8099: `/` the page, `/api` proxy to LHM, `/state` idle time, `/limits`, `/comfy`, `/log`, `/manifest.json`, `/icon.svg`. |
| `watchdog.ps1` | Watches LHM, the server, `adb reverse` and the phone's foreground; wakes the display, detects the PC waking up. |
| `limity.ps1` | Collector of Claude and Codex limits → `limity.json`. |
| `limity-codex.py` | Codex limits (`codex app-server`, fallback from session files). |
| `comfy.ps1` | ComfyUI generation progress → `comfy.json`. |
| `cursorguard.ps1` | Safeguard in case the phone became a Windows display (spacedesk) and the cursor kept escaping onto it. |
| `app/` | App source + `build.ps1` (APK without Gradle). |
| `dashboard-v1-zaloha.html` | An older, simpler design; to go back, rename it to `dashboard.html`. |
| `sleepflag.ps1` | Leftover from the first version, not used. |
| `tests/` | Behaviour tests without a browser (Node, no dependencies). |
| `docs/poznamky-k-vyvoji.md` | Why the code is the way it is — and what held it up. (Czech) |

---

## Tests

```powershell
node tests/design-states.cjs     # states, boot, transitions, limits
node tests/ambient-motion.cjs    # calm mode, smoothness
node tests/oled-protection.cjs   # screen blanking and display locks
node tests/memory-meter.cjs      # memory meter
```

The tests read `dashboard.html` and run its code in `node:vm` with a substitute
DOM — that is why they need neither a browser nor a single dependency. They run
in CI as well.

---

## Security and privacy

- `server.ps1` listens **only on `http://localhost:8099`** and the phone reaches
  it through `adb reverse` (that is, over the USB cable). **Nothing is exposed
  to the network** and no data goes anywhere.
- That is also why there is no login: anyone who can reach your computer's
  `localhost` has access anyway. Do not forward port 8099 outside (no
  `netsh portproxy`, no tunnel) — the page and `/api` have no authentication.
- `/log` writes text from the phone into `watchdog.log`. It is a debugging
  channel for a local device; do not let anything foreign near it.
- `limity.json`, `comfy.json` and `watchdog.log` are created at runtime, contain
  your numbers and **are in `.gitignore`** — they do not belong in the
  repository.
- The app's signing key (`app/debug.keystore`) is generated on the first build
  and is ignored as well. Never share it: whoever has it can sign an APK that
  the phone will accept as an update of this application.
- The app only holds the `INTERNET` permission (for `localhost`) and
  `WAKE_LOCK`, plus `usesCleartextTraffic` because of HTTP on localhost.

---

## Known limitations

- Windows + Android. On another system the page would work, the scripts would
  not.
- Without LibreHardwareMonitor running **as administrator** there are no
  temperatures.
- A running Android emulator confuses `adb` (two devices); the watchdog
  therefore picks the phone by name and ignores `emulator-*`.
- Physically putting the phone to sleep is handled by MIUI itself — it cannot be
  forced through `adb`, it is two switches in the phone's settings.
- The fonts (Bahnschrift Condensed, Cascadia Mono) come from the system; where
  they are missing, the page falls back to a generic sans-serif.

---

## Licence

[MIT](LICENSE) — use it, modify it, commercially as well; just keep the
copyright and the licence text.

The project bundles nothing of anyone else's: it only talks to
LibreHardwareMonitor (MPL-2.0) through its HTTP API and to `adb`, and you
install both yourself. The fonts come from the system.

The dashboard was built on 29–30 August 2026 as a use for an old phone that had
been lying around in a drawer. If you build one too, send a photo to Issues.
