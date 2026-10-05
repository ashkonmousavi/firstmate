from pathlib import Path
import subprocess, re, datetime, hashlib, os
p=Path('/home/zcrew/.no-mistakes/evidence/01M45JNGXNRJ522PPBNYHJF1VA')
delivery=Path('tests/fm-task-delivery.test.sh').read_text().split('\ntest_prep_current_work_checks\n')[0]
delivery=re.sub(r'^test_[a-z_]+\s*$', '', delivery, flags=re.M)
probe=Path('tests/.review-depth-probe.sh')
probe.write_text(delivery+'''
eval "$(declare -f fm_prep_delivery_mode | sed '1s/fm_prep_delivery_mode/review_original_delivery_mode/')"
fm_prep_delivery_mode() { cp "$1" "$REVIEW_INPUT"; review_original_delivery_mode "$@"; }
eval "$(declare -f run_spawn | sed '1s/run_spawn/review_original_run_spawn/')"
run_spawn() {
  local result code item
  cp "$1/data/$3/prep.md" "$REVIEW_INPUT"
  result=$(review_original_run_spawn "$@"); code=$?
  for item in "$1/data/$3/launch-brief.md" "$1/state/$3.meta" "$2/tmux.calls" "$2/treehouse.calls"; do
    if [ -f "$item" ]; then cp "$item" "$REVIEW_INPUT.${item##*/}"; fi
  done
  find "$1/state" -name '*lock*' > "$REVIEW_INPUT.locks"
  printf '%s\\n' "$result"
  return "$code"
}
review_helper() {
  local mode=$1 rec home proj fakebin prep out code
  rec=$(make_home "helper-$mode")
  IFS='|' read -r home proj fakebin <<< "$rec"
  fm_test_prep_record "$home/data" helper no no no "$mode" || fail "helper generation"
  prep="$home/data/helper/prep.md"
  out=$(fm_prep_delivery_mode "$prep"); code=$?
  [ "$code" = 0 ] && [ "$out" = "$mode" ] || fail "helper lost explicit $mode: $out (exit $code)"
  out=$(fm_prep_unfilled_reason "$prep"); code=$?
  [ "$code" = 1 ] && [ -z "$out" ] || fail "helper lost upstream common fields: $out (exit $code)"
  pass "helper public scaffold/completeness $mode"
}
set -x
"$@"
''')
brief=Path('tests/fm-brief.test.sh').read_text().split('\ntest_delivery_depth_scaffolds\n')[0]
brief=re.sub(r'^test_[a-z_]+\s*$', '', brief, flags=re.M)
bprobe=Path('tests/.review-brief-probe.sh')
bprobe.write_text(brief+'\nset -x\n"$@"\n')
(p/'green-driver.sh').write_bytes(probe.read_bytes())
(p/'brief-driver.sh').write_bytes(bprobe.read_bytes())
files=['bin/fm-dod-lib.sh','bin/fm-spawn.sh','tests/prep-record-helper.sh','tests/fm-task-delivery.test.sh','tests/fm-brief.test.sh']
original={f:Path(f).read_bytes() for f in files}
for f,b in original.items(): (p/(Path(f).name+'.fixed')).write_bytes(b)
receipt=[f'UTC {datetime.datetime.now(datetime.timezone.utc).isoformat()}\nHEAD '+subprocess.check_output(['git','rev-parse','HEAD'],text=True)+'Dirty status:\n'+subprocess.check_output(['git','status','--short'],text=True)]
failed=[]
def run(name,args,expected=0,driver=probe):
    cmd=['env',f'REVIEW_INPUT={p}/{name}.input.md','bash',str(driver),*args]
    r=subprocess.run(cmd,capture_output=True,text=True)
    (p/(name+'.log')).write_text(r.stdout+r.stderr)
    receipt.append(f'UTC {datetime.datetime.now(datetime.timezone.utc).isoformat()}\nCommand {cmd!r}\nRaw exit {r.returncode}; expected {expected}; log {name}.log\nProduction/fixture SHA-256 '+str({f:hashlib.sha256(Path(f).read_bytes()).hexdigest() for f in files})+'\n')
    if (r.returncode==0) != (expected==0): failed.append(name)
    print(name, 'exit',r.returncode,'expected',expected, next((x for x in r.stderr.splitlines() if x.startswith('not ok')), ''),flush=True)
    (p/'fixed-head-receipts.txt').write_text(''.join(receipt))
