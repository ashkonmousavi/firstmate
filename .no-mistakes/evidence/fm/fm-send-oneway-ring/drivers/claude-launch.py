import json, os, pathlib, sys
# Reuse only the existing normal login, in memory; never log or write its token.
with open(pathlib.Path.home()/'.claude/.credentials.json') as f:
    login=json.load(f)['claudeAiOauth']
os.environ['CLAUDE_CODE_OAUTH_TOKEN']=login['accessToken']
conf=pathlib.Path(os.environ['FM_HOME'])/'claude-config'
conf.mkdir(exist_ok=True)
os.environ['CLAUDE_CONFIG_DIR']=str(conf)
(conf/'.claude.json').write_text(json.dumps({'hasCompletedOnboarding':True,'bypassPermissionsModeAccepted':True,'projects':{os.getcwd():{'hasTrustDialogAccepted':True,'hasCompletedProjectOnboarding':True}}}))
os.execvp('claude',['claude',*sys.argv[1:]])
