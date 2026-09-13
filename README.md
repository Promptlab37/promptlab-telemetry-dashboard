**Čeština** · [English](README.en.md)

# PROMPTLAB · System Telemetry

**Starý telefon jako trvalá přístrojová deska počítače.** Teploty, vytížení,
paměť a zbývající limity AI nástrojů — velkými čísly, čitelně přes celý stůl,
bez cloudu a bez účtu. Telefon visí na USB, stránka běží v něm, počítač jen
posílá data.

![Dashboard na telefonu](docs/dashboard.png)

---

## Co to umí

- **Teploty a vytížení CPU/GPU** na dvou velkých budících, se slovním stavem
  (V normě / Zvýšená / Vysoká / Kritická) — nikdy jen barva.
- **Operační paměť a VRAM** včetně volného místa a rysky špičky.
- **Zbývající limity Claude Code a Codexu** (volitelné, viz níže).
- **Ukazatel generování v ComfyUI** (volitelné) — naskočí jen když se generuje.
- **Klidový režim**, když od počítače odejdeš: panely ustoupí, zůstanou hodiny
  a dvě velká čísla, obraz se pomalu posouvá kvůli OLED.
- **Přežije uspání počítače**: stránka běží v telefonu, takže při ztrátě dat
  sama přejde na obrazovku „Systém spí" a po návratu přehraje bootovací sekvenci.
- **Rozsvítí displej**, když se vrátíš k počítači — to prohlížeč neumí, proto
  je tu vlastní miniaplikace (jeden WebView, dva soubory Javy).

Celé je to jedna HTML stránka bez jediné knihovny, několik PowerShell skriptů
a APK o velikosti pár desítek kB. Žádný build, žádné závislosti, žádná registrace.

---

## Jak to funguje

```
LibreHardwareMonitor (jako správce)  →  čte čidla, HTTP na portu 8085
server.ps1                           →  port 8099: stránka + /api + /state + /limits
limity.ps1                           →  limity Claude a Codexu  → limity.json
comfy.ps1                            →  průběh generování       → comfy.json
adb reverse tcp:8099                 →  telefon vidí PC jako svůj localhost
aplikace PROMPTLAB (WebView)         →  vykresluje dashboard nativně, fullscreen
watchdog.ps1                         →  hlídá všechno výše a budí telefon
```

Dvě rozhodnutí, která za tím stojí:

- **Stránka běží v telefonu, ne na PC.** Díky tomu přežije uspání počítače:
  když přestanou chodit data, přepne se sama a čeká na návrat.
- **Vlastní aplikace místo prohlížeče.** Chrome nepřepne na celou obrazovku bez
  gesta uživatele (a přes `adb` to gesto nejde vyvolat) a stránka v prohlížeči
  neumí rozsvítit displej. Aktivita umí obojí, bez zvláštních oprávnění.

---

## Co je potřeba

