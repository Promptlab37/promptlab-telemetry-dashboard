#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Vypise limity Codexu ve STEJNEM formatu, jaky vraci `claude -p /usage`.

KOPIE PRO TELEMETRII V TELEFONU (C:/another_phone): puvodni soubor je
/root/limity-codex.py ve WSL (zaloha Desktop/promptlab-remote-claude/server).
Tahle kopie navic umi `--json` (strojovy vystup pro limity.ps1) a bezi
i pod windowsovym Pythonem (cesty se odvozuji z USERPROFILE/LOCALAPPDATA).

Proc stejny format: appky (mobil i Mac) uz umi rozebrat radky
"<popis>: <N>% used · resets <kdy>", takze staci pripsat dalsi radky a limity
Codexu se objevi vedle Claudovych bez jakekoli zmeny v appkach.

ODKUD SE TO BERE (poradi je dulezite):

1. ZIVE z Codexu - `codex app-server` je JSON-RPC server a metoda
   "account/rateLimits/read" vrati aktualni stav limitu. NESTOJI to zadne
   tokeny (neni to dotaz na model) a trva to pod vterinu. Zjisteno 8. 9. 2026
   z `codex app-server generate-json-schema` (codex-cli 0.153.4).

2. Zaloha: posledni znamy stav ze souboru relaci
   (~/.codex/sessions/RRRR/MM/DD/rollout-*.jsonl, udalost "token_count",
   pole "rate_limits"). Pouziva se jen kdyz zivy dotaz selze.

