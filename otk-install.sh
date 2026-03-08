#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  OTK Client Installer — All AI Tools
#  Works with: Claude Code · Cursor · VS Code · any terminal
#
#  Usage:
#    curl -fsSL https://alejandrodelarocha.com/otk/install | bash
#    curl -fsSL https://alejandrodelarocha.com/otk/install | bash -s -- https://your-server.com
#    curl -fsSL https://alejandrodelarocha.com/otk/install | bash -s -- --local   # no server
# ═══════════════════════════════════════════════════════════

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

# ── 0. Server URL + API Key ───────────────────────────────────
ARG="${1:-${OTK_SERVER_URL:-}}"
OTK_SERVER=""
OTK_KEY="${OTK_API_KEY:-}"

if [ "$ARG" = "--local" ]; then
  warn "Local-only mode — no server, using built-in filters"
elif [ -n "$ARG" ]; then
  OTK_SERVER="${ARG%/}"
  ok "Using server: $OTK_SERVER"
else
  printf "Enter your OTK server URL (or press Enter for local-only mode): "
  read -r USER_VPS 2>/dev/null || USER_VPS=""
  if [ -n "$USER_VPS" ]; then
    OTK_SERVER="${USER_VPS%/}"
    ok "Using server: $OTK_SERVER"
  else
    warn "No server — using local filtering only"
  fi
fi

if [ -n "$OTK_SERVER" ] && [ -z "$OTK_KEY" ]; then
  printf "Enter API key (or press Enter to skip): "
  read -r OTK_KEY 2>/dev/null || OTK_KEY=""
  [ -n "$OTK_KEY" ] && ok "API key set" || skip "No API key (server must allow unauthenticated access)"
fi

# ── 1. OTK binary ────────────────────────────────────────────
step "Installing OTK binary..."
mkdir -p "$HOME/.local/bin"
cat > "$OTK_BIN" << 'PYEOF'
#!/usr/bin/env python3
"""OTK - AI Token Killer (multi-tool client)"""
import sys, subprocess, re, json, os, time, socket
from pathlib import Path

ANALYTICS = Path.home() / ".config/otk/analytics.json"
GAIN_CACHE = Path.home() / ".config/otk/gain_cache.json"

def get_server():
    cfg = Path.home() / ".config/otk/config.toml"
    if "OTK_SERVER" in os.environ:
        return os.environ["OTK_SERVER"]
    if cfg.exists():
        for line in cfg.read_text().splitlines():
            if line.startswith("server_url"):
                v = line.split("=",1)[1].strip().strip('"')
                return v if v else None
    return None

def get_api_key():
    if "OTK_API_KEY" in os.environ:
        return os.environ["OTK_API_KEY"]
    cfg = Path.home() / ".config/otk/config.toml"
    if cfg.exists():
        for line in cfg.read_text().splitlines():
            if line.startswith("api_key"):
                return line.split("=",1)[1].strip().strip('"')
    return ""

def strip_ansi(t): return re.sub(r'\x1b\[[0-9;]*[mKHJABCDGsu]','',t)
def truncate(lines, n=200):
    if len(lines)<=n: return lines
    h=n//2; return lines[:h]+[f"...({len(lines)-n} omitted)..."]+lines[-h:]

def filter_git(out, sub):
    lines = out.splitlines()
    if sub=="diff":
        return "\n".join(l for l in lines if l and (
            l.startswith(("diff --git","---","+++","@@","index ","new file","deleted file"))
            or (l[0] in ("+","-") and not l.startswith(("---","+++")))
        ))
    if sub in("log","reflog"): return "\n".join(lines[:40])
    if sub=="status":
        result, untracked, uc = [], False, 0
        for l in lines:
            if "Untracked files:" in l: untracked=True; result.append(l)
            elif untracked and l.startswith("\t"):
                uc+=1
                if uc<=10: result.append(l)
                elif uc==11: result.append(f"\t... and more untracked files")
            else: untracked=False; result.append(l)
        return "\n".join(result)
    if sub in("push","fetch","pull"):
        noise = re.compile(r'^(Enumerating|Counting|Compressing|Writing|Total|remote: Counting|remote: Compressing) ')
        return "\n".join(l for l in lines if not noise.match(l))
    return out
