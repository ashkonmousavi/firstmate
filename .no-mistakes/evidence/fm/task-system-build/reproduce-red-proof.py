import pathlib,subprocess,tarfile,io,os
root=pathlib.Path.cwd(); ev=pathlib.Path('~/.no-mistakes/evidence/01M6NJNWM2YZHE7J8AAMK0ZD4F')
source=(root/'tests/fm-spawn-slice-gate.test.sh').read_text()
for label,ref,test in [('red-b6','d23d07ade96bf4ccfae4275e4d4c63b673462c33','test_enforce_refuses_a_ship_without_a_slice_line'),('red-unlisted','8d1292ad','test_unlisted_projects_bypass_without_a_validator_result')]:
    dest=root/'.test-tmp'/label;dest.mkdir(exist_ok=True)
    archive=subprocess.run(['git','archive',ref,'bin','tests','docs','.agents'],capture_output=True,check=True)
    with tarfile.open(fileobj=io.BytesIO(archive.stdout)) as tf: tf.extractall(dest,filter='data')
    (dest/'tests/fm-spawn-slice-gate.test.sh').write_text(source[:source.index('FM_TEST_REAL_HOME=$HOME')]+test+'\n')
    env=os.environ.copy();env['TMPDIR']=str(root/'.test-tmp')
    with (ev/(label+'.log')).open('w') as log:
        log.write(f'Historical production revision {ref}; behavioral test {test}\n');log.flush()
        r=subprocess.run(['bash',str(dest/'tests/fm-spawn-slice-gate.test.sh')],env=env,stdout=log,stderr=subprocess.STDOUT)
        log.write(f'\nActual exit status: {r.returncode} (expected nonzero: historical bug reproduced)\n')
    print(label,r.returncode)
    if r.returncode==0: raise RuntimeError('Historical regression did not reproduce')