PROC TO VZNIKLO: do 8. 9. 2026 se cetla POUZE zaloha, takze appka ukazovala
zmrazeny stav z chvile, kdy Codex naposled bezel. 8. 9. rano hlasila
"97 % z peti hodinoveho okna" ze snimku ze 7. 9. v 18:12, i kdyz se okno
tu noc ve 21:09 obnovilo a skutecne vycerpani bylo 0 %. Proto se ted
primarne ptame Codexu naziv a v zaloze se propadle okno (cas obnovy uz
probehl) neukazuje jako aktualni.
"""
import glob
import json
import os
import subprocess
import sys
import threading
import time
from datetime import datetime

try:
    from zoneinfo import ZoneInfo
    PRAHA = ZoneInfo("Europe/Prague")
except Exception:                      # pragma: no cover - stara python bez tzdata
    PRAHA = None

def _windows_domov():
    """Domovsky adresar windowsoveho uctu pri behu ve WSL.

    Jmeno uctu se neuhaduje - vezme se ten pod /mnt/c/Users, ktery Codex
    opravdu pouziva. Kdyz zadny takovy neni, vrati se None a pouzije se
    domov v Linuxu (nativni Codex CLI).
    """
    for cesta in sorted(glob.glob("/mnt/c/Users/*/.codex/sessions")):
        return os.path.dirname(os.path.dirname(cesta))
    for cesta in sorted(glob.glob("/mnt/c/Users/*/AppData/Local/OpenAI/Codex")):
        return cesta.split("/AppData/")[0]
    return None


def _vychozi_sessions():
    if os.name == "nt":
        return os.path.join(os.environ.get("USERPROFILE", ""), ".codex", "sessions")
    domov = _windows_domov()
    if domov:
        return os.path.join(domov, ".codex", "sessions")
    return os.path.expanduser("~/.codex/sessions")


def _vychozi_exe_glob():
    if os.name == "nt":
        return os.path.join(os.environ.get("LOCALAPPDATA", ""),
                            "OpenAI", "Codex", "bin", "*", "codex.exe")
    domov = _windows_domov()
    if domov:
        return os.path.join(domov, "AppData/Local/OpenAI/Codex/bin/*/codex.exe")
    return os.path.expanduser("~/.codex/bin/*/codex")


BASE = os.environ.get("CODEX_SESSIONS", _vychozi_sessions())
KOLIK_SOUBORU = 12                     # staci projit par nejnovejsich relaci

# Codex CLI je windowsovy program; ze skriptu ve WSL se spousti primo pres
# /mnt/c (interop). Cesta obsahuje hash verze, ktery se pri update meni, proto
# se hleda hvezdickou a bere se nejnovejsi.
CODEX_EXE_GLOB = os.environ.get("CODEX_EXE_GLOB", _vychozi_exe_glob())
ZIVY_LIMIT_S = 20                      # kdyz app-server nestihne, jde se na zalohu


def cas(razitko):
    """Epocha -> '6. 9. v 18:45' v prazskem case."""
    try:
        d = datetime.fromtimestamp(int(razitko), PRAHA) if PRAHA \
            else datetime.fromtimestamp(int(razitko))
    except (TypeError, ValueError, OSError):
        return ""
    return f"{d.day}. {d.month}. v {d:%H:%M}"


# ---------------------------------------------------------------- zivy dotaz

def _codex_exe():
    """Nejnovejsi codex.exe, nebo None kdyz se zadny nenasel."""
    nalezene = glob.glob(CODEX_EXE_GLOB)
    if not nalezene:
        return None
    return max(nalezene, key=os.path.getmtime)


def zive_limity():
    """Aktualni limity primo z Codexu. Vraci dict ve tvaru jako v relacich.

    Prevadi se do stejneho tvaru jako zaloha (used_percent / window_minutes /
    resets_at), aby zbytek skriptu nemusel rozlisovat, odkud data prisla.
    Pri jakemkoli problemu vraci None - limity Clauda se kvuli Codexu nesmi
    ztratit, takze se odsud nic nevyhazuje ven.
    """
    exe = _codex_exe()
    if not exe:
        return None
    try:
        p = subprocess.Popen(
            [exe, "app-server"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, encoding="utf-8", bufsize=1,
        )
    except OSError:
        return None

    # Pojistka: kdyby app-server zamrzl, po ZIVY_LIMIT_S ho zabijeme a
    # blokujici readline() skonci na prazdnem radku.
    hlidac = threading.Timer(ZIVY_LIMIT_S, p.kill)
    hlidac.daemon = True
    hlidac.start()
    try:
        _posli(p, {"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {
            "clientInfo": {"name": "promptlab-limity", "title": "PromptLab limity",
                           "version": "1.0"}}})
        _posli(p, {"jsonrpc": "2.0", "id": 1,
                   "method": "account/rateLimits/read", "params": {}})
        konec = time.time() + ZIVY_LIMIT_S
        while time.time() < konec:
            radek = p.stdout.readline()
            if not radek:
                return None
            try:
                zprava = json.loads(radek)
            except ValueError:
                continue               # notifikace, ktere nas nezajimaji
            if zprava.get("id") != 1:
                continue
            if "error" in zprava:      # napr. odhlaseny Codex
                return None
            return _prevod(zprava.get("result") or {})
        return None
    except (OSError, ValueError):
        return None
    finally:
        hlidac.cancel()
        try:
            p.kill()
        except OSError:
            pass


def _posli(p, zprava):
    p.stdin.write(json.dumps(zprava) + "\n")
    p.stdin.flush()


def _prevod(vysledek):
    """Odpoved app-serveru -> tvar, jaky ma "rate_limits" v relacich."""
    podle_id = vysledek.get("rateLimitsByLimitId") or {}
    snimek = podle_id.get("codex") or vysledek.get("rateLimits") or {}
    prevedeny = {}
    for klic in ("primary", "secondary"):
        okno = snimek.get(klic) or {}
        procenta = okno.get("usedPercent")
        if procenta is None:
            continue
        prevedeny[klic] = {
            "used_percent": procenta,
            "window_minutes": okno.get("windowDurationMins"),
            "resets_at": okno.get("resetsAt"),
        }
    return prevedeny or None


# ------------------------------------------------------------------- zaloha

def pouzitelny(lim):
    """Ma zaznam aspon jedno okno s procenty?

    Codex CLI pise vedle zaznamu s limit_id "codex" (skutecna okna) jeste
    zaznamy s jinym limit_id - napr. "premium", ktery se objevil 7. 9. 2026,
    kdyz se vycerpalo peti hodinove okno. Ten ma primary i secondary null a
    slouzi jen ke kreditum. Kdyz se vzal jako "nejnovejsi", skript nemel co
    vypsat a v appce zmizely limity Codexu uplne.
    """
    if not lim:
        return False
    for klic in ("primary", "secondary"):
        okno = lim.get(klic) or {}
        if okno.get("used_percent") is not None:
            return True
    return False


def posledni_limity():
    """Nejnovejsi POUZITELNY zaznam rate_limits ze vsech relaci. (limity, cas)"""
    soubory = sorted(glob.glob(BASE + "/*/*/*/rollout-*.jsonl"),
                     key=os.path.getmtime, reverse=True)[:KOLIK_SOUBORU]
    nej, nej_cas = None, ""
    for cesta in soubory:
        try:
            with open(cesta, encoding="utf-8", errors="replace") as f:
                for radek in f:
                    if '"rate_limits"' not in radek:
                        continue
                    try:
                        rec = json.loads(radek)
                    except ValueError:
                        continue
                    lim = (rec.get("payload") or {}).get("rate_limits")
                    if not pouzitelny(lim):
                        continue
                    kdy = rec.get("timestamp") or ""
                    if kdy >= nej_cas:      # ISO 8601 se da porovnavat jako text
                        nej, nej_cas = lim, kdy
        except OSError:
            continue
        if nej is not None:
            break                        # nejnovejsi soubor uz limity mel
    return nej, nej_cas


def kdy_zapsano(iso):
    """'2026-09-06T17:57:56.902Z' -> 'k 19:57' v prazskem case."""
    if not iso:
        return ""
    try:
        d = datetime.strptime(iso[:19], "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return ""
    try:
        from datetime import timezone
        d = d.replace(tzinfo=timezone.utc)
        if PRAHA:
            d = d.astimezone(PRAHA)
    except Exception:
        pass
    return f"k {d:%H:%M}"


# --------------------------------------------------------------------- vypis

def main():
    lim = zive_limity()
    zdroj, kdy = "live", ""
    znacka = ""                        # zive udaje se oznacovat nemusi
    if not lim:
        zdroj = "zaloha"
        lim, kdy = posledni_limity()
        if not lim:
            if "--json" in sys.argv:
                print(json.dumps({"source": None, "windows": []}))
            return 0
        znacka = kdy_zapsano(kdy)
    if "--json" in sys.argv:
        return vypis_json(lim, zdroj, kdy)
    popisky = (
        ("primary", "Codex – okno 5 h"),
        ("secondary", "Codex – týden"),
    )
    for klic, popis in popisky:
        okno = lim.get(klic) or {}
        procenta = okno.get("used_percent")
        if procenta is None:
            continue
        # Delka okna se bere z dat, ne z hlavy: kdyby OpenAI okno zmenilo,
        # popisek se zmeni s nim (300 min = 5 h, 10080 min = tyden).
        popis = _popis_okna(okno.get("window_minutes"), popis)
        # Cas snimku patri k OBNOVE, ne do popisku: v mobilu se popisek kresli
        # pod uzky krouzek a dlouhy text se tam nevejde.
        obnova = cas(okno.get("resets_at"))
        casti = []
        if _propadle(okno.get("resets_at")):
            # Okno ze zalozniho snimku se mezitim obnovilo. Stara procenta by
            # ted lhala (a lhala - 8. 9. rano hlasila 97 % z okna, ktere se
            # obnovilo uz 7. 9. ve 21:09), takze se hlasi 0 % a rekne se proc.
            procenta = 0
            casti.append("?")
            if obnova:
                casti.append("obnoveno " + obnova)
        elif obnova:
            casti.append(obnova)
        if znacka:
            casti.append("stav " + znacka)
        radek = f"{popis}: {int(round(procenta))}% used"
        if casti:
            radek += " · resets " + " · ".join(casti)
        print(radek)
    return 0


def vypis_json(lim, zdroj, kdy):
    """Strojovy vystup pro limity.ps1 (telemetrie v telefonu).

    Cas snimku zalohy se posila jako epocha, aby si ho stranka prevedla
    sama; u zivych dat je to "ted". Propadle okno ze zalohy se hlasi jako
    0 % + stale=true, stejne jako v textovem vystupu.
    """
    okna = []
    for klic in ("primary", "secondary"):
        okno = lim.get(klic) or {}
        procenta = okno.get("used_percent")
        if procenta is None:
            continue
        propadle = zdroj != "live" and _propadle(okno.get("resets_at"))
        okna.append({
            "key": klic,
            "pct": 0 if propadle else int(round(procenta)),
            "windowMinutes": okno.get("window_minutes"),
            "resetsAt": okno.get("resets_at"),
            "stale": bool(propadle),
        })
    at = int(time.time())
    if zdroj != "live" and kdy:
        try:
            from datetime import timezone
            d = datetime.strptime(kdy[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
            at = int(d.timestamp())
        except ValueError:
            pass
    print(json.dumps({"source": zdroj, "at": at, "windows": okna}))
    return 0


def _propadle(razitko):
    """Uz cas obnovy probehl? (u zivych dat se to nestava)"""
    try:
        return int(razitko) < time.time()
    except (TypeError, ValueError):
        return False


def _popis_okna(minut, vychozi):
    """Popisek podle skutecne delky okna (window_minutes z rate_limits)."""
    try:
        minut = int(minut)
    except (TypeError, ValueError):
        return vychozi
    if minut % 10080 == 0 and minut >= 10080:
        tydnu = minut // 10080
        return "Codex – týden" if tydnu == 1 else f"Codex – {tydnu} týdny"
    if minut % 1440 == 0 and minut >= 1440:
        dnu = minut // 1440
        return f"Codex – okno {dnu} dní" if dnu != 1 else "Codex – okno 1 den"
    if minut % 60 == 0 and minut >= 60:
        return f"Codex – okno {minut // 60} h"
    return f"Codex – okno {minut} min"


if __name__ == "__main__":
    sys.exit(main())
