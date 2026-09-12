# Poznámky k vývoji

Proč je kód, jak je. Většinu z toho stálo několik hodin hledání, takže než
něco „zjednodušíš", mrkni sem.

---

## Data z LibreHardwareMonitoru

- **Paměť.** LHM má dva paměťové uzly se *shodně pojmenovanými* senzory:
  `Total Memory` (fyzická RAM) a `Virtual Memory` (RAM + stránkovací soubor).
  Rozlišuje je název **hardwaru**, ne senzoru — proto
  `/^(?!Virtual\s)(.*\s)?Memory$/i`. Celkovou kapacitu LHM samostatně nehlásí,
  počítá se jako `Memory Used + Memory Available`; špička je `Max`
  u `Memory Used`.
- **Ventilátor.** Skupina `Fans` dává otáčky, `Controls` procenta. Dashboard
  chce procenta a na otáčky padá až jako záloha.
- **Síť** (dnes se nepoužívá, v `dashboard-v1-zaloha.html` ano): skupina
  `Throughput` není jen síť — patří do ní i GPU PCIe a disky — a virtuální
  adaptéry (VPN, WSL, Docker, Tailscale) hlásí nesmysly. Nutné vyřazovat.
- **Desetinná čárka.** LHM i PowerShellový `-f` formátují podle českého
  národního prostředí. U ručně skládaného JSONu je nutné vynutit
  `InvariantCulture`, jinak vznikne `{"idle":0,0}` — neplatný JSON.

## Vzhled

- **Barvy** vycházejí z dataviz palety ověřené validátorem proti `#000000`.
  Stav vždy nese **barvu i slovo** — nikdy jen barvu.
- **Písma:** Bahnschrift Condensed a Cascadia Mono, obojí ve Windows lokálně.
  Návrhová plocha je 2400 × 1080, `fit()` ji jen přeškáluje.
- **Organismus** v klidovém režimu není animace na smyčce, čte skutečná data:
  vytížení CPU určuje rychlost tepu (42–127 tepů/min), vytížení GPU hustotu
  a dosah synapsí, nejvyšší teplota barvu (zelená → jantarová → rudá).

## Pasti, na kterých se to zdrželo

- **`<canvas>` je nahrazovaný element.** `inset:0` mu velikost neurčí — vezme
  si atributový rozměr. Nutné explicitní `width`/`height` i v CSS.
- **`setMode()` přepisem `className`** smazal třídu `needs-fs`. Třídy režimů
  se proto přidávají a odebírají jmenovitě.
- **`onResume()` vracel `KEEP_SCREEN_ON`** a hlídač aplikaci opakovaně
  spouštěl → displej nikdy nezhasl. Hlídač proto při nečinnosti nezasahuje.
- **d8 padal na anonymních vnitřních třídách** při `-source 8`. Aktivita proto
  implementuje `Runnable` přímo a `RetryClient` je samostatná pojmenovaná třída.
- **Detekce fullscreenu:** WebView nehlásí `display-mode: fullscreen`, i když
  fullscreen skutečně je. Pozná se podle `; wv)` v identifikátoru prohlížeče.
- **Běžící Android emulátor rozbije všechno.** `adb` má pak dvě zařízení
  a každý příkaz skončí na `error: more than one device/emulator`. Hlídač si
  proto telefon vybírá jmenovitě (`adb -s <serial>`) a zařízení začínající
  `emulator-` ignoruje. Bez toho se po probuzení nestalo vůbec nic.
- **Nečinnost po odemknutí je zastaralá.** Zadání hesla na zamykací obrazovce
  se do uživatelské relace nepočítá, takže `GetLastInputInfo` hlásí poslední
  vstup z doby *před* uspáním — naměřeno 18 978 s. Hlídač to vyhodnotil jako
  „u počítače nikdo není" a telefon nechal spát. Server proto pozná probuzení
  podle skoku systémového čítače mezi dvěma dotazy a další 3 minuty hlásí
  nečinnost 0.
- **Hledání procesů podle příkazové řádky** chytá i vlastní konzoli, která ten
  řetězec jen zmiňuje — skript se tím zabil sám. Jedináčka řeší **mutex**.
- **PowerShell a `$null` u `[string]` parametru** — převede se na *prázdný
  řetězec*, na což `EnumDisplayDevices` (v `cursorguard.ps1`) doplatí. Nutné
  `[NullString]::Value`.
- **Stránka v telefonu se sama neobnovuje.** Po úpravě `dashboard.html` je
  potřeba se do aplikace vrátit (`onResume` → `web.reload()`), jinak v telefonu
  dál běží stará verze:
  `adb shell input keyevent KEYCODE_HOME` a pak
  `adb shell am start -n cz.promptlab.telemetry/.MainActivity`.

