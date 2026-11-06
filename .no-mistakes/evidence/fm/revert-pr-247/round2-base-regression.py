#!/usr/bin/env python3
"""Reproduce the reported ready-count error on an archived base source tree."""
import json,os,pathlib,subprocess,tempfile
root=pathlib.Path.cwd()
out=pathlib.Path('~/.no-mistakes/evidence/01M6QG4GJ98YRTXTMHF63ZZK56')
with tempfile.TemporaryDirectory(prefix='.round2-baseline-',dir=root) as archived, tempfile.TemporaryDirectory(prefix='round2-base-toolchain-',dir=out) as scratch:
    archive=subprocess.Popen(['git','archive','4e4a338f1167b55826b81414070402bea7b9b34f','bin','tests'],stdout=subprocess.PIPE)
    extracted=subprocess.run(['tar','-x','-C',archived],stdin=archive.stdout)
    archive.stdout.close()
    assert archive.wait()==0 and extracted.returncode==0
    env=os.environ|{'TMPDIR':scratch,'GIT_CEILING_DIRECTORIES':scratch,'FM_AUTOLAUNCH_EGM1R2_ONLY':'test_egm1r2_malformed_ready_is_not_a_successful_read'}
    result=subprocess.run(['bash',str(pathlib.Path(archived)/'tests/fm-autolaunch.test.sh')],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=60)
    (out/'round2-base-count-mismatch.log').write_text(result.stdout)
    expected='EGM1-R2 ready count-mismatch: malformed ready output was recorded as tasks status ok'
    print(result.stdout)
    print('Base exit:',result.returncode,'(expected failure)')
    assert result.returncode!=0 and expected in result.stdout
    (out/'round2-base-result.json').write_text(json.dumps({'commit':'4e4a338f1167b55826b81414070402bea7b9b34f','exit':result.returncode,'reported_failure_reproduced':True})+'\n')
