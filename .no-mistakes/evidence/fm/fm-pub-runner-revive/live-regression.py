"""Reproduce pre-fix watcher ordering with the same real loopback SSH lab."""
import asyncio
import importlib.util
import signal
import subprocess
import time

spec = importlib.util.spec_from_file_location('revive', __file__.replace('live-regression.py', 'live-revival.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.EVIDENCE = m.EVIDENCE / 'baseline'
m.EVIDENCE.mkdir(exist_ok=True)
m.BASE = m.ROOT / '.test-revive/baseline-live'


def reproduce():
    code = m.BASE / 'remote-code'
    old_watcher = subprocess.check_output([
        'git', 'show', '81d68b37efd9d1947cdf4ba91a253914cf831294:bin/fm-watch.sh'], cwd=m.ROOT)
    (code / 'bin/fm-watch.sh').write_bytes(old_watcher)
    m.run([m.ROOT / 'bin/fm-procevent-remote-reply.sh', 'arm', 'ios'])
    (m.HOME / 'state/ios.meta').write_text('kind=secondmate\nwindow=fm-lab-revive:p1\nbackend=herdr\nharness=claude\nremote_host=revive-lab\nhome=' + str(m.REMOTE) + '\n')
    script = '''. "$1/bin/fm-pending-reply-lib.sh"
c=$(fm_pending_reply_create "$FM_HOME" "$FM_HOME/state" ios "Please report the recovery result")
fm_pending_reply_mark_delivered "$FM_HOME/state" "$c"
'''
    m.run(['bash', '-c', script, 'create', m.ROOT])
    m.MODE = 'stalled'
    log = (m.EVIDENCE / 'baseline-watcher.log').open('w')
    p = subprocess.Popen([str(code / 'bin/fm-watch.sh')], env=m.ENV,
                         stdout=log, stderr=log, start_new_session=True)
    m.PROCS.append((p, log))
    m.wait_for(lambda: any(e['event'] == 'ssh-exec' and
                          e.get('argv', [])[:2] == ['fm-remote-secondmate-control.sh', 'observe']
                          for e in m.EVENTS), 'old watcher blocked in remote observe')
    time.sleep(3)
    assert m.claim() is None, 'old watcher unexpectedly repaired before blocked probe'
    m.record('pre-fix-regression-reproduced', owner=m.owner(),
             observation='remote observe is blocking and registered runner remains absent')
    p.terminate()
    code = p.wait(timeout=35)
    assert code in (0, -signal.SIGTERM, 128 + signal.SIGTERM), code
    m.record('baseline-watcher-exit', code=code)


m.scenarios = reproduce
if __name__ == '__main__':
    asyncio.run(m.main())