| | |
|---|---|
| **Počítač** | Windows 10/11, PowerShell 5.1 (součást systému) |
| **Čidla** | [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) — `winget install LibreHardwareMonitor.LibreHardwareMonitor` |
| **Telefon** | Android 7+ (API 24), zapnuté vývojářské možnosti a ladění přes USB |
| **Nástroje** | `adb` z [platform-tools](https://developer.android.com/tools/releases/platform-tools) |
| **Build appky** | Android SDK build-tools 34 + JDK (stačí to, co instaluje Android Studio) — jen když si chceš APK sestavit sám |
| **Testy** | Node.js (jen pro `tests/`) |

Vyzkoušeno na Xiaomi 11T Pro (AMOLED, 6,67"), ale nic v kódu není na tenhle
model vázané. Stránka je navržená na plochu 2400 × 1080 a sama se přeškáluje.

---

## Instalace

**1. LibreHardwareMonitor.** Nainstaluj, spusť **jako správce** (bez toho
nepřečte teplotní čidla) a v `Options → Remote Web Server` zapni server na
portu **8085**. Ověř v prohlížeči: `http://localhost:8085/data.json`.

**2. Stáhni tohle repo** kamkoli, třeba `C:\telemetrie`.

**3. Telefon připoj přes USB**, potvrď na něm ladění a ověř:

```powershell
adb devices          # musí být vidět jedno zařízení ve stavu "device"
```

**4. Nainstaluj aplikaci do telefonu.** Buď si sestav APK:

```powershell
.\app\build.ps1      # aapt2 + javac + d8 + apksigner, bez Gradle
```

…nebo si dashboard nejdřív zkus jen v prohlížeči telefonu (`adb reverse
tcp:8099 tcp:8099` a v Chrome `http://localhost:8099`) — jen nebude fullscreen
ani se sám nerozsvítí.

> Xiaomi/MIUI blokuje **první** instalaci přes USB (`INSTALL_FAILED_USER_RESTRICTED`).
> Buď zapni „Instalace přes USB" ve vývojářských možnostech, nebo APK jednou
> nainstaluj ručně ze správce souborů v telefonu. Další aktualizace už přes
> `adb install -r` projdou.

**5. Spusť hlídače:**

```powershell
.\watchdog.ps1
```

Hlídač si sám pustí `server.ps1`, obnoví `adb reverse`, přepne telefon na
aplikaci a drží to v chodu. Na dashboard se koukni i na PC:
`http://localhost:8099`.

**6. Automatický start (volitelné).** Přesně tahle dvojice úloh se osvědčila:

```powershell
# 1) LibreHardwareMonitor - musí mít zvýšená práva, jinak nejsou teploty
$lhm = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\LibreHardwareMonitor.LibreHardwareMonitor_*\LibreHardwareMonitor.exe").FullName
Register-ScheduledTask -TaskName 'PROMPTLAB-Telemetry-LHM' `
  -Trigger (New-ScheduledTaskTrigger -AtLogOn) `
  -Action  (New-ScheduledTaskAction -Execute $lhm) `
  -Principal (New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest)

# 2) Hlídač - běžná práva stačí
Register-ScheduledTask -TaskName 'PROMPTLAB-Telemetry-Watchdog' `
  -Trigger (New-ScheduledTaskTrigger -AtLogOn) `
  -Action  (New-ScheduledTaskAction -Execute 'powershell.exe' `
             -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PWD\watchdog.ps1`"")
```

Hlídači se hodí ještě druhý spouštěč „po probuzení ze spánku" (Plánovač úloh →
při události, log `System`, zdroj `Kernel-Power`, ID 107). `START-hlidac.cmd`
a `STOP-hlidac.cmd` jsou ruční vypínače těchto úloh.

---

## Nastavení

Nic se nekonfiguruje v souborech — všechno jsou parametry skriptů nebo
proměnné prostředí, aby repo bylo použitelné hned po stažení.

| Skript | Parametry (výchozí) |
|---|---|
| `server.ps1` | `-Port 8099`, `-LhmPort 8085` |
| `watchdog.ps1` | `-IntervalSec 10`, `-Port 8099`, `-AdbExe`, `-LhmExe`, `-Once` |
| `limity.ps1` | `-IntervalSec 30`, `-ClaudeFallbackMin 5`, `-Once`, `-ForceUsage` |
| `comfy.ps1` | `-ComfyPort 8188`, `-LogDir`, `-IntervalMs 1000` |

| Proměnná prostředí | K čemu |
|---|---|
| `ANDROID_HOME` / `ANDROID_SDK_ROOT` | kde je Android SDK (jinak `%LOCALAPPDATA%\Android\Sdk`) |
| `JAVA_HOME` | JDK pro build APK (jinak JBR z Android Studia) |
| `PROMPTLAB_ADB` / `PROMPTLAB_LHM` | přímá cesta k `adb.exe` / `LibreHardwareMonitor.exe` |
| `PROMPTLAB_COMFY_LOGDIR` | adresář s logy launcheru ComfyUI |
| `CODEX_SESSIONS` / `CODEX_EXE_GLOB` | kde má `limity-codex.py` hledat Codex |

Prahy chování dashboardu (kdy klidový režim, kdy zhasnout) jsou nahoře
v `dashboard.html` jako `IDLE_ENTER` a `SCREEN_OFF`. Práh klidu se navíc sám
řídí podle skutečného limitu spořiče ve Windows.

---

## Limity Claude Code a Codexu (volitelné)

Spodní řada dashboardu ukazuje, kolik zbývá v jednotlivých oknech limitů —
velké číslo, slovní stav (Volno / Dochází / Na hraně / Vyčerpáno), pruh, který
ubývá jako palivo, a čas obnovy. Bez těchto nástrojů zůstane řada prázdná
a zbytek dashboardu funguje dál.

**Claude Code** posílá do status line JSON, ve kterém je i `rate_limits`
(`five_hour`, `seven_day`: `used_percentage`, `resets_at`). Stačí si je ve své
status line uložit do souboru — je to zadarmo a živé, obnoví se při každé
odpovědi kterékoli běžící session. Hotový příklad:
[`examples/statusline-limity.py`](examples/statusline-limity.py).

```
statusline (tvoje)      →  ~/.claude/status/_limity-claude.json
limity-codex.py --json  →  codex app-server (account/rateLimits/read)
limity.ps1 (po 30 s)    →  limity.json
server.ps1              →  /limits
dashboard.html          →  checkLimits() po 10 s
```

Když je soubor od status line starší než 5 minut **a sedíš u počítače**,
`limity.ps1` si jednou za 5 minut vyžádá zálohu přes `claude -p /usage`.
Codex se ptá `codex app-server` přes JSON-RPC (nestojí to žádné tokeny);
když neodpoví, vezme poslední známé limity ze souborů relací.

Diagnostika: `.\limity.ps1 -Once -ForceUsage` a `http://localhost:8099/limits`.

---

## Stavy displeje a ochrana OLED

| Stav | Spouštěč | Co se stane |
|---|---|---|
| **Práce** | uživatel u PC | plný dashboard, živá data |
| **Klid** | nečinnost ≥ limit spořiče | panely ustoupí, naskočí „organismus" |
| **Návrat** | pohyb myší | rázová vlna od středu, panely naskočí |
| **Spánek PC** | ztráta spojení | budíky na nulu, obrazovka „Systém spí" |
| **Probuzení** | návrat dat | bootovací sekvence, budíky vyjedou z nuly |

```
180 s nečinnosti  →  klidový režim (obsah na 42 %, pomalu cestuje)
300 s nečinnosti  →  stránka zčerná a pustí zámek displeje
+ limit telefonu  →  telefon zhasne sám
pohyb myší        →  hlídač do 10 s spustí aktivitu → displej se rozsvítí
```

Pod černou se nekreslí nic a `body.oled-off *` zastaví i CSS animace — skrytý
prvek by jinak dál budil GPU telefonu. **Tyhle ochrany riziko vypálení snižují,
nevylučují ho.** U statického dashboardu na OLED se vyplatí nechat telefonu
vlastní krátký limit zhasnutí a vypnout „nevypínat obrazovku při nabíjení".

---

## Soubory

| Soubor | Co dělá |
|---|---|
| `dashboard.html` | Vzhled i logika — jedna stránka, žádná knihovna. |
| `server.ps1` | Port 8099: `/` stránka, `/api` proxy na LHM, `/state` nečinnost, `/limits`, `/comfy`, `/log`, `/manifest.json`, `/icon.svg`. |
| `watchdog.ps1` | Hlídá LHM, server, `adb reverse`, popředí telefonu; budí displej, pozná probuzení PC. |
| `limity.ps1` | Sběrač limitů Claude a Codexu → `limity.json`. |
| `limity-codex.py` | Limity Codexu (`codex app-server`, záloha ze souborů relací). |
| `comfy.ps1` | Průběh generování v ComfyUI → `comfy.json`. |
| `cursorguard.ps1` | Pojistka, kdyby se z telefonu stal displej Windows (spacedesk) a utíkal na něj kurzor. |
| `app/` | Zdroj aplikace + `build.ps1` (APK bez Gradle). |
| `dashboard-v1-zaloha.html` | Starší jednodušší design; návrat = přejmenovat na `dashboard.html`. |
| `sleepflag.ps1` | Pozůstatek z první verze, nepoužívá se. |
| `tests/` | Testy chování bez prohlížeče (Node, bez závislostí). |
| `docs/poznamky-k-vyvoji.md` | Proč je kód, jak je — a na čem se to zdrželo. |

---

## Testy

```powershell
node tests/design-states.cjs     # stavy, boot, přechody, limity
node tests/ambient-motion.cjs    # klidový režim, plynulost
node tests/oled-protection.cjs   # zhasínání a zámky displeje
node tests/memory-meter.cjs      # ukazatel paměti
```

Testy čtou `dashboard.html` a pouštějí jeho kód v `node:vm` s náhradním DOM —
proto nepotřebují prohlížeč ani jedinou závislost. Běží i v CI.

---

## Bezpečnost a soukromí

- `server.ps1` poslouchá **jen na `http://localhost:8099`** a telefon se k němu
  dostane přes `adb reverse` (tedy po USB kabelu). **Nic se nevystavuje do sítě**
  a nikam neodcházejí žádná data.
- Proto tu není žádné přihlašování: kdo má přístup na `localhost` tvého
  počítače, má ho stejně. Neposílej port 8099 ven (žádný `netsh portproxy`,
  žádný tunel) — stránka i `/api` jsou bez ověření.
- `/log` zapisuje text z telefonu do `watchdog.log`. Je to ladicí kanál pro
  lokální zařízení; nepouštěj k němu nic cizího.
- `limity.json`, `comfy.json` a `watchdog.log` vznikají za běhu, obsahují tvoje
  čísla a **jsou v `.gitignore`** — do repa nepatří.
- Podpisový klíč appky (`app/debug.keystore`) se generuje při prvním buildu
  a je rovněž ignorovaný. Nikdy ho nesdílej: kdo ho má, může podepsat APK,
  které telefon přijme jako aktualizaci téhle aplikace.
- Aplikace má jen oprávnění `INTERNET` (kvůli `localhost`) a `WAKE_LOCK`,
  `usesCleartextTraffic` kvůli HTTP na localhost.

---

## Známá omezení

- Windows + Android. Na jiném systému by fungovala stránka, ne skripty.
- Bez LibreHardwareMonitoru běžícího **jako správce** nejsou teploty.
- Běžící Android emulátor mate `adb` (dvě zařízení); hlídač proto vybírá
  telefon jmenovitě a `emulator-*` ignoruje.
- Fyzické uspání telefonu si MIUI hlídá samo — přes `adb` ho vynutit nejde,
  jsou to dva přepínače v nastavení telefonu.
- Písma (Bahnschrift Condensed, Cascadia Mono) se berou ze systému; jinde
  stránka spadne na náhradní bezpatkové písmo.

---

## Licence

[MIT](LICENSE) — používej, uprav si to, klidně i komerčně; jen zachovej
copyright a text licence.

Projekt nic cizího nebalí: mluví jen s LibreHardwareMonitorem (MPL-2.0) přes
jeho HTTP API a s `adb`, obojí si instaluješ sám. Písma jsou systémová.

Dashboard vznikl 29.–30. 8. 2026 jako využití starého telefonu, který se válel
v šuplíku. Když ho postavíš taky, pošli fotku do Issues.
