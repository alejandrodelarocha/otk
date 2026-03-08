#!/usr/bin/env python3
"""OTK Server — central analytics + filtering for all machines."""

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse
import sqlite3, json, time, os
from pathlib import Path

app = FastAPI()
DB = Path(os.environ.get("OTK_DB", "/data/otk.db"))

MODELS = {
    "claude":      3.00,
    "gpt":         2.50,
    "gpt4o":       2.50,
    "gemini":      0.075,
}


def get_db():
    DB.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(DB))
    conn.row_factory = sqlite3.Row
    conn.execute("""
        CREATE TABLE IF NOT EXISTS runs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            machine TEXT,
            cmd TEXT,
            original INTEGER,
            filtered INTEGER,
            saved INTEGER,
            pct INTEGER,
            ts INTEGER
        )
    """)
    conn.commit()
    return conn


def count_tokens_approx(text: str) -> int:
    return max(1, len(text) // 4)


def filter_text(cmd: str, raw: str) -> str:
    import re
    lines = raw.splitlines()
    # Deduplicate
    seen, result = set(), []
    for line in lines:
        clean = re.sub(r'\x1b\[[0-9;]*[mKHJABCDGsu]', '', line).strip()
        if clean and clean not in seen:
            seen.add(clean)
            result.append(line)
    # Truncate
    if len(result) > 80:
        omitted = len(result) - 80
        result = result[:40] + [f"... ({omitted} lines omitted) ..."] + result[-40:]
    return "\n".join(result)


@app.post("/api/filter")
async def api_filter(request: Request):
    body = await request.json()
    cmd = body.get("cmd", "")
    raw = body.get("output", "")
    machine = body.get("machine", "unknown")

    filtered = filter_text(cmd, raw)

    original = count_tokens_approx(raw)
    filtered_tokens = count_tokens_approx(filtered)
    saved = max(0, original - filtered_tokens)
    pct = round(saved / original * 100) if original else 0

    db = get_db()
    db.execute(
        "INSERT INTO runs (machine, cmd, original, filtered, saved, pct, ts) VALUES (?,?,?,?,?,?,?)",
        (machine, cmd[:60], original, filtered_tokens, saved, pct, int(time.time()))
    )
    db.commit()
    db.close()

    return {"filtered": filtered, "saved": saved, "pct": pct}


@app.get("/api/gain")
def api_gain():
    db = get_db()
    row = db.execute("SELECT SUM(original) as to_, SUM(saved) as ts, COUNT(*) as runs FROM runs").fetchone()
    total_original = row["to_"] or 0
    total_saved = row["ts"] or 0
    runs = row["runs"] or 0
    pct = round(total_saved / total_original * 100) if total_original else 0

    machines = db.execute("""
        SELECT machine, COUNT(*) as runs, SUM(saved) as total_saved,
               ROUND(AVG(pct)) as avg_pct
        FROM runs GROUP BY machine ORDER BY total_saved DESC
    """).fetchall()

    recent = db.execute("""
        SELECT cmd, saved, pct, ts FROM runs ORDER BY ts DESC LIMIT 20
    """).fetchall()
    db.close()

    return {
        "total_original": total_original,
        "total_saved": total_saved,
        "runs": runs,
        "pct": pct,
        "machines": [dict(m) for m in machines],
        "recent": [dict(r) for r in recent],
    }


@app.get("/dashboard", response_class=HTMLResponse)
def dashboard():
    return HTMLResponse("""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>OTK Dashboard</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: 'Courier New', monospace; background: #0d1117; color: #c9d1d9; min-height: 100vh; }
  header { background: #161b22; border-bottom: 1px solid #30363d; padding: 1.2rem 2rem; display: flex; align-items: center; gap: 1rem; }
  header h1 { font-size: 1.4rem; color: #58a6ff; }
  header span { font-size: .85rem; color: #8b949e; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 1rem; padding: 2rem; }
  .card { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 1.5rem; }
  .card .label { font-size: .75rem; color: #8b949e; text-transform: uppercase; letter-spacing: .05em; }
  .card .value { font-size: 2rem; font-weight: bold; color: #3fb950; margin-top: .3rem; }
  .card .sub { font-size: .8rem; color: #8b949e; margin-top: .2rem; }
  .section { padding: 0 2rem 2rem; }
  .section h2 { font-size: 1rem; color: #8b949e; margin-bottom: 1rem; text-transform: uppercase; letter-spacing: .05em; }
  table { width: 100%; border-collapse: collapse; }
  th { text-align: left; font-size: .75rem; color: #8b949e; padding: .5rem; border-bottom: 1px solid #30363d; }
  td { padding: .5rem; font-size: .85rem; border-bottom: 1px solid #21262d; }
  .bar { background: #0d1117; border-radius: 4px; height: 6px; margin-top: 4px; }
  .bar-fill { background: #3fb950; height: 6px; border-radius: 4px; }
  .spent { color: #f85149; }
  #title-bar { display: none; }
</style>
</head>
<body>
<header>
  <h1>OTK — Token Savings</h1>
  <span id="updated">Loading...</span>
</header>
<div class="grid">
  <div class="card"><div class="label">Tokens Saved</div><div class="value" id="saved">—</div><div class="sub" id="pct">—</div></div>
  <div class="card"><div class="label">Cost Saved (Claude)</div><div class="value" id="cost">—</div><div class="sub">@ $3/1M tokens</div></div>
  <div class="card"><div class="label">Total Runs</div><div class="value" id="runs">—</div><div class="sub">commands filtered</div></div>
  <div class="card"><div class="label">Machines</div><div class="value" id="machines">—</div><div class="sub">connected</div></div>
</div>
<div class="section">
  <h2>Machines</h2>
  <table><thead><tr><th>Machine</th><th>Runs</th><th>Tokens Saved</th><th>Avg %</th></tr></thead>
  <tbody id="machines-table"></tbody></table>
</div>
<div class="section">
  <h2>Recent Commands</h2>
  <table><thead><tr><th>Command</th><th>Saved</th><th>%</th></tr></thead>
  <tbody id="recent-table"></tbody></table>
</div>
<script>
async function load() {
  const r = await fetch('/api/gain');
  const d = await r.json();
  const fmt = n => n >= 1000 ? (n/1000).toFixed(1)+'K' : n;
  const cost = (d.total_saved * 3 / 1000000).toFixed(4);
  document.getElementById('saved').textContent = fmt(d.total_saved);
  document.getElementById('pct').textContent = d.pct + '% reduction';
  document.getElementById('cost').textContent = '$' + cost;
  document.getElementById('runs').textContent = d.runs;
  document.getElementById('machines').textContent = d.machines.length;
  document.getElementById('updated').textContent = 'Updated ' + new Date().toLocaleTimeString();
  document.title = 'YOU HAVE SAVED: ' + fmt(d.total_saved) + ' tokens | OTK';
  const mt = document.getElementById('machines-table');
  mt.innerHTML = d.machines.map(m =>
    `<tr><td>${m.machine}</td><td>${m.runs}</td><td>${fmt(m.total_saved)}</td>
     <td><div>${m.avg_pct}%</div><div class="bar"><div class="bar-fill" style="width:${m.avg_pct}%"></div></div></td></tr>`
  ).join('');
  const rt = document.getElementById('recent-table');
  rt.innerHTML = d.recent.map(r =>
    `<tr><td>${r.cmd}</td><td>${fmt(r.saved)}</td><td>${r.pct}%</td></tr>`
  ).join('');
}
load();
setInterval(load, 10000);
</script>
</body>
</html>""")


@app.get("/")
def root():
    return {"status": "ok", "service": "OTK Server", "endpoints": ["/api/gain", "/api/filter", "/dashboard"]}
