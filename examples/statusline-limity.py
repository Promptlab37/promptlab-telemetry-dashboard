# Priklad status line pro Claude Code, ktera navic ulozi limity pro dashboard.
#
# Instalace: uloz jako ~/.claude/statusline.py, zaloz adresar ~/.claude/status
# a v ~/.claude/settings.json nastav:
#
#     "statusLine": { "type": "command",
#                     "command": "python ~/.claude/statusline.py" }
#
# Claude Code posila na stdin JSON, ve kterem je (pro predplatitele, az po
# prvni odpovedi v session) i "rate_limits" s okny five_hour / seven_day:
#     {"used_percentage": 42.0, "resets_at": 1789110600}
# Zapsat si je do souboru je ZADARMO a ZIVE - obnovuje je kazda bezici session
# pri kazde odpovedi. Cte je limity.ps1 -> /limits -> dashboard.
import json
import sys

# Windows python ma stdout v cp1250 - unicode symbol by shodil cely skript.
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)

model = (d.get("model") or {}).get("display_name") or "?"
ctx = (d.get("context_window") or {}).get("used_percentage")

out = f"* {model}"
if isinstance(ctx, (int, float)):
    out += f" - kontext {round(ctx)} %"
    if ctx >= 80:
        out += " !"
print(out)


def uloz_limity(d):
    """Zapise rate_limits do ~/.claude/status/_limity-claude.json."""
    import os
    import time

    rl = d.get("rate_limits")
    if not isinstance(rl, dict) or not rl:
        return
    cesta = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "status", "_limity-claude.json")
    os.makedirs(os.path.dirname(cesta), exist_ok=True)
    ted = int(time.time())

    # Desitky sessions volaji status line kazdych par set ms - zapisovat jen
    # kdyz se limity zmenily, nebo aspon 1x za minutu (at jde poznat stari).
    try:
        with open(cesta, encoding="utf-8") as f:
            stare = json.load(f)
        if stare.get("rate_limits") == rl and ted - int(stare.get("at", 0)) < 60:
            return
    except Exception:
        pass

    data = {"at": ted, "model": model, "rate_limits": rl}
    tmp = f"{cesta}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f)
    os.replace(tmp, cesta)      # atomicky - ctenar nikdy neuvidi pulku souboru


# Cokoli se tady pokazi, nesmi shodit status line.
try:
    uloz_limity(d)
except Exception:
    pass
