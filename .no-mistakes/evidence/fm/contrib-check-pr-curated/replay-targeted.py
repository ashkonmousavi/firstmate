"""Run from a checkout of target 2c738da6: python3 replay-targeted.py EVIDENCE_DIRECTORY.
Runs only the contributions behavior tests, excluding the recorded baseline timing exception.
Uses normal /tmp test-toolchain fixtures; does not control a validation pipeline.
"""
import os, pathlib, re, subprocess, sys, tempfile
root=pathlib.Path.cwd()
evidence=pathlib.Path(sys.argv[1]).resolve()
evidence.mkdir(parents=True,exist_ok=True)
src=(root/'tests/fm-contributions.test.sh').read_text()
definitions, runner=src.rsplit('\nfailures=0\n',1)
definitions=definitions.replace('. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"','. "'+str(root/'tests/lib.sh')+'"',1)
names=re.search(r'for test_name in (.*); do',runner).group(1).split()
names.remove('test_unmeasured_url_does_not_starve_the_tail')
with tempfile.TemporaryDirectory(prefix='fm-contrib-replay-') as temp:
    driver=pathlib.Path(temp)/'driver.sh'
    driver.write_text(definitions+'\nfailures=0\nfor test_name in '+' '.join(names)+'; do\n  ( "$test_name" ) || failures=$((failures+1))\ndone\n[ "$failures" -eq 0 ]\n')
    with (evidence/'replay-targeted.log').open('w') as log:
        result=subprocess.run(['bash',str(driver)],env={**os.environ,'TMPDIR':'/tmp'},stdout=log,stderr=subprocess.STDOUT)
raise SystemExit(result.returncode)
