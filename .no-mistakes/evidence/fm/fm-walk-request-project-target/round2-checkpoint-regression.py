from pathlib import Path
import subprocess, tempfile
root=Path.cwd()
script=r"""
. "$1"
unset FM_CHECKPOINT_CLOCK_OFFSET
fm_checkpoint_clock
FM_CHECKPOINT_DEADLINE=$((FM_CHECKPOINT_NOW + 1))
printf 'initial=%s deadline=%s\n' "$FM_CHECKPOINT_NOW" "$FM_CHECKPOINT_DEADLINE"
SECONDS=$((SECONDS - 60))
sleep 1.1
fm_checkpoint_expired
expired=$?
budget=$(fm_checkpoint_budget 25)
rc=$?
printf 'expired_status=%s budget_status=%s budget=%s\n' "$expired" "$rc" "$budget"
[ "$expired" -eq 0 ] && [ "$rc" -eq 124 ]
"""
with tempfile.TemporaryDirectory(prefix='.clock-counterfactual-',dir=root) as d:
    base=Path(d)/'base-timeout.sh'
    base.write_bytes(subprocess.check_output(['git','show','2bafe15f26658147adf097c4f0dbef263761c814:bin/fm-timeout-lib.sh']))
    for label,lib,expected in [('base',base,1),('target',root/'bin/fm-timeout-lib.sh',0)]:
        r=subprocess.run(['bash','-c',script,'clock-check',str(lib)],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=10)
        print(label+'\n'+r.stdout+'exit='+str(r.returncode),flush=True)
        assert r.returncode==expected
print('Disposable base copy removed.')
