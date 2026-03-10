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

def count_tokens(t):
    try:
        import tiktoken
        return max(1, len(tiktoken.get_encoding("cl100k_base").encode(t)))
    except Exception:
        return max(1, int(len(t)/4.0))

GEMINI_KEY = "AIzaSyCMhKATgGP2gjZ8T3O7DjloZSTf1PGptHk"

def filter_via_gemini(cmd, raw):
    import urllib.request
    if len(raw) < 200: return None, False
    try:
        prompt = f"Compress this CLI output for an AI coding assistant. Keep errors, warnings, key results, and actionable info. Remove noise, progress bars, and repetitive lines. Return ONLY the filtered output, no explanation.\n\nCommand: {' '.join(cmd[:5])}\n\nOutput:\n{raw[:8000]}"
        payload = json.dumps({"contents":[{"parts":[{"text":prompt}]}],"generationConfig":{"maxOutputTokens":2000,"temperature":0.1}}).encode()
        req = urllib.request.Request(
            f"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key={GEMINI_KEY}",
            data=payload, headers={"Content-Type":"application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=5) as r:
            d = json.loads(r.read())
            text = d["candidates"][0]["content"]["parts"][0]["text"]
            return text.strip(), False
    except: return None, False

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
    ga=load_analytics(); ls=ga["total_saved"]; lr=ga["runs"]; lo=ga["total_original"]
    if url:
        try:
            key=get_api_key()
            headers={"X-OTK-Key":key} if key else {}
            req=urllib.request.Request(url+"/api/gain",headers=headers)
            with urllib.request.urlopen(req,timeout=1) as r:
                gd=json.loads(r.read())
                ss,sr=gd.get("total_saved",0),gd.get("runs",0)
                gs=ls+ss; gr=lr+sr
                so=ss*100//max(gd.get("pct",1),1) if gd.get("pct") else 0
                go=lo+so
                gp=round(gs/go*100) if go else 0
                GAIN_CACHE.parent.mkdir(parents=True,exist_ok=True)
                GAIN_CACHE.write_text(json.dumps({"gs":gs,"gr":gr,"gp":gp,"ts":time.time()}))
                return gs,gr,gp
        except: pass
    gp=round(ls/lo*100) if lo else 0
    return ls,lr,gp

def record(cmd, orig, filt):
    saved=max(0,orig-filt); d=load_analytics()
    d["total_saved"]+=saved; d["total_original"]+=orig; d["runs"]+=1
    d["history"].append({"cmd":" ".join(cmd[:3]),"original":orig,"filtered":filt,"saved":saved,"pct":round(saved/orig*100) if orig else 0,"ts":int(time.time())})
    d["history"]=d["history"][-100:]; save_analytics(d)
    # Sync to server (fire-and-forget)
    try:
        import urllib.request
        url=get_server(); key=get_api_key()
        if url:
            payload=json.dumps({"cmd":" ".join(cmd[:3]),"original":orig,"filtered":filt,"saved":saved,"machine":socket.gethostname()}).encode()
            hd={"Content-Type":"application/json"}
            if key: hd["X-OTK-Key"]=key
            req=urllib.request.Request(url+"/api/record",data=payload,headers=hd,method="POST")
            urllib.request.urlopen(req,timeout=2)
    except: pass

def cmd_gain(history=False, model="claude-sonnet"):
    PRICES={"claude-sonnet":3.0,"claude-opus":15.0,"gpt-4o":2.5,"gpt-4":30.0,"gpt-4o-mini":0.15,"gemini-flash":0.075,"gemini-pro":1.25}
    price=PRICES.get(model,3.0)
    BLUE="\033[0;34m"; DIM="\033[2m"; NC="\033[0m"; BOLD="\033[1m"
    import urllib.request
    url=get_server()
    # Load local stats
    ld=load_analytics(); l_saved=ld["total_saved"]; l_runs=ld["runs"]; l_orig=ld["total_original"]
    # Try server stats
    s_saved=s_runs=0; has_server=False
    if url:
        try:
            key=get_api_key()
            _h={"X-OTK-Key":key} if key else {}
            with urllib.request.urlopen(urllib.request.Request(url+"/api/gain",headers=_h),timeout=3) as r:
                sd=json.loads(r.read())
            s_saved=sd.get("total_saved",0); s_runs=sd.get("runs",0)
            has_server=True
        except: pass
    # Combine
    saved=l_saved+s_saved; runs=l_runs+s_runs
    pct=round(saved/l_orig*100) if l_orig else 0
    cost=saved*price/1_000_000
    src="LOCAL+VPS" if has_server else "LOCAL"
    print(f"OTK Savings [{model} @ ${price}/1M] -- {src}"); print("-"*44)
    print(f"  Runs:       {runs:,}")
    print(f"  Saved:      {BLUE}{BOLD}{saved:,} tokens ({pct}%){NC}")
    print(f"  Cost saved: {BLUE}{BOLD}${cost:.6f}{NC}")
    if has_server:
        print(f"  {DIM}(local: {l_saved:,} | vps: {s_saved:,}){NC}")
    if history:
        print("\nRecent (local):")
        for e in reversed(ld.get("history",[])[-10:]):
            print(f"  {e['cmd']:<30} {BLUE}-{e['pct']}%{NC}")

def cmd_ping():
    import urllib.request
    url=get_server()
    if not url: print("otk: no server configured",file=sys.stderr); sys.exit(1)
    try:
        payload=json.dumps({"machine":socket.gethostname(),"event":"ping"}).encode()
        req=urllib.request.Request(url+"/api/ping",data=payload,headers={"Content-Type":"application/json"},method="POST")
        urllib.request.urlopen(req,timeout=3)
        print("✓ Dashboard pinged")
    except Exception as e:
        print(f"otk: ping failed: {e}",file=sys.stderr); sys.exit(1)

def check_auth():
    key = get_api_key()
    if not key: return True  # no key configured = local-only mode
    auth_file = Path.home() / ".config/otk/.authenticated"
    if auth_file.exists():
        stored = auth_file.read_text().strip()
        if stored == key: return True
    # Key exists in config -- auto-authenticate (user already has it)
    auth_file.parent.mkdir(parents=True, exist_ok=True)
    auth_file.write_text(key)
    return True

def main():
    args=sys.argv[1:]
    if not args: print(__doc__); sys.exit(0)
    if args[0]=="gain":
        model="claude-sonnet"
        for i,a in enumerate(args):
            if a=="--model" and i+1<len(args): model=args[i+1]
        check_auth()
        cmd_gain("--history" in args, model); return
    if args[0]=="ping": check_auth(); cmd_ping(); return
    if args[0]=="proxy": check_auth(); sys.exit(subprocess.run(args[1:]).returncode)
    check_auth()
    try:
        result=subprocess.run(args,capture_output=True,text=True)
    except FileNotFoundError:
        print(f"otk: command not found: {args[0]}",file=sys.stderr); sys.exit(127)
    raw=result.stdout+result.stderr
    filtered,privacy=filter_via_server(args,raw)
    if filtered is None:
        filtered,privacy=filter_via_gemini(args,raw)
    if filtered is None:
        filtered=filter_output(args,raw); privacy=False
    orig_tok=count_tokens(raw); filt_tok=count_tokens(filtered)
    record(args,orig_tok,filt_tok)
    BLUE="\033[0;34m"; DIM="\033[2m"; NC="\033[0m"; YELLOW="\033[0;33m"
    print(f"{BLUE}{filtered}{NC}",end="" if filtered.endswith("\n") else "\n")
    if privacy:
        print(f"{DIM}  * otk: {YELLOW}skipped AI -- sensitive data detected (privacy){NC}",file=sys.stderr)
    else:
        saved=max(0,orig_tok-filt_tok); pct=round(saved/orig_tok*100) if orig_tok else 0
        gs,gr,gp=get_cached_gain(); gcost=gs*3.0/1_000_000
        if saved==0:
            print(f"{DIM}  * otk: nothing to compress ({orig_tok:,} tokens) | total {BLUE}{gs:,} saved ({gp}%) ${gcost:.4f}{NC}{DIM} across {gr} runs{NC}",file=sys.stderr)
        else:
            print(f"{DIM}  * otk: {BLUE}{saved:,} tokens saved ({pct}%){NC}{DIM} | {orig_tok:,}->{filt_tok:,} | total {gs:,} saved ({gp}%) ${gcost:.4f} across {gr} runs{NC}",file=sys.stderr)
    sys.exit(result.returncode)

if __name__=="__main__": main()
