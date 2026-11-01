Validation contract research, 2026-11-01

The worktree has no data/research-book/INDEX.md. No other checkout was read. These findings remain in this run’s evidence.

The [official gh pr list manual](https://cli.github.com/manual/gh_pr_list) defines merged as an accepted state filter, --json/--jq as output controls, and --limit/-L as the maximum fetched item count. A list limit of 9 therefore does not identify PR 9. These semantics support the aggregate-versus-specific-PR adversarial checks.

The [official Claude hooks reference](https://code.claude.com/docs/en/hooks#stop) defines last_assistant_message as the final reply and stop_hook_active as the marker for a hook continuation. Accordingly this validation records actual vendor Stop payloads, the production hook’s exit and stderr, and completed Bash tool results in Claude’s transcript.

The production module explicitly treats command presence as read evidence; it does not validate remote output truth. Forge commands are disposable external-boundary fixtures. Claude itself, its Stop event, transcript, Bash execution and production guard are real. No forge credentials or fleet state are exercised.

The initial custom driver also demanded that Claude repeat its blocked reply verbatim. Some sessions instead obeyed the guard and performed a direct read before replying. That assertion tested model cooperation beyond the changed behavior. evaluate_live.py checks the first Stop against the intended exact claim and verifies all commands completed before that reply; raw attempts remain retained. The existing live e2e test separately verifies the identical-reply exemption.
