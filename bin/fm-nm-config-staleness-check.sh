#!/usr/bin/env bash
# Read-only Linux no-mistakes metadata sampler. Usage: <nm-home> <machine>
# Prints one fm-nm-config-age/1 JSON observation; unknown is unavailable.
# Reads config filesystem metadata, PID/start record and local proc identity,
# never config contents, process environment, run logs or pipeline databases.
# Identity is PID plus kernel start ticks, checked before and after sampling.
# Config is stale only beyond current btime + ticks/CLK_TCK + 10 seconds.
# A PID reused before the first sample cannot be distinguished by this record.
# --episode <private-marker>: consume exactly pc/server/zenbook JSON lines on
# stdin, print diagnostics and prompt sorted warnings as changed evidence arrives.
# A sweep may emit growing confirmed stale sets as independent probes finish.
# Call inside the existing check cadence BEFORE its early A/B/D returns.
# Transport failures must supply an unavailable observation for that machine.
# Markers store per-machine digests of label, PID, start ticks and config mtime;
# unchanged episode evidence is quiet. Unknown preserves prior evidence;
# verified current/not_running clears it. No daemon lifecycle is authorized.
# Python 3 is required; unsupported/read-error samples remain unavailable.
set -eu
if [ "$#" -ne 2 ] || [ "$1" = --help ]; then
  echo 'Usage: fm-nm-config-staleness-check.sh <nm-home> <machine> | --episode <private-marker>'
  exit 2
fi
exec python3 -c '
import datetime as dt, hashlib, json, os, re, stat, sys, tempfile
from pathlib import Path

def emit(machine, status, code="", **fields):
    print(json.dumps(dict(schema="fm-nm-config-age/1", machine=machine,
        status=status, diagnostic=code, sampled_at=dt.datetime.now(dt.timezone.utc).isoformat(), **fields)))

def regular(path):
    s=path.lstat()
    if not stat.S_ISREG(s.st_mode) or not s.st_mode & 0o444:
        raise ValueError("unsafe_metadata")
    return s

def record(path):
    regular(path)
    raw=path.read_bytes()
    r=json.loads(raw)
    pid=r["pid"]
    if type(pid) is not int or pid <= 0: raise ValueError("invalid_pid")
    text=r["started_at"]
    if not isinstance(text,str) or not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,9})?Z",text):
        raise ValueError("invalid_start")
    dt.datetime.fromisoformat(text[:-1])
    return raw, pid

def identity(proc,pid):
    p=proc/str(pid)
    comm=(p/"comm").read_text().strip()
    fields=(p/"stat").read_text().rsplit(") ",1)[1].split()
    uid=next(line.split()[1:] for line in (p/"status").read_text().splitlines() if line.startswith("Uid:"))
    if comm != "no-mistakes" or len(uid)!=4 or any(int(x)!=os.getuid() for x in uid) or fields[0] in ("Z","X"):
        raise ValueError("wrong_process")
    return int(fields[19])

def sample(home,machine):
    if not re.fullmatch(r"[a-z][a-z0-9_-]*",machine): raise ValueError("invalid_machine")
    proc=Path(os.environ.get("FM_NM_PROC_ROOT","/proc") if os.environ.get("FM_TEST_SEAM")=="1" else "/proc")
    if not (proc/"stat").exists(): raise ValueError("unsupported_platform")
    path=Path(home)/"daemon.pid"
    if not path.exists() and not path.is_symlink():
        # Missing record alone does not prove there is no running daemon.
        for p in proc.iterdir():
            if p.name.isdigit():
                try:
                    if (p/"comm").read_text().strip()=="no-mistakes":
                        identity(proc,int(p.name))
                        raise ValueError("missing_record")
                except FileNotFoundError: pass
        if path.exists() or path.is_symlink(): raise ValueError("changed_record")
        emit(machine,"not_running"); return
    raw,pid=record(path)
    ticks=identity(proc,pid)
    boot=int(next(line.split()[1] for line in (proc/"stat").read_text().splitlines() if line.startswith("btime ")))
    birth=boot*10**9+ticks*10**9//os.sysconf("SC_CLK_TCK")
    config=Path(home)/"config.yaml"
    s=regular(config)
    if identity(proc,pid)!=ticks or record(path)[0]!=raw: raise ValueError("changed_identity")
    end=regular(config)
    if (s.st_dev,s.st_ino,s.st_mtime_ns,s.st_ctime_ns)!=(end.st_dev,end.st_ino,end.st_mtime_ns,end.st_ctime_ns):
        raise ValueError("changed_config")
    emit(machine,"stale" if s.st_mtime_ns>birth+10*10**9 else "current",pid=pid,
         process_start_ticks=ticks,config_mtime_ns=s.st_mtime_ns)

def episode(marker):
    path=Path(marker)
    if path.is_symlink(): raise ValueError("unsafe_marker")
    old=json.loads(path.read_text()) if path.exists() else {}
    new=dict(old); seen=set(); stale=[]; reported=None
    for line in sys.stdin:
        try:
            r=json.loads(line); machine=r["machine"]
            if r.get("schema")!="fm-nm-config-age/1" or machine not in ("pc","server","zenbook") or machine in seen:
                raise ValueError("invalid_observation")
            status=r["status"]
            if status in ("stale","current"):
                evidence=[machine,r["pid"],r["process_start_ticks"],r["config_mtime_ns"]]
                if any(type(r[k]) is not int or r[k]<0 for k in ("pid","process_start_ticks","config_mtime_ns")) or r["pid"]==0:
                    raise ValueError("invalid_observation")
            elif status not in ("unavailable","not_running"): raise ValueError("invalid_status")
        except (ValueError,KeyError,TypeError):
            print("server-idle-watch: no-mistakes observation unavailable: malformed probe",flush=True)
            continue
        seen.add(machine)
        if status=="unavailable":
            print("server-idle-watch: no-mistakes observation unavailable on: "+machine,flush=True)
        elif status=="stale":
            new[machine]=hashlib.sha256(json.dumps(evidence).encode()).hexdigest(); stale.append(machine)
        else: new.pop(machine,None)
        confirmed={machine:new[machine] for machine in stale}
        if stale and new!=old and confirmed!=reported:
            print("server-idle-watch: no-mistakes config newer than running daemon on: "+", ".join(sorted(stale)),flush=True)
            reported=confirmed
    for machine in sorted({"pc","server","zenbook"}-seen):
        print("server-idle-watch: no-mistakes observation unavailable on: "+machine,flush=True)
    fd,tmp=tempfile.mkstemp(prefix=".nm-config-age-",dir=path.parent)
    try:
        with os.fdopen(fd,"w") as f: json.dump(new,f,sort_keys=True)
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

try:
    if sys.argv[1]=="--episode": episode(sys.argv[2])
    else: sample(sys.argv[1],sys.argv[2])
except (OSError,ValueError,KeyError,TypeError,IndexError,StopIteration):
    if sys.argv[1]=="--episode":
        print("server-idle-watch: no-mistakes observation unavailable: invalid episode metadata")
        sys.exit(1)
    emit(sys.argv[2],"unavailable","unverified_metadata")
' "$@"