## Ochrana OLED

- Při práci zůstávají budíky velké; bílá a záření číslic jsou mírně tlumené.
- V klidovém režimu je celý obsah na 42 % krytí a plynule cestuje vodorovně
  v rozsahu ±140 návrhových pixelů, s malým svislým pohybem. Pohybují se
  i číslice a kruhy, nejen pozadí. (Krytí není údaj v nitech.)
- Po 300 s nečinnosti počítače stránka přejde na čistou černou a uvolní
  nativní zámek displeje. Pod černou se nekreslí organismus a `body.oled-off *`
  zastaví i všechny CSS animace — skrytý prvek by jinak dál budil GPU telefonu.
  Probíhající generování tenhle limit neruší.
- Po ztrátě spojení se přehraje uspávací sekvence, 60 s zůstane tmavý stavový
  údaj, potom také čistá černá. Návrat spojení zruší starý časovač zhasnutí.
- Nativní WebView používá pouze `PL.setAwake`, nikoli současně webový Wake Lock
  — dva zámky se navzájem perou.
- **Fyzické uspání telefonu blokuje jeho nastavení a `adb` s tím nic nezmůže.**
  Na MIUI platí `stay_on_while_plugged_in=15` (displej při nabíjení nikdy
  nezhasne) a `screen_off_timeout=600000`; `settings put global …` skončí na
  `WRITE_SECURE_SETTINGS`, `settings put system …` na `WRITE_SETTINGS`
  a `input keyevent 223` na `INJECT_EVENTS`. Odemyká to jedině
  „Ladění USB (nastavení zabezpečení)" ve vývojářských možnostech. Bez toho
  jsou to **dva ruční přepínače v telefonu**, ne věc skriptu:
  1. Vývojářské možnosti → vypnout „Nevypínat obrazovku při nabíjení".
  2. Nastavení → Displej → Režim spánku → 30 sekund.
- Ověření celého cyklu: nechat počítač 5 minut bez dotyku (stránka zčerná,
  `PL.setAwake(false)`), počkat, až telefon zhasne, pak sáhnout na myš. Hlídač
  do 10 s uvidí nečinnost < 25 s, spustí `am start` a aktivita se přes
  `setTurnScreenOn()` rozsvítí sama.
- Tyhle ochrany riziko vypálení **snižují, nevylučují**.

## Limity Claude a Codexu

- **Claude Code** posílá status line na stdin JSON, ve kterém je i
  `rate_limits.five_hour` / `rate_limits.seven_day` (`used_percentage`,
  `resets_at`) — pole jsou jen pro předplatitele a objeví se až po první
  odpovědi v session. Uložit si je ze status line do souboru je zadarmo
  a živé: obnovuje to každá běžící session při každé odpovědi. Zápis musí být
  atomický (`os.replace`) a jen při změně nebo 1× za minutu — status line
  volají desítky sessions za sekundu. Viz `examples/statusline-limity.py`.
- **Záloha `claude -p /usage`** se pouští, jen když je soubor starší než
  5 minut a uživatel je u počítače. `/usage` se předává **bez uvozovek**,
  jinak to nefunguje. Trvá to ~4 s a zakládá malou session, proto nejvýš
  1× za 5 minut a nikdy při nečinnosti. Tahle cesta dává navíc třetí okno
  („Týden · Fable"), které status line neposílá — počet dlaždic Clauda proto
  kolísá 2 ↔ 3 podle zdroje a poměr sloupců (`.bot.lim32`) se přizpůsobí.
- **Codex** odpovídá na JSON-RPC `account/rateLimits/read` v `codex app-server`
  — nestojí to žádné tokeny a trvá ~1 s. Když to selže, vezme se poslední
  `rate_limits` ze souborů relací (`~/.codex/sessions/…/rollout-*.jsonl`,
  událost `token_count`) a propadlé okno se hlásí jako 0 % + `stale`.
- Prahy stavů jsou stejné jako u kroužků v mobilní aplikaci autora:
  zelená > 30 % zbývá, žlutá ≤ 30 %, červená ≤ 10 %.

## Architektura příkazů v hlídači

Hlídač (`watchdog.ps1`) každých 10 s kontroluje v tomhle pořadí: běží LHM →
běží `server.ps1` → je aktivní `adb reverse tcp:8099` → je telefon vidět →
je v popředí aplikace → má se budit displej. Sběrače (`limity.ps1`,
`comfy.ps1`) si spouští sám a pozná je podle příkazové řádky s cestou k repu.
