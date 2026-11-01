import os,subprocess,pathlib,json,time,html
ROOT=pathlib.Path.cwd();LAB=ROOT/".l";EV=pathlib.Path("~/.no-mistakes/evidence/01M6B62AEYX0JQH5T01JDP149M")
ENV=os.environ.copy()
for k in list(ENV):
 if k.startswith(("FM_","HERDR_","CLAUDE_CODE_")) or k in ("CLAUDECODE","TMUX","TMUX_PANE","NO_MISTAKES_GATE"): ENV.pop(k)
ENV.update(FM_HERDR_LAB_STATE_DIR=str(LAB/"herdr-lab"),FM_HOME=str(LAB),CLAUDE_CODE_DISABLE_AGENT_VIEW="1",CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF="1",CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION="false")
NAME=(LAB/"herdr-session").read_text().strip()
def helper(*args):
 p=subprocess.run([str(ROOT/"bin/fm-herdr-lab.sh"),*args],env=ENV,capture_output=True,text=True,timeout=90)
 if p.returncode:raise RuntimeError(str(args)+": "+p.stdout+p.stderr)
 return p.stdout
def run(*args):return helper("run",NAME,*args)
