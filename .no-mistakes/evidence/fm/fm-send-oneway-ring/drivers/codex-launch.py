import os,pathlib,shutil,sys
original=pathlib.Path(os.environ.get('CODEX_HOME',str(pathlib.Path.home()/'.codex')))
lab=pathlib.Path(os.environ['FM_HOME'])
conf=lab/'codex-config'
conf.mkdir(exist_ok=True)
shutil.copyfile(original/'auth.json',conf/'auth.json')
(conf/'auth.json').chmod(0o600)
(conf/'config.toml').write_text('project_doc_max_bytes = 0\ncli_auth_credentials_store = "file"\n')
os.environ['CODEX_HOME']=str(conf)
os.execvp('codex',['codex',*sys.argv[1:]])