try:
    for fmt in ['full','surgical']:
      for mode in ['direct-PR','no-mistakes']:
        run(f'green-{fmt}-{mode}', ['test_depth_commented_tier',fmt,mode])
    run('green-mode-matrix',['test_depth_mode_matrix'])
    run('green-required-fields',['test_depth_required_full_and_surgical'])
    run('green-guide-count',['test_prep_scaffolds_the_preparation_record'],driver=bprobe)
    for mode in ['direct-PR','no-mistakes']: run('green-helper-'+mode,['review_helper',mode])
    f='bin/fm-dod-lib.sh'
    s=original[f].decode().replace('  fm_prep_body_text < "$file" | fm_brief_heading_parse - "$FM_PREP_TIER_HEADING" "$mode"', '''  if [ "$mode" = present ]; then
    fm_brief_heading_parse "$file" "$FM_PREP_TIER_HEADING" present
  else
    fm_brief_heading_body "$file" "$FM_PREP_TIER_HEADING" | fm_prep_body_text
  fi''')
    assert s!=original[f].decode()
    Path(f).write_text(s)
    (p/'fault-context.patch').write_text(subprocess.check_output(['git','diff','--',f],text=True))
    for fmt in ['full','surgical']:
      for mode in ['direct-PR','no-mistakes']:
        for check in ['reader','mismatch']:
          run(f'fault-context-{fmt}-{mode}-{check}',['test_depth_commented_tier',fmt,mode,check],1)
    Path(f).write_bytes(original[f])
    for fmt in ['full','surgical']:
      for mode in ['direct-PR','no-mistakes']:
        run(f'restored-context-{fmt}-{mode}',['test_depth_commented_tier',fmt,mode])
    f='bin/fm-spawn.sh'
    s=original[f].decode().replace('if [ "$MODE" != local-only ] && [ "$MODE" != "$PREP_DEPTH_MODE" ]; then','if false; then')
    assert s!=original[f].decode()
    Path(f).write_text(s)
    for mode in ['direct-PR','no-mistakes']:
      run('fault-comparison-'+mode,['test_depth_commented_tier','full',mode,'mismatch'],1)
    Path(f).write_bytes(original[f])
    run('restored-mode-matrix',['test_depth_mode_matrix'])
    f='bin/fm-dod-lib.sh'
    s=original[f].decode().replace('if ! fm_prep_delivery_mode "$file" >/dev/null; then','if false; then')
    assert s!=original[f].decode()
    Path(f).write_text(s)
    run('fault-required-depth',['test_depth_required_full_and_surgical'],1)
    Path(f).write_bytes(original[f])
    run('restored-required-fields',['test_depth_required_full_and_surgical'])
    s=original[f].decode()
    s='\n'.join(x for x in s.split('\n') if not x.startswith('<!-- Delivery depth:'))
    assert s!=original[f].decode()
    Path(f).write_text(s)
    run('fault-guide-count',['test_prep_scaffolds_the_preparation_record'],1,driver=bprobe)
    Path(f).write_bytes(original[f])
    run('restored-guide-count',['test_prep_scaffolds_the_preparation_record'],driver=bprobe)
    f='tests/prep-record-helper.sh'
    for fault in ['STILL_VALID','SIBLINGS_NAMED','VALIDATION_ROUTE','DELIVERY_DEPTH','forwarding']:
      s=original[f].decode()
      if fault=='forwarding': s=s.replace('fm_test_fill_prep_common "$prep" "$depth_mode"','fm_test_fill_prep_common "$prep"')
      elif fault=='DELIVERY_DEPTH': s=s.replace('gsub(/\\{DELIVERY_DEPTH\\}/, depth ', 'gsub(/\\{UNUSED_DEPTH\\}/, depth ')
      else: s='\n'.join(x for x in s.split('\n') if 'gsub(/\\{'+fault+'\\}/' not in x)
      assert s!=original[f].decode()
      Path(f).write_text(s)
      run('fault-helper-'+fault,['review_helper','direct-PR'],1)
      Path(f).write_bytes(original[f])
      run('restored-helper-'+fault,['review_helper','direct-PR'])
finally:
    for f,b in original.items(): Path(f).write_bytes(b)
    receipt.append('Final restored SHA-256 '+str({f:hashlib.sha256(Path(f).read_bytes()).hexdigest() for f in files})+'\nAll original fixed bytes restored: '+str(all(Path(f).read_bytes()==b for f,b in original.items()))+'\nUnexpected outcomes: '+repr(failed)+'\n')
    (p/'fixed-head-receipts.txt').write_text(''.join(receipt))
    probe.unlink()
    bprobe.unlink()
if failed: raise SystemExit(1)
