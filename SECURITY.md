# Bezpečnost

## Jak je to navržené

Celá telemetrie je **lokální**. `server.ps1` otevírá `HttpListener` výhradně na
`http://localhost:8099/`, takže se k němu z jiného počítače nedá připojit ani
omylem. Telefon se k němu dostane přes `adb reverse tcp:8099 tcp:8099`, což je
tunel po USB kabelu — ne po síti. Data z čidel nikam neodcházejí a projekt
nikam nevolá.

Proto server **nemá žádné ověřování**. Je to záměr: kdo už má přístup na
`localhost` tvého počítače, ten má stejně všechno ostatní.

## Co nedělat

- Nevystavuj port 8099 (ani 8085 od LibreHardwareMonitoru) do sítě —
  žádný `netsh portproxy`, `ngrok`, port forward na routeru. Stránka, `/api`
  i `/state` jsou bez ověření a `/log` zapisuje text z požadavku do
  `watchdog.log`.
- Necommituj `limity.json`, `comfy.json` ani `watchdog.log` — jsou v
  `.gitignore` a obsahují tvoje čísla a časy.
- Nesdílej `app/debug.keystore`. Generuje se při prvním buildu a je ignorovaný.
  Kdo ho má, může podepsat APK, které telefon přijme jako aktualizaci téhle
  aplikace.

## Oprávnění aplikace

`INTERNET` (kvůli spojení na `localhost`) a `WAKE_LOCK` (rozsvícení displeje).
`usesCleartextTraffic` je zapnuté kvůli HTTP na localhost. Nic víc aplikace
nechce a nic neposílá.

## Hlášení chyb

Bezpečnostní problém pošli jako **Security advisory** (záložka Security →
Report a vulnerability), ne jako veřejné issue. Je to hobby projekt, odpověď
může pár dní trvat.
