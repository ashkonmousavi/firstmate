import os, pathlib, re, shutil, subprocess, tempfile, json
root = pathlib.Path.cwd()
evidence = pathlib.Path('/home/tegris/.no-mistakes/evidence/01M45A310MS8SHF58HQB9BSH73')
lab = pathlib.Path(tempfile.mkdtemp(prefix='.prep-validation-', dir=root))
env = os.environ.copy()
for key in list(env):
    if (key.startswith('FM_') and key.endswith('_OVERRIDE')) or key in ('FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','FM_TASK_ID','TASKS_AXI_FILE','TASKS_AXI_BACKEND'):
        env.pop(key, None)
env['FM_HOME'] = str(lab)
rows = []
def run(args):
    return subprocess.run(args, cwd=root, env=env, text=True, capture_output=True)
def gate(path):
    return run(['bash','-c','. bin/fm-dod-lib.sh; fm_prep_unfilled_reason "$1"','_',str(path)])
def record(case, process, code, contains=None):
    ok = process.returncode == code and (contains is None or contains in process.stdout)
    rows.append({'case':case,'exit':process.returncode,'stdout':process.stdout.strip(),'stderr':process.stderr.strip(),'expected_exit':code,'expected_reason':contains,'pass':ok})
    if not ok:
        raise AssertionError(rows[-1])
def field(text, label, value):
    return re.sub(r'^- '+re.escape(label)+r':.*$', lambda m:'- '+label+': '+value,text, flags=re.M)
