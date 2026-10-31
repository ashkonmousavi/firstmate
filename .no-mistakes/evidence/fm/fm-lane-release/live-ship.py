from pathlib import Path
helper=Path('~/.no-mistakes/evidence/01M67W332R62ZJZSW3A4W2RCSJ/live-lanes.py').read_text().split('now=int(time.time())')[0].replace("E/'live-lanes.log'","E/'live-ship.log'")
exec(compile(helper,'live-lanes-helper','exec'))
bg=None
try:
 W.mkdir(exist_ok=True);wt=W/'ship';wt.mkdir(exist_ok=True)
 (wt/'keep.txt').write_text('ship uncommitted work kept\n')
 now=int(time.time());gen=f's{now-10}.1.1'
 meta=S/'sh.meta';meta.write_text(f'window=primary:fm-sh\nendpoint_task_id=sh\nworktree={wt}\nproject={wt}\nharness=claude\nkind=ship\nmode=no-mistakes\nspawn_gen={gen}\nbackend=tmux\npr=https://github.com/example/disposable/pull/7\n')
 (S/'sh.status').write_text(f'working [at={now-9}]: started disposable ship\n')
 busygen=run([ROOT/'bin/fm-busy-event.sh','arm',S,'sh']).stdout.strip()
 hooks={}
 for event,state,ev in [('UserPromptSubmit','busy','user-prompt-submit'),('Stop','idle','stop'),('SessionEnd','idle','session-end')]:
  cmd=shlex.join([str(ROOT/'bin/fm-busy-event.sh'),'apply',str(S),'sh',state,'--gen',busygen,'--source','claude-hook','--event',ev])
  if event=='UserPromptSubmit':cmd+=' --prompt-stdin'
  hooks[event]=[{'hooks':[{'type':'command','command':cmd}]}]
 settings=W/'ship-settings.json';settings.write_text(json.dumps({'hooks':hooks,'feedbackDrafts':'off'}))
 launch=['claude','--permission-mode','auto','--model','haiku','--setting-sources','','--settings',str(settings),'--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--tools','','--system-prompt','Reply only with the requested word. Do not read or change files.']
 tm('new-window','-d','-t','primary:','-n','fm-sh','-c',str(wt),'bash');tm('send-keys','-t','primary:fm-sh','-l',shlex.join(launch));tm('send-keys','-t','primary:fm-sh','Enter')
 wait(lambda:'❯' in tm('capture-pane','-p','-t','primary:fm-sh').stdout)
 tm('send-keys','-t','primary:fm-sh','-l','Reply only READY');tm('send-keys','-t','primary:fm-sh','Enter')
 wait(lambda:'event=stop ' in (S/'sh.busy-state').read_text(),60)
 snap('ship-ready','primary:fm-sh')
 # Materialize independent git data after startup, keeping existing login/trust untouched.
 run(['git','init','-q','-b','disposable-ship',wt]);(wt/'base.txt').write_text('base\n')
 run(['git','-C',wt,'add','base.txt']);run(['git','-C',wt,'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','fixture'])
 (C/'lane-release').write_text('on\n');anchor=int(time.time())+1
 sweep(anchor+400);sweep(anchor+800)
 assert_(alive('sh') and not (S/'sh.release-candidate').exists(),'ship without confirmed merge keeps its real worker alive')
 # Use the real merge-receipt writer: no forge service or real PR is consulted.
 run(['bash','-c','. "$1"; fm_pr_poll_merge_mark_notified "$2" sh github github.com example/disposable 7','fixture',ROOT/'bin/fm-pr-lib.sh',S])
 receipt=S/'sh.pr-poll-merge-notified';os.utime(receipt,(anchor,anchor))
 p=run([ROOT/'bin/fm-crew-state.sh','sh'],extra={'FM_CREW_STATE_NO_FORGE':'1'});(E/'ship-working-crew-state.txt').write_text(p.stdout)
 sweep(anchor+400);assert_(alive('sh') and not (S/'sh.release-candidate').exists(),'worker declaring working is retained because crew-state does not agree completion')
 (S/'sh.status').unlink()
 p=run([ROOT/'bin/fm-crew-state.sh','sh'],extra={'FM_CREW_STATE_NO_FORGE':'1'});(E/'ship-idle-crew-state.txt').write_text(p.stdout)
 # Enqueue a real firstmate steering record and place exactly its doorbell in composer.
 cmd='. "$1"; rec=$(fm_task_inbox_write "$2" sh "Unfinished continuation"); fm_task_inbox_doorbell_line "$rec"'
 bell=run(['bash','-c',cmd,'fixture',ROOT/'bin/fm-task-inbox-lib.sh',S]).stdout
 sweep(anchor+400);assert_(alive('sh') and not (S/'sh.release-candidate').exists(),'unhandled steering record retains an otherwise merged idle ship')
 tm('send-keys','-t','primary:fm-sh','-l',bell)
 sweep(anchor+400);p=audit(anchor+2200)
 assert_('stuck-composer sh' in p.stdout and alive('sh'),'the real unsent own-doorbell composer is classified stuck-composer and retained')
 snap('ship-stuck-composer','primary:fm-sh')
 tm('send-keys','-t','primary:fm-sh','C-u','C-u','C-u');shutil.rmtree(S/'sh.inbox')
 wait(lambda:lr('read-evidence','composer',meta,'sh').stdout.strip()=='empty')
 # A full actual model turn between observations invalidates the quiet proof.
 sweep(anchor+400);assert_((S/'sh.release-candidate').exists(),'confirmed merged idle ship enters debounce')
 old=(S/'sh.busy-state').read_text()
 tm('send-keys','-t','primary:fm-sh','-l','Reply only AGAIN');tm('send-keys','-t','primary:fm-sh','Enter')
 wait(lambda:'event=stop ' in (S/'sh.busy-state').read_text() and (S/'sh.busy-state').read_text()!=old,60)
 sweep(anchor+800)
 assert_(alive('sh') and not (S/'sh.released').exists() and not (S/'sh.release-candidate').exists(),'an intervening completed real model turn invalidates release')
 anchor=int(time.time())+1;os.utime(receipt,(anchor,anchor))
 sweep(anchor+1000);sweep(anchor+1300)
 wait(lambda:(S/'sh.release.log').exists(),75)
 (E/'ship-release-control.txt').write_text((S/'sh.release.log').read_text())
 assert_('rc=0' in (S/'sh.release.log').read_text() and not alive('sh'),'merged-while-idle ship exits successfully without a done line')
 sweep(anchor+1310)
 assert_('result=released' in (S/'sh.released').read_text(),'real ship seat is verified free')
 assert_((wt/'keep.txt').read_text()=='ship uncommitted work kept\n','ship exit keeps uncommitted work and its copy')
 before=(D/'lane-release.ledger').read_text();sweep(anchor+1500)
 assert_((D/'lane-release.ledger').read_text()==before,'second sweep does not repeat a completed release event')
 (E/'ship-release.ledger').write_text(before);(E/'sh.released').write_text((S/'sh.released').read_text())
 # Recovery's public sweep uses its real dependencies and sees the active marker.
 (D/'sh').mkdir(exist_ok=True);(D/'sh/brief.md').write_text('# Disposable ship\n')
 (C/'backlog-backend').write_text('manual\n')
 p=run(['bash','-c','. "$1"; fm_crew_recovery_sweep','fixture',ROOT/'bin/fm-crew-recovery-lib.sh'])
 assert_(not alive('sh') and meta.exists() and 'result=released' in (S/'sh.released').read_text(),'startup recovery leaves intentionally released task stopped')
 p=run([ROOT/'bin/fm-fleet-view.sh']);(E/'fleet-view.md').write_text(p.stdout)
 assert_('(released: merged-ship)' in p.stdout,'heartbeat fleet listing displays the intentional merged-ship release')
 # Changing incarnation invalidates old marker in public listing; no relaunch is invoked.
 meta.write_text(meta.read_text().replace(gen,f's{now+1}.2.2'))
 p=run([ROOT/'bin/fm-fleet-snapshot.sh','--json']);obj=json.loads(p.stdout)
 assert_(next(x for x in obj['tasks'] if x['id']=='sh')['lane_release'] is None,'new incarnation does not inherit the previous release marker')
 log.write('ALL LIVE SHIP SCENARIOS PASSED\n')
except Exception as exc:
 log.write('FAILED: '+repr(exc)+'\n')
 try:snap('ship-failure','primary:fm-sh')
 except Exception:pass
 raise
finally:
 tm('kill-server');shutil.rmtree(W,ignore_errors=True);shutil.rmtree(LAB,ignore_errors=True)
 log.write('CLEANUP: private tmux server and disposable ship home/copy removed\n');log.close()
