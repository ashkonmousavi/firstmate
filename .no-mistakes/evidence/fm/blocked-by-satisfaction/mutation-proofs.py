import os,pathlib,subprocess,tempfile,shutil,time,re
ROOT=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M6PYWK8CF5K753X1RN1KN9J8')
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_','HERDR_','REX_'))}
env['TMPDIR']=str(ROOT/'.test-validation-tmp')
log=(E/'mutation-proofs.log').open('w')
def run(code,home,command,*args):
    p=subprocess.run([str(code/'bin'/command),*args],env=env|{'FM_HOME':str(home)},text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=40)
    log.write('$ '+command+' '+' '.join(args)+'\n'+p.stdout+p.stderr+f'[exit {p.returncode}]\n');log.flush()
    return p
with tempfile.TemporaryDirectory(prefix='mutants-',dir=ROOT/'.test-validation-tmp') as tmp:
    tmp=pathlib.Path(tmp); home=tmp/'home'; (home/'data').mkdir(parents=True); (home/'state').mkdir();(home/'config').mkdir()
    (home/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\n')
    (home/'data/backlog.md').write_text('## Queued\n- [ ] wait - Wait blocked-by: ghost (kind: scout)\n')
    (home/'data/blocked-by-fleet-rows.tsv').write_text(f'self\tlocal\ngenerated\t{int(time.time())}\nhomes\tlocal,other,third\n')
    mutant=tmp/'mutant'; shutil.copytree(ROOT/'bin',mutant/'bin')
    lib=mutant/'bin/fm-blocked-by-lib.sh'; text=lib.read_text(); lib.write_text(text.replace('verdict = "unknown"','verdict = "satisfied"'))
    def unresolved_guard(code):
        out=run(code,home,'fm-tasks-axi.sh','ready'); assert out.returncode==0
        ready=re.search(r'^ready\[\d+\].*\n((?:  [^\n]*\n)*)',out.stdout,re.M)
        return not ready or not any(line.strip().startswith('wait,') for line in ready[1].splitlines())
    log.write('ORACLE: an unresolved blocker must never be dispatchable (G9).\n')
    assert not unresolved_guard(mutant); log.write('RED: unresolved-as-satisfied mutant rejected by readiness guard.\n')
    assert unresolved_guard(ROOT); log.write('GREEN: target preserves UNKNOWN and withholds the dependent.\n\n')
    pr='https://github.com/cli/cli/pull/14918'
    (home/'data/backlog.md').write_text('## Queued\n- [ ] shared - Local prep (kind: scout)\n')
    (home/'data/blocked-by-fleet-rows.tsv').write_text(f'self\tlocal\ngenerated\t{int(time.time())}\nhomes\tlocal,other,third\nrow\tother\tshared\topen\t-\nrow\tthird\tshared\topen\t{pr}\n')
    owner=mutant/'bin/fm-pr-owner.sh'; source=(ROOT/'bin/fm-pr-owner.sh').read_text()
    owner.write_text(source.replace('if (named != "") {','if (named != "") {\n      split(named, first, ","); known(first[1], task, "mutant first match wins"); exit st'))
    def owner_guard(code,id,homewant):
        p=run(code,home,'fm-pr-owner.sh',pr,'--branch','fm/'+id)
        return p.returncode==0 and p.stdout.startswith('known\t'+homewant+'\t'+id+'\t')
    log.write('ORACLE: shared branch ID belongs to the unique PR-citing home, regardless of row order.\n')
    assert not owner_guard(mutant,'shared','third');log.write('RED: first-match-wins mutant rejected.\n')
    assert owner_guard(ROOT,'shared','third');log.write('GREEN: target selects third.\n\n')
    (home/'data/blocked-by-fleet-rows.tsv').write_text(f'self\tlocal\ngenerated\t{int(time.time())}\nhomes\tlocal,other,third\nrow\tother\tbranch-only\tarchive\t-\nrow\tthird\tciting\tdone\t{pr}\n')
    owner.write_text(source.replace('if (named != "") {','if (0 && named != "") {'))
    log.write('ORACLE: a unique fm/<id> task row outranks a different PR-citing row.\n')
    assert not owner_guard(mutant,'branch-only','other');log.write('RED: ignore-branch-name mutant rejected.\n')
    assert owner_guard(ROOT,'branch-only','other');log.write('GREEN: target selects branch-only in other.\n')
log.write('All three hand mutants rejected; target passed; disposable copies removed.\n');log.close()
print('Three behavioral mutation proofs passed')