answers = {
 'Q1':'no','Q2':'no','UI_WIRING':'no, operator-facing document admission only.',
 'Q1_REASON':'No product screen or user action changes.', 'Q2_REASON':'The isolated certificate names only one file.',
 'CAPTAIN_RULINGS':'Intent: validate the prep and generated-brief interface in a disposable home.',
 'STILL_VALID':'proceed: checked target b4f967e6 against base 24be0cf9 and related delivery records on 2026-10-04; this validation is still needed and no dependency blocks it.',
 'SIBLINGS_NAMED':'Not a defect; searched the isolated backlog and generated delivery records, none found; no broader repair authorized.',
 'VALIDATION_ROUTE':'python3 drive-public-interfaces.py for focused commands; Bash 5 isolated home; baseline unmeasured, first bounded run now; test phase owns execution and outer executor owns final CI acceptance.',
 'SCREEN_AND_REGION':'n/a: command and Markdown output only.',
 'RED_FIRST_PROOF':'Call fm_prep_unfilled_reason after blanking each required field; expect exit 0 naming the field; restore complete bytes and expect empty output with exit 1.',
 'FIXTURE_ARITHMETIC':'n/a: no calculated result.',
 'DATA_PATH_REACHABILITY':'bin/fm-brief.sh --prep writes data/task/prep.md; fm_prep_unfilled_reason reads that exact generated record.',
 'SCOPE_ONLY_AS_ASKED':'Exercise preparation admission and generated walk guidance only; fleet lifecycle and private operator records excluded.',
 'AUTHOR_GATE_CHECK':'bash -c source bin/fm-dod-lib.sh then fm_prep_unfilled_reason on this final prep; handoff retains the actual empty output and raw exit 1.',
 'INTENT_AND_BOXES':'The operator prepares a task and checks its readiness before handing it off.',
 'OUTCOME':'O1: A researcher opens the assigned study, saves the comparison and reopens it',
 'OBSERVABLE_RESULT':'The researcher starting from the study page selects both candidates, saves their comparison, returns home and reopens the same saved comparison with both candidates retained.',
 'WHERE_AND_HOW':'Execution owner: test phase; disposable local home; fixture evidence class; inspect generated prep and accepted-spec overlay, then cite actual observation in the existing evidence directory.',
 'EXPECTED_VALUE':'The independently requested task is to retain both candidates after reopen; actual walked observation belongs in delivery evidence, with permitted console and network diagnosis on failure.'
}
try:
    for fmt in ('full','surgical'):
        task = 'prep-'+fmt
        command = ['bash','bin/fm-brief.sh',task,'--prep']+(['--surgical'] if fmt=='surgical' else [])
        p=run(command); record(fmt+' scaffold CLI',p,0)
        prep=lab/'data'/task/'prep.md'
        raw=prep.read_text()
        for label in ('Still valid','Siblings named','Validation route'):
            assert re.search(r'^- '+re.escape(label)+':',raw,re.M)
        assert '| Outcome | Exact observable result | Where and how to check | Expected value |' in raw
        shutil.copy2(prep,evidence/(fmt+'-scaffold.md'))
        complete=raw
        for key,value in answers.items(): complete=complete.replace('{'+key+'}',value)
        for c in range(1,6):
            complete=complete.replace('{C'+str(c)+'}','yes').replace('{C'+str(c)+'_EVIDENCE}', 'bin/owned.sh:12 inspected; lookup found no outside callers; no stored data, security, permission, money, install or server changes; cause reproduced and one focused regression covers the entire change.')
        complete=re.sub(r'^\{[A-Z0-9_]+\}$','n/a: isolated document-admission verification.',complete,flags=re.M)
        prep.write_text(complete)
        record(fmt+' complete prep admitted',gate(prep),1)
        shutil.copy2(prep,evidence/(fmt+'-answered-prep.md'))
        for label in ('Still valid','Siblings named','Validation route'):
            for name,value in [('blank',''),('placeholder','{UNFILLED}'),('bare-na','n/a'),('reasoned-na','n/a: no checks'),('example','Example: searched current sources'),('comment','<!-- substantive evidence -->')]:
                prep.write_text(field(complete,label,value)); record(fmt+' '+label+' '+name+' refused',gate(prep),0,label)
            line=re.search(r'^- '+re.escape(label)+r':.*$',complete,re.M).group()
            for name,replacement in [('missing',''),('duplicate',line+'\n'+line),('fenced','```markdown\n'+line+'\n```'),('comment-block','<!--\n'+line+'\n-->')]:
                prep.write_text(complete.replace(line,replacement)); record(fmt+' '+label+' '+name+' refused',gate(prep),0,label)
        for value in ('refresh: newer design','covered: work completed','superseded: new owner','blocked: unresolved dependency','proceed:','proceed: {EVIDENCE}','proceed: n/a'):
            prep.write_text(field(complete,'Still valid',value)); record(fmt+' '+value+' refused',gate(prep),0,'Still valid')
        for value in ('Searched isolated task records and delivery inventory, none found.','Not a defect; checked related admission work and its existing owner.'):
            prep.write_text(field(complete,'Siblings named',value)); record(fmt+' explicit siblings '+value+' admitted',gate(prep),1)
        # The target includes continuation normalization; observe it without modifying the declined behavior.
        prep.write_text(field(complete,'Still valid','\n    proceed: checked the target and current task; work remains needed.'))
        record(fmt+' multiline substantive proceed admitted',gate(prep),1)
        prep.write_text(complete)
        overlay=run(['bash','-c','. bin/fm-dod-lib.sh; fm_brief_intent_overlay "Walk the assigned study and reopen its saved comparison." "$1"','_',str(prep)])
        record(fmt+' accepted specification rendered',overlay,0,answers['OUTCOME'])
        (evidence/(fmt+'-accepted-spec.md')).write_text(overlay.stdout)
        assert answers['OBSERVABLE_RESULT'] in overlay.stdout and answers['EXPECTED_VALUE'] in overlay.stdout
    for kind in ('ship','scout'):
        task='walk-'+kind
        args=['bash','bin/fm-brief.sh',task,'firstmate']+(['--scout'] if kind=='scout' else ['--mode','no-mistakes'])
        record(kind+' scaffold CLI',run(args),0)
        brief=lab/'data'/task/'brief.md'
        text=brief.read_text(); shutil.copy2(brief,evidence/(kind+'-generated-brief.md'))
        block=text.split('# Walk evidence\n',1)[1].split('\n# ',1)[0]
        assert 'return or reopen step' in block and 'actual observed result' in block and 'first failing boundary' in block and 'diagnostics' in block
        record(kind+' initial task placeholders detected',run(['bash','-c','. bin/fm-dod-lib.sh; fm_brief_task_placeholders_present "$1"','_',str(brief)]),0)
        brief.write_text(text.replace('{TASK}','Walk the assigned study and reopen its saved comparison.'))
        record(kind+' FIRSTMATE_SPEC alone detected',run(['bash','-c','. bin/fm-dod-lib.sh; fm_brief_task_placeholders_present "$1"','_',str(brief)]),0)
        brief.write_text(brief.read_text().replace('{FIRSTMATE_SPEC}','Use assigned actor and candidate; retain actual observations and permitted diagnostic evidence.'))
        record(kind+' complete task placeholders cleared',run(['bash','-c','. bin/fm-dod-lib.sh; fm_brief_task_placeholders_present "$1"','_',str(brief)]),1)
        shutil.copy2(brief,evidence/(kind+'-filled-brief.md'))
finally:
    (evidence/'public-interface-results.json').write_text(json.dumps(rows,indent=2)+'\n')
    (evidence/'public-interface-transcript.txt').write_text('\n'.join(f"{r['case']}: raw exit {r['exit']}; reason={r['stdout']!r}; expected exit={r['expected_exit']}; expected reason={r['expected_reason']!r}; result={'PASS' if r['pass'] else 'FAIL'}" for r in rows)+'\n')
    shutil.rmtree(lab)
print(f'Executed real scaffold, gate and brief interfaces: {len(rows)} observed outcomes; disposable home removed.')
