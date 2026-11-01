"""Judge initial Stop behavior independently of how Claude repairs a block."""
import json
from pathlib import Path
import sys

evidence = Path(sys.argv[1])
index = json.loads((evidence / 'live-scenarios.json').read_text())
reports = []
for number, case in enumerate(index['cases']):
    name = case['name']
    record = json.loads((evidence / f'{number:02}-{name}-stop.json').read_text())
    events = record.get('stop_events', [])
    report = {'name': name, 'expected_message': case['message'],
              'expected_initial_exit': case['expected_stop_exits'][0]}
    try:
        assert record['cli_exit'] == 0, 'Claude process failed'
        assert events, 'missing real Stop event'
        first = events[0]
        assert first['payload']['last_assistant_message'].strip() == case['message'], 'initial text differs from scenario'
        assert first['payload']['stop_hook_active'] is False, 'not an initial Stop'
        assert first['rc'] == report['expected_initial_exit'], 'incorrect initial guard verdict'
        if first['rc'] == 2:
            assert 'State claim needs a same-turn read' in first['stderr'], 'wrong blocker'
        stream = [json.loads(line) for line in (evidence / f'{number:02}-{name}-stream.jsonl').read_text().splitlines() if line.startswith('{')]
        assert any(row.get('type') == 'result' and not row.get('is_error') for row in stream), 'no successful model result'
        transcript_path = Path(first['payload']['transcript_path'])
        # Only the exact transcript created by this driver is read. Never enumerate the home.
        assert '.test-state-claim-tmp' in first['payload']['cwd'], 'not a disposable test session'
        transcript = transcript_path.read_text()
        (evidence / f'{number:02}-{name}-transcript.jsonl').write_text(transcript)
        rows = [json.loads(line) for line in transcript.splitlines()]
        called, complete = {}, set()
        reached_reply = False
        for row in rows:
            content = row.get('message', {}).get('content', [])
            if not isinstance(content, list): continue
            if row.get('type') == 'assistant' and any(block.get('type') == 'text' and block.get('text', '').strip() == case['message'] for block in content):
                reached_reply = True
                break
            for block in content:
                if row.get('type') == 'assistant' and block.get('type') == 'tool_use' and block.get('name') == 'Bash':
                    called[block['id']] = block.get('input', {}).get('command')
                if row.get('type') == 'user' and block.get('type') == 'tool_result' and not block.get('is_error'):
                    complete.add(block['tool_use_id'])
        assert reached_reply, 'no initial assistant reply in real transcript'
        report['completed_commands_before_initial_reply'] = [command for ident, command in called.items() if ident in complete]
        assert report['completed_commands_before_initial_reply'] == ([case['command']] if case['command'] else []), 'unexpected reads before initial claim'
        report['actual_initial_exit'] = first['rc']
        report['initial_stderr'] = first['stderr']
        report['continuation_exits'] = [event['rc'] for event in events[1:]]
        report['result'] = 'pass'
    except Exception as error:
        report['result'] = 'fail'
        report['error'] = repr(error)
    reports.append(report)
    print(json.dumps(report), flush=True)
result = {'version': index['version'], 'case_count': len(reports), 'cases': reports,
          'criterion': 'Exact initial reply and actual completed same-turn commands at the first real Claude Stop. Continuation repair choices are not constrained; identical-continuation behavior has its own existing live test.'}
(evidence / 'live-evaluated.json').write_text(json.dumps(result, indent=2))
sys.exit(0 if len(reports) == 41 and all(report['result'] == 'pass' for report in reports) else 1)
