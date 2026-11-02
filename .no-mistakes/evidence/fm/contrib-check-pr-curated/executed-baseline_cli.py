import json, os, pathlib, shutil, signal, subprocess, time
root=pathlib.Path.cwd()
# Reuse only the disposable data construction and isolated environment from the manual driver.
setup=(root/'.contrib-live-validation/manual_cli.py').read_text().split('\nresults=[]\n',1)[0]
exec(compile(setup,'manual-disposable-setup','exec'))
baseline=root/'bin/.fm-contributions-baseline-validation.sh'
baseline.write_bytes(subprocess.run(['git','show','f145078aeb3f3068169dd29ca7a1f03839fa8ec0:bin/fm-contributions.sh'],capture_output=True,check=True).stdout)
proc=None
try:
    started=time.monotonic()
    proc=subprocess.Popen(['bash',str(baseline),'poll'],env={**env,'FM_CHECK_TIMEOUT':'4'},stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
    exceeded=False
    try: out,err=proc.communicate(timeout=4)
    except subprocess.TimeoutExpired:
        exceeded=True
        os.killpg(proc.pid,signal.SIGTERM)
        try: out,err=proc.communicate(timeout=.2)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid,signal.SIGKILL)
            out,err=proc.communicate(timeout=5)
    finally:
        try: os.killpg(proc.pid,signal.SIGKILL)
        except ProcessLookupError: pass
    result=dict(base_commit='f145078aeb3f3068169dd29ca7a1f03839fa8ec0',command='bash bin/fm-contributions.sh poll',environment=dict(FM_CHECK_TIMEOUT='4'),saved_owners=400,exceeded_four_second_watcher_bound=exceeded,exit_after_deadline_control=proc.returncode,elapsed_seconds=round(time.monotonic()-started,3),stdout=out,stderr=err,all_records_byte_identical=(hashes()==before))
    (evidence/'baseline-deadline-transcript.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result),flush=True)
    assert exceeded,'base unexpectedly completed; compare actual output before claiming reproduction'
finally:
    if proc is not None and proc.poll() is None:
        os.killpg(proc.pid,signal.SIGKILL)
        proc.wait()
    baseline.unlink(missing_ok=True)
    shutil.rmtree(home)
