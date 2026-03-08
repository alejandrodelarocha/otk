#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  OTK Client Installer — All AI Tools
#  Works with: Claude Code · Cursor · VS Code · any terminal
#
#  Usage: curl -fsSL https://alejandrodelarocha.com/otk/install | bash
# ═══════════════════════════════════════════════════════════

set -e

OTK_SERVER=""
OTK_BIN="$HOME/.local/bin/otk"
OTK_CFG="$HOME/.config/otk/config.toml"
MACHINE=$(hostname)

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[0;33m'; DIM='\033[2m'; NC='\033[0m'
step()  { echo -e "\n${BLUE}▶ $1${NC}"; }
ok()    { echo -e "  ${GREEN}✓ $1${NC}"; }
skip()  { echo -e "  ${DIM}– $1${NC}"; }
warn()  { echo -e "  ${YELLOW}⚠ $1${NC}"; }

echo -e "\n${GREEN}⚡ OTK — All AI Tools Installer${NC}"
echo -e "${DIM}Machine: $MACHINE${NC}\n"

# ── 0. VPS prompt ─────────────────────────────────────────────
USER_VPS="${1:-${OTK_SERVER_URL:-}}"
if [ -z "$USER_VPS" ]; then
  while true; do
    printf "Enter your VPS URL: "
    read -r USER_VPS 2>/dev/null || { warn "No TTY — pass URL as arg: bash otk-install.sh https://yourserver.com"; exit 1; }
    [ -n "$USER_VPS" ] && break
    warn "VPS URL is required."
  done
fi
OTK_SERVER="${USER_VPS%/}"
ok "Using VPS: $OTK_SERVER"
echo ""

# ── 1. OTK binary ────────────────────────────────────────────
step "Installing OTK binary..."
mkdir -p "$HOME/.local/bin"
cat > "$OTK_BIN" << 'PYEOF'
#!/usr/bin/env python3
"""OTK - AI Token Killer (multi-tool client)"""
import sys, subprocess, re, json, os, time, socket
from pathlib import Path

ANALYTICS = Path.home() / ".config/otk/analytics.json"

def get_server():
    cfg = Path.home() / ".config/otk/config.toml"
    if "OTK_SERVER" in os.environ:
        return os.environ["OTK_SERVER"]
    if cfg.exists():
        for line in cfg.read_text().splitlines():
            if line.startswith("server_url"):
                return line.split("=",1)[1].strip().strip('"')
    return None

def strip_ansi(t): return re.sub(r'\x1b\[[0-9;]*[mKHJABCDGsu]','',t)
def dedup(lines):
    seen,out = set(),[]
    for l in lines:
        if l not in seen: seen.add(l); out.append(l)
    return out
def truncate(lines, n=80):
    if len(lines)<=n: return lines
    h=n//2; return lines[:h]+[f"...({len(lines)-n} omitted)..."]+lines[-h:]

def filter_git(out, sub):
    lines = out.splitlines()
    if sub=="diff": return "\n".join(l for l in lines if l.startswith(("diff --git","---","+++","@@","+","-","index ")))
    if sub in("log","reflog"): return "\n".join(lines[:40])
    return out
def filter_npm(out, sub):
    lines = [l for l in out.splitlines() if not re.match(r'^npm (warn|notice|timing|http)',l,re.I)]
    if sub in("install","i","ci"):
        s=[l for l in lines if re.match(r'added|removed|changed|audited|found',l)]
        return "\n".join(s) if s else "\n".join(truncate(lines))
    return "\n".join(truncate(lines))
def filter_docker(out, sub):
    lines = out.splitlines()
    if sub=="build": return "\n".join(l for l in lines if re.match(r'Step \d+|ERROR|-->',l))
    return "\n".join(truncate(lines))
def filter_generic(out):
    lines = [l for l in strip_ansi(out).splitlines() if l.strip()]
    return "\n".join(truncate(dedup(lines)))
def filter_output(cmd, raw):
    if not cmd: return filter_generic(raw)
    base = cmd[0].split("/")[-1]; sub = cmd[1] if len(cmd)>1 else ""
    clean = strip_ansi(raw)
    if base=="git": return filter_git(clean, sub)
    if base in("npm","pnpm","yarn"): return filter_npm(clean, sub)
    if base=="docker": return filter_docker(clean, sub)
    return filter_generic(clean)

def count_tokens(t): return max(1, int(len(t)/4.0))

def filter_via_server(cmd, raw):
    import urllib.request
    url = get_server()
    if not url: return None, False
    if len(raw) < 200: return (raw, False)  # too small to bother compressing
    try:
        payload = json.dumps({"cmd":" ".join(cmd),"output":raw,"machine":socket.gethostname()}).encode()
        req = urllib.request.Request(url+"/api/filter", data=payload, headers={"Content-Type":"application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=2) as r:
            d = json.loads(r.read())
            return d["filtered"], d.get("privacy", False)
    except: return None, False

def load_analytics():
    ANALYTICS.parent.mkdir(parents=True, exist_ok=True)
    if ANALYTICS.exists(): return json.loads(ANALYTICS.read_text())
    return {"total_saved":0,"total_original":0,"runs":0,"history":[]}
def save_analytics(d): ANALYTICS.write_text(json.dumps(d,indent=2))
def record(cmd, orig, filt):
    saved=max(0,orig-filt); d=load_analytics()
    d["total_saved"]+=saved; d["total_original"]+=orig; d["runs"]+=1
    d["history"].append({"cmd":" ".join(cmd[:3]),"original":orig,"filtered":filt,"saved":saved,"pct":round(saved/orig*100) if orig else 0,"ts":int(time.time())})
    d["history"]=d["history"][-100:]; save_analytics(d)

def cmd_gain(history=False, model="claude-sonnet"):
    PRICES={"claude-sonnet":3.0,"claude-opus":15.0,"gpt-4o":2.5,"gpt-4":30.0,"gpt-4o-mini":0.15,"gemini-flash":0.075,"gemini-pro":1.25}
    price=PRICES.get(model,3.0)
    BLUE="\033[0;34m"; DIM="\033[2m"; NC="\033[0m"; BOLD="\033[1m"
    import urllib.request
    url=get_server()
    if url:
        try:
            with urllib.request.urlopen(url+"/api/gain",timeout=3) as r:
                d=json.loads(r.read())
            saved=d["total_saved"]; runs=d["runs"]; pct=d["pct"]
            cost=saved*price/1_000_000
            print(f"OTK Savings [{model} @ ${price}/1M] — SERVER"); print("─"*44)
            print(f"  Runs:       {runs:,}")
            print(f"  Saved:      {BLUE}{BOLD}{saved:,} tokens ({pct}%){NC}")
            print(f"  Cost saved: {BLUE}{BOLD}${cost:.6f}{NC}")
            if history and d.get("recent"):
                print("\nRecent:")
                [print(f"  {e['cmd']:<30} {BLUE}-{e['pct']}%{NC}") for e in d["recent"][:10]]
            return
        except: pass
    d=load_analytics(); saved=d["total_saved"]; runs=d["runs"]
    pct=round(saved/d["total_original"]*100) if d["total_original"] else 0
    print(f"OTK Savings [{model} @ ${price}/1M] — LOCAL"); print("─"*44)
    print(f"  Runs:  {runs:,}")
    print(f"  Saved: {BLUE}{BOLD}{saved:,} tokens ({pct}%){NC}")
    print(f"  Cost:  {BLUE}{BOLD}${saved*price/1_000_000:.6f}{NC}")
    if history: [print(f"  {e['cmd']:<30} {BLUE}-{e['pct']}%{NC}") for e in reversed(d["history"][-10:])]

def main():
    args=sys.argv[1:]
    if not args: print(__doc__); sys.exit(0)
    if args[0]=="gain":
        model="claude-sonnet"
        for i,a in enumerate(args):
            if a=="--model" and i+1<len(args): model=args[i+1]
        cmd_gain("--history" in args, model); return
    if args[0]=="proxy": sys.exit(subprocess.run(args[1:]).returncode)
    try:
        result=subprocess.run(args,capture_output=True,text=True)
    except FileNotFoundError:
        print(f"otk: command not found: {args[0]}",file=sys.stderr); sys.exit(127)
    raw=result.stdout+result.stderr
    filtered,privacy=filter_via_server(args,raw)
    if filtered is None:
        print("otk: server unreachable — check your connection or visit "+str(get_server()),file=sys.stderr); sys.exit(1)
    orig_tok=count_tokens(raw); filt_tok=count_tokens(filtered)
    record(args,orig_tok,filt_tok)
    BLUE="\033[0;34m"; DIM="\033[2m"; NC="\033[0m"; YELLOW="\033[0;33m"
    print(f"{BLUE}{filtered}{NC}",end="" if filtered.endswith("\n") else "\n")
    if privacy:
        print(f"{DIM}  ⚡ otk: {YELLOW}skipped AI — sensitive data detected (privacy){NC}",file=sys.stderr)
    else:
        saved=max(0,orig_tok-filt_tok); pct=round(saved/orig_tok*100) if orig_tok else 0
        import urllib.request
        url=get_server()
        gs,gr,gp=0,0,0
        if url:
            try:
                with urllib.request.urlopen(url+"/api/gain",timeout=1) as r:
                    gd=json.loads(r.read()); gs=gd.get("total_saved",0); gr=gd.get("runs",0); gp=gd.get("pct",0)
            except: pass
        if gs==0:
            ga=load_analytics(); gs=ga["total_saved"]; gr=ga["runs"]; gp=round(gs/ga["total_original"]*100) if ga["total_original"] else 0
        gcost=gs*3.0/1_000_000
        if saved==0:
            print(f"{DIM}  ⚡ otk: nothing to compress ({orig_tok:,} tokens) · total {BLUE}{gs:,} saved ({gp}%) ${gcost:.4f}{NC}{DIM} across {gr} runs{NC}",file=sys.stderr)
        else:
            print(f"{DIM}  ⚡ otk: {BLUE}{saved:,} tokens saved ({pct}%){NC}{DIM} · {orig_tok:,}→{filt_tok:,} · total {gs:,} saved ({gp}%) ${gcost:.4f} across {gr} runs{NC}",file=sys.stderr)
    sys.exit(result.returncode)

if __name__=="__main__": main()
PYEOF
chmod +x "$OTK_BIN"
ok "OTK binary → $OTK_BIN"

# ── 2. Config ─────────────────────────────────────────────────
step "Writing config..."
mkdir -p "$(dirname "$OTK_CFG")"
cat > "$OTK_CFG" << EOF
server_url = "$OTK_SERVER"
machine    = "$MACHINE"
EOF
ok "Config → $OTK_CFG"

# ── 3. Shell functions (zsh + bash + fish) ────────────────────
step "Installing shell functions..."

OTK_SHELL_BLOCK='
# ── OTK: funnels commands through token killer ───────────────
export PATH="$HOME/.local/bin:$PATH"
_OTK_CMDS=(git npm pnpm yarn docker pip cargo)
for _cmd in "${_OTK_CMDS[@]}"; do
  eval "function $_cmd() { otk $_cmd \"\$@\"; }"
done
unset _cmd _OTK_CMDS
# ─────────────────────────────────────────────────────────────
'

for RC in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
  if [ -f "$RC" ] && ! grep -q "OTK: funnels" "$RC"; then
    echo "$OTK_SHELL_BLOCK" >> "$RC"; ok "Added to $(basename $RC)"
  elif [ -f "$RC" ]; then skip "$(basename $RC) already configured"; fi
done

# Fish shell
FISH_CONF="$HOME/.config/fish/conf.d/otk.fish"
if command -v fish &>/dev/null; then
  mkdir -p "$(dirname "$FISH_CONF")"
  cat > "$FISH_CONF" << 'FISHEOF'
# OTK — token killer for fish shell
set -gx PATH $HOME/.local/bin $PATH
for cmd in git npm pnpm yarn docker pip cargo
  function $cmd --wraps $cmd
    otk $cmd $argv
  end
end
FISHEOF
  ok "Fish shell → $FISH_CONF"
fi

# ── 4. Claude Code hook ───────────────────────────────────────
step "Claude Code..."
CLAUDE_HOOK="$HOME/.claude/hooks/otk-rewrite.sh"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
if [ -d "$HOME/.claude" ]; then
  mkdir -p "$HOME/.claude/hooks"
  cat > "$CLAUDE_HOOK" << 'HOOKEOF'
#!/usr/bin/env bash
if ! command -v jq &>/dev/null || ! command -v otk &>/dev/null; then exit 0; fi
INPUT=$(cat); CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[ -z "$CMD" ] && exit 0
BASE=$(echo "$CMD" | awk '{print $1}' | sed 's|.*/||')

# Shell builtins and TTY-requiring commands — never wrap with otk
SKIP="cd export source alias unset set pwd exit return true false type builtin command eval exec vim nano less more top htop ssh python python3 node ruby irb psql mysql sqlite3 watch man ftp sftp telnet screen tmux"

rewrite() {
  local cmd="$1"
  UPDATED=$(echo "$INPUT" | jq -c --arg cmd "$cmd" '.tool_input.command = $cmd')
  jq -n --argjson u "$(echo $UPDATED | jq -c '.tool_input')" \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"OTK","updatedInput":$u}}'
}

# Already wrapped
echo "$CMD" | grep -q "^otk " && exit 0

# Handle "cd X && real_cmd args" pattern — wrap just the real_cmd
if echo "$CMD" | grep -qE '^cd [^ ]+ && ' && ! echo "$SKIP" | grep -qw "$BASE"; then
  REST=$(echo "$CMD" | sed 's/^cd [^ ]* && //')
  REST_BASE=$(echo "$REST" | awk '{print $1}' | sed 's|.*/||')
  if ! echo "$SKIP" | grep -qw "$REST_BASE" && ! echo "$REST" | grep -q "^otk "; then
    NEW_CMD=$(echo "$CMD" | sed "s|&& ${REST}|\&\& otk ${REST}|")
    rewrite "$NEW_CMD"
  fi
  exit 0
fi

# Skip builtins and TTY commands
echo "$SKIP" | grep -qw "$BASE" && exit 0

# Wrap everything else
rewrite "otk $CMD"
HOOKEOF
  chmod +x "$CLAUDE_HOOK"
  if [ -f "$CLAUDE_SETTINGS" ]; then
    python3 - << PYEOF
import json, pathlib
p = pathlib.Path("$CLAUDE_SETTINGS")
d = json.loads(p.read_text())
d.setdefault("hooks", {}).setdefault("PreToolUse", [])
d["hooks"]["PreToolUse"] = [h for h in d["hooks"]["PreToolUse"] if "rtk" not in str(h) and "otk" not in str(h)]
d["hooks"]["PreToolUse"].append({"matcher":"Bash","hooks":[{"type":"command","command":"$CLAUDE_HOOK"}]})
p.write_text(json.dumps(d, indent=2))
PYEOF
    ok "Claude Code hook registered"
  else
    ok "Hook installed (settings.json not found — add hook manually)"
  fi
else
  skip "Claude Code not found"
fi

# ── 5. VS Code ────────────────────────────────────────────────
step "VS Code..."
VSCODE_SETTINGS="$HOME/Library/Application Support/Code/User/settings.json"
if [ ! -f "$VSCODE_SETTINGS" ]; then
  VSCODE_SETTINGS="$HOME/.config/Code/User/settings.json"
fi
if [ -f "$VSCODE_SETTINGS" ]; then
  python3 - << PYEOF
import json, pathlib
p = pathlib.Path("$VSCODE_SETTINGS")
d = json.loads(p.read_text()) if p.exists() else {}
# Set integrated terminal to load OTK shell functions
d["terminal.integrated.env.osx"]  = d.get("terminal.integrated.env.osx", {})
d["terminal.integrated.env.linux"] = d.get("terminal.integrated.env.linux", {})
d["terminal.integrated.env.osx"]["PATH"]   = "$HOME/.local/bin:" + d["terminal.integrated.env.osx"].get("PATH","") + ":\${env:PATH}"
d["terminal.integrated.env.linux"]["PATH"] = "$HOME/.local/bin:" + d["terminal.integrated.env.linux"].get("PATH","") + ":\${env:PATH}"
# Tasks: wrap common commands
tasks_file = p.parent / "tasks.json"
tasks = json.loads(tasks_file.read_text()) if tasks_file.exists() else {"version":"2.0.0","tasks":[]}
otk_tasks = [
    {"label":f"OTK: {cmd}","type":"shell","command":f"otk {cmd}","args":["\${input:args}"],"group":"build"}
    for cmd in ["git status","git log","docker ps","npm install"]
]
existing_labels = {t["label"] for t in tasks["tasks"]}
tasks["tasks"] += [t for t in otk_tasks if t["label"] not in existing_labels]
tasks_file.write_text(json.dumps(tasks, indent=2))
p.write_text(json.dumps(d, indent=2))
print("ok")
PYEOF
  ok "VS Code terminal PATH + tasks configured"
else
  skip "VS Code settings not found"
fi

# ── 6. Cursor ─────────────────────────────────────────────────
step "Cursor..."
CURSOR_SETTINGS="$HOME/Library/Application Support/Cursor/User/settings.json"
if [ ! -f "$CURSOR_SETTINGS" ]; then
  CURSOR_SETTINGS="$HOME/.config/Cursor/User/settings.json"
fi
if [ -f "$CURSOR_SETTINGS" ]; then
  python3 - << PYEOF
import json, pathlib
p = pathlib.Path("$CURSOR_SETTINGS")
d = json.loads(p.read_text()) if p.exists() else {}
d["terminal.integrated.env.osx"]  = d.get("terminal.integrated.env.osx", {})
d["terminal.integrated.env.linux"] = d.get("terminal.integrated.env.linux", {})
d["terminal.integrated.env.osx"]["PATH"]   = "$HOME/.local/bin:\${env:PATH}"
d["terminal.integrated.env.linux"]["PATH"] = "$HOME/.local/bin:\${env:PATH}"
# Cursor rules — tell the AI to be aware of OTK
rules_file = pathlib.Path.home() / ".cursorrules"
existing = rules_file.read_text() if rules_file.exists() else ""
if "OTK" not in existing:
    rules_file.write_text(existing + "\n\n# OTK\nAll shell commands (git, npm, docker, etc.) are automatically routed through OTK (token killer). Output may be truncated/filtered to save tokens. This is expected behavior.\n")
p.write_text(json.dumps(d, indent=2))
print("ok")
PYEOF
  ok "Cursor terminal PATH + .cursorrules configured"
elif command -v cursor &>/dev/null; then
  warn "Cursor binary found but settings not located"
else
  skip "Cursor not found"
fi

# ── 7. Local API proxy (optional) ────────────────────────────
step "Local API proxy..."
PROXY_BIN="$HOME/.local/bin/otk-proxy"
cat > "$PROXY_BIN" << 'PROXYEOF'
#!/usr/bin/env python3
"""
OTK Proxy — intercepts OpenAI/Anthropic/Google API calls,
filters tool results before forwarding. Run on localhost:8765.

Configure your AI tool to use:
  OpenAI base URL:    http://localhost:8765/openai
  Anthropic base URL: http://localhost:8765/anthropic
"""
import sys
try:
    from fastapi import FastAPI, Request
    from fastapi.responses import JSONResponse, StreamingResponse
    import uvicorn, httpx, json, re
except ImportError:
    print("Installing dependencies...")
    import subprocess
    subprocess.run([sys.executable, "-m", "pip", "install", "fastapi", "uvicorn", "httpx", "-q"])
    from fastapi import FastAPI, Request
    from fastapi.responses import JSONResponse
    import uvicorn, httpx, json, re

app = FastAPI(title="OTK Proxy")

def filter_tool_result(content: str) -> str:
    lines = [l for l in content.splitlines() if l.strip()]
    if len(lines) > 80:
        h = 40
        lines = lines[:h] + [f"... ({len(lines)-80} lines filtered by OTK) ..."] + lines[-h:]
    return "\n".join(lines)

def filter_messages(messages: list) -> list:
    filtered = []
    for msg in messages:
        if isinstance(msg.get("content"), list):
            new_content = []
            for block in msg["content"]:
                if block.get("type") == "tool_result":
                    for part in block.get("content", []):
                        if part.get("type") == "text":
                            part["text"] = filter_tool_result(part["text"])
                new_content.append(block)
            msg = {**msg, "content": new_content}
        elif isinstance(msg.get("content"), str) and msg.get("role") == "tool":
            msg = {**msg, "content": filter_tool_result(msg["content"])}
        filtered.append(msg)
    return filtered

@app.post("/openai/{path:path}")
async def proxy_openai(path: str, request: Request):
    body = await request.json()
    if "messages" in body:
        body["messages"] = filter_messages(body["messages"])
    async with httpx.AsyncClient() as client:
        headers = dict(request.headers)
        headers.pop("host", None)
        r = await client.post(f"https://api.openai.com/{path}", json=body, headers=headers, timeout=60)
        return JSONResponse(r.json(), status_code=r.status_code)

@app.post("/anthropic/{path:path}")
async def proxy_anthropic(path: str, request: Request):
    body = await request.json()
    if "messages" in body:
        body["messages"] = filter_messages(body["messages"])
    async with httpx.AsyncClient() as client:
        headers = dict(request.headers)
        headers.pop("host", None)
        r = await client.post(f"https://api.anthropic.com/{path}", json=body, headers=headers, timeout=60)
        return JSONResponse(r.json(), status_code=r.status_code)

@app.get("/")
async def info():
    return {"status":"OTK Proxy running","openai":"http://localhost:8765/openai","anthropic":"http://localhost:8765/anthropic"}

if __name__ == "__main__":
    print("OTK Proxy — listening on http://localhost:8765")
    print("  OpenAI base URL:    http://localhost:8765/openai")
    print("  Anthropic base URL: http://localhost:8765/anthropic")
    uvicorn.run(app, host="127.0.0.1", port=8765)
PROXYEOF
chmod +x "$PROXY_BIN"
ok "API proxy → $PROXY_BIN  (run: otk-proxy)"

# ── 8. Verify ─────────────────────────────────────────────────
step "Testing server connection..."
if curl -sf --max-time 5 "$OTK_SERVER/api/gain" > /dev/null; then
  ok "Server reachable: $OTK_SERVER"
else
  warn "Server unreachable — local filtering will be used as fallback"
fi

# ── Summary ───────────────────────────────────────────────────
echo -e "\n${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ⚡ OTK installed — $MACHINE${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo "  Reload shell:      source ~/.zshrc"
echo "  Check savings:     otk gain"
echo "  Dashboard:         $OTK_SERVER/"
echo "  API proxy:         otk-proxy  (then point tools to localhost:8765)"
echo ""
echo -e "${DIM}  Configured:${NC}"
[ -d "$HOME/.claude" ]            && echo "  ✓ Claude Code (PreToolUse hook)"
[ -f "$VSCODE_SETTINGS" ]         && echo "  ✓ VS Code (terminal PATH + tasks)"
[ -f "$CURSOR_SETTINGS" ]         && echo "  ✓ Cursor (terminal PATH + .cursorrules)"
command -v fish &>/dev/null        && echo "  ✓ Fish shell"
                                      echo "  ✓ Zsh / Bash (shell functions)"
                                      echo "  ✓ OTK API proxy (localhost:8765)"
echo ""