def filter_npm(out, sub):
    lines = out.splitlines()
    noise = re.compile(r'^(npm (warn EBADENGINE|timing|http|notice)|WARN deprecated)',re.I)
    filtered = [l for l in lines if not noise.match(l)]
    if sub in("install","i","ci","add"):
        summary=[l for l in filtered if re.search(r'added|removed|changed|packages in',l,re.I)]
        warnings=[l for l in filtered if re.search(r'warn|error',l,re.I)]
        return "\n".join(warnings+summary) if (summary or warnings) else "\n".join(truncate(filtered,20))
    return "\n".join(truncate(filtered))
def filter_docker(out, sub):
    lines = out.splitlines()
    if sub=="build": return "\n".join(l for l in lines if re.match(r'Step \d+|ERROR|-->',l)) or "\n".join(truncate(lines,20))
    if sub=="ps": return "\n".join(truncate(lines,30))
    return "\n".join(truncate(lines))
def filter_test(out):
    lines = out.splitlines()
    noise=re.compile(r'^(test .* \.\.\. ok|\.+$|ok\s+\S+\s+\([\d.]+s\)|\s*PASS\s*$)',re.I)
    important=re.compile(r'(FAIL|ERROR|panic|assert|Exception|Traceback|FAILED|error\[|\d+ (test|passed|failed|error))',re.I)
    keep=[l for l in lines if not noise.match(l.strip()) or important.search(l)]
    for l in lines[-10:]:
        if l not in keep: keep.append(l)
    return "\n".join(truncate(keep,100))
def filter_output(cmd, raw):
    if not cmd: return strip_ansi(raw)
    base=cmd[0].split("/")[-1]; sub=cmd[1] if len(cmd)>1 else ""
    clean=strip_ansi(raw)
    lines=[l for l in clean.splitlines() if l.strip()]
    if base=="git": return filter_git(clean, sub)
    if base in("npm","pnpm","yarn"): return filter_npm(clean, sub)
    if base=="docker": return filter_docker(clean, sub)
    if base in("pytest","py.test"): return filter_test(clean)
    if base=="cargo" and sub=="test": return filter_test(clean)
    if base=="go" and sub=="test": return filter_test(clean)
    if base in("grep","rg","ag"):
        filtered=[l for l in lines if not re.match(r'^(Binary file|grep: )',l)]
        return "\n".join(truncate(filtered,300))
    if base in("ls","tree","find"): return clean  # never truncate file listings
    return "\n".join(truncate(lines,200))

def count_tokens(t): return max(1, int(len(t)/4.0))

def filter_via_server(cmd, raw):
    import urllib.request
    url = get_server()
    if not url: return None, False
    if len(raw) < 200: return (raw, False)
    try:
        payload = json.dumps({"cmd":" ".join(cmd),"output":raw,"machine":socket.gethostname()}).encode()
        headers = {"Content-Type": "application/json"}
        key = get_api_key()
        if key: headers["X-OTK-Key"] = key
        req = urllib.request.Request(url+"/api/filter", data=payload, headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=2) as r:
            d = json.loads(r.read())
            return d["filtered"], d.get("privacy", False)
    except: return None, False

def load_analytics():
    ANALYTICS.parent.mkdir(parents=True, exist_ok=True)
    if ANALYTICS.exists(): return json.loads(ANALYTICS.read_text())
    return {"total_saved":0,"total_original":0,"runs":0,"history":[]}
def save_analytics(d): ANALYTICS.write_text(json.dumps(d,indent=2))

