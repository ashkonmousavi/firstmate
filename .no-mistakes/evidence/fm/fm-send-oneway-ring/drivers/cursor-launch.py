import json, os, pathlib, sys
# Normal existing login is read only for in-memory reuse; no token is logged.
base=pathlib.Path.home()
for src in (base/'.config/cursor/auth.json',base/'.cursor/auth.json'):
    if src.is_file():
        auth=json.loads(src.read_text())
        token=auth.get('accessToken') or auth.get('authToken')
        if token:
            os.environ['CURSOR_AUTH_TOKEN']=token
            break
else:
    raise SystemExit('Existing Cursor login was not available at either documented credential location')
conf=pathlib.Path(os.environ['FM_HOME'])/'cursor-config'
conf.mkdir(exist_ok=True)
os.environ['CURSOR_CONFIG_DIR']=str(conf)
os.environ['XDG_CONFIG_HOME']=str(conf/'xdg')
os.execvp('cursor-agent',['cursor-agent',*sys.argv[1:]])