def get_cached_gain():
    import urllib.request
    url = get_server()
    if GAIN_CACHE.exists():
        try:
            c = json.loads(GAIN_CACHE.read_text())
            if time.time() - c.get("ts",0) < 60:
                return c.get("gs",0), c.get("gr",0), c.get("gp",0)
        except: pass
    if url:
        try:
            key=get_api_key()
            headers={"X-OTK-Key":key} if key else {}
            req=urllib.request.Request(url+"/api/gain",headers=headers)
            with urllib.request.urlopen(req,timeout=1) as r:
                gd=json.loads(r.read())
                gs,gr,gp=gd.get("total_saved",0),gd.get("runs",0),gd.get("pct",0)
                GAIN_CACHE.parent.mkdir(parents=True,exist_ok=True)
                GAIN_CACHE.write_text(json.dumps({"gs":gs,"gr":gr,"gp":gp,"ts":time.time()}))
                return gs,gr,gp
        except: pass
    ga=load_analytics(); gs=ga["total_saved"]; gr=ga["runs"]
    gp=round(gs/ga["total_original"]*100) if ga["total_original"] else 0
    return gs,gr,gp

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
            key=get_api_key()
            _h={"X-OTK-Key":key} if key else {}
            with urllib.request.urlopen(urllib.request.Request(url+"/api/gain",headers=_h),timeout=3) as r:
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
        filtered=filter_output(args,raw); privacy=False
    orig_tok=count_tokens(raw); filt_tok=count_tokens(filtered)
    record(args,orig_tok,filt_tok)
    BLUE="\033[0;34m"; DIM="\033[2m"; NC="\033[0m"; YELLOW="\033[0;33m"
    print(f"{BLUE}{filtered}{NC}",end="" if filtered.endswith("\n") else "\n")
    if privacy:
        print(f"{DIM}  ⚡ otk: {YELLOW}skipped AI — sensitive data detected (privacy){NC}",file=sys.stderr)
    else:
        saved=max(0,orig_tok-filt_tok); pct=round(saved/orig_tok*100) if orig_tok else 0
        gs,gr,gp=get_cached_gain(); gcost=gs*3.0/1_000_000
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
api_key    = "$OTK_KEY"
EOF
ok "Config → $OTK_CFG"

# ── 3. Shell functions (zsh + bash + fish) ────────────────────
step "Installing shell functions..."

# Commands to wrap in the terminal (matches Claude Code hook)
OTK_CMDS="git npm pnpm yarn docker pip pip3 cargo pytest ruff go make kubectl helm"

OTK_SHELL_MARKER="# ── OTK token killer"
OTK_SHELL_BLOCK="${OTK_SHELL_MARKER} ──────────────────────────────
[ -f \"\$HOME/.local/bin/otk\" ] && export PATH=\"\$HOME/.local/bin:\$PATH\"
_otk_wrap() { for _c in $OTK_CMDS; do
  eval \"_otk_\${_c}() { \\\$HOME/.local/bin/otk \$_c \\\"\\\$@\\\"; }\"
  alias \$_c=\"_otk_\${_c}\"
done; unset _c; }
_otk_wrap; unset -f _otk_wrap
# ────────────────────────────────────────────────────────────"

for RC in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
  if [ -f "$RC" ]; then
    if grep -q "$OTK_SHELL_MARKER" "$RC"; then
      # Remove old block and re-add updated one
      python3 -c "
import re, pathlib
p = pathlib.Path('$RC')
txt = p.read_text()
txt = re.sub(r'# ── OTK token killer.*?# ──+\n', '', txt, flags=re.DOTALL)
p.write_text(txt)
" 2>/dev/null
    fi
    printf '\n%s\n' "$OTK_SHELL_BLOCK" >> "$RC"
    ok "Updated $(basename $RC)"
  fi
done

# Fish shell
FISH_CONF="$HOME/.config/fish/conf.d/otk.fish"
if command -v fish &>/dev/null; then
  mkdir -p "$(dirname "$FISH_CONF")"
  cat > "$FISH_CONF" << FISHEOF
# OTK — token killer for fish shell
fish_add_path \$HOME/.local/bin
for cmd in $OTK_CMDS
  function \$cmd --wraps \$cmd
    \$HOME/.local/bin/otk \$cmd \$argv
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
if echo "$CMD" | grep -qE '^cd [^ ]+ && '; then
  REST=$(echo "$CMD" | sed 's/^cd [^ ]* && //')
  REST_BASE=$(echo "$REST" | awk '{print $1}' | sed 's|.*/||')
  if ! echo "$SKIP" | grep -qw "$REST_BASE" && ! echo "$REST" | grep -q "^otk "; then
    PREFIX="${CMD%%&&*}&& "
    NEW_CMD="${PREFIX}otk ${REST}"
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
    python3 - << PYEOF2
import json, pathlib
p = pathlib.Path("$CLAUDE_SETTINGS")
try:
    d = json.loads(p.read_text())
except:
    d = {}
d.setdefault("hooks", {}).setdefault("PreToolUse", [])
d["hooks"]["PreToolUse"] = [h for h in d["hooks"]["PreToolUse"] if "rtk" not in str(h) and "otk" not in str(h)]
d["hooks"]["PreToolUse"].append({"matcher":"Bash","hooks":[{"type":"command","command":"$CLAUDE_HOOK"}]})
p.write_text(json.dumps(d, indent=2))
PYEOF2
    ok "Claude Code hook registered"
  else
    ok "Hook installed (no settings.json — hook will activate when Claude Code runs)"
  fi
else
  skip "Claude Code not found"
fi

# ── 5. VS Code ────────────────────────────────────────────────
step "VS Code..."
VSCODE_SETTINGS="$HOME/Library/Application Support/Code/User/settings.json"
[ ! -f "$VSCODE_SETTINGS" ] && VSCODE_SETTINGS="$HOME/.config/Code/User/settings.json"
if [ -f "$VSCODE_SETTINGS" ]; then
  python3 - << PYEOF3
import json, pathlib
p = pathlib.Path("$VSCODE_SETTINGS")
try:
    d = json.loads(p.read_text())
except:
    d = {}
for key in ["terminal.integrated.env.osx","terminal.integrated.env.linux"]:
    d.setdefault(key, {})
    existing = d[key].get("PATH","")
    if "$HOME/.local/bin" not in existing:
        d[key]["PATH"] = "$HOME/.local/bin:\${env:PATH}"
p.write_text(json.dumps(d, indent=2))
print("ok")
PYEOF3
  ok "VS Code terminal PATH configured"
else
  skip "VS Code not found"
fi

# ── 6. Cursor ─────────────────────────────────────────────────
step "Cursor..."
CURSOR_SETTINGS="$HOME/Library/Application Support/Cursor/User/settings.json"
[ ! -f "$CURSOR_SETTINGS" ] && CURSOR_SETTINGS="$HOME/.config/Cursor/User/settings.json"
if [ -f "$CURSOR_SETTINGS" ]; then
  python3 - << PYEOF4
import json, pathlib
p = pathlib.Path("$CURSOR_SETTINGS")
try:
    d = json.loads(p.read_text())
except:
    d = {}
for key in ["terminal.integrated.env.osx","terminal.integrated.env.linux"]:
    d.setdefault(key, {})
    if "$HOME/.local/bin" not in d[key].get("PATH",""):
        d[key]["PATH"] = "$HOME/.local/bin:\${env:PATH}"
rules_file = pathlib.Path.home() / ".cursorrules"
existing = rules_file.read_text() if rules_file.exists() else ""
if "OTK" not in existing:
    rules_file.write_text(existing + "\n\n# OTK\nAll shell commands are routed through OTK (token killer). Filtered output is expected.\n")
p.write_text(json.dumps(d, indent=2))
print("ok")
PYEOF4
  ok "Cursor configured"
else
  skip "Cursor not found"
fi

# ── 7. Verify ─────────────────────────────────────────────────
if [ -n "$OTK_SERVER" ]; then
  step "Testing server connection..."
  HTTP_CODE=$(curl -sf --max-time 5 -o /dev/null -w "%{http_code}" "$OTK_SERVER/api/gain" 2>/dev/null || echo "000")
  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "401" ]; then
    ok "Server reachable: $OTK_SERVER"
  else
    warn "Server unreachable (HTTP $HTTP_CODE) — local filtering will be used as fallback"
  fi
fi

# ── Summary ───────────────────────────────────────────────────
echo -e "\n${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ⚡ OTK installed — $MACHINE${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo "  Reload shell:   source ~/.zshrc"
echo "  Check savings:  otk gain"
[ -n "$OTK_SERVER" ] && echo "  Dashboard:      $OTK_SERVER/dashboard"
echo ""
echo -e "${DIM}  Configured:${NC}"
[ -d "$HOME/.claude" ]        && echo "  ✓ Claude Code (PreToolUse hook — all commands)"
[ -f "$VSCODE_SETTINGS" ]     && echo "  ✓ VS Code"
[ -f "$CURSOR_SETTINGS" ]     && echo "  ✓ Cursor"
command -v fish &>/dev/null    && echo "  ✓ Fish shell"
                                  echo "  ✓ Zsh / Bash (wraps: $OTK_CMDS)"
echo ""
