#!/usr/bin/env bash
# Synthetic offline native-stream fixtures, never native permission evidence.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-readonly-evidence)
python3 - "$ROOT/bin/fm-readonly-evidence.py" "$LAB" <<'PY'
import copy
import json
from pathlib import Path
import subprocess
import sys

cli, lab = sys.argv[1], Path(sys.argv[2])
path = lab / 'native.jsonl'
secret = 'NEVER_ECHO_NATIVE_PRIVATE_CONTENT_5398'
init = {'type': 'system', 'subtype': 'init', 'claude_code_version': '2.1.312',
        'tools': ['Read', 'Glob', 'Grep'], 'mcp_servers': [], 'session_id': 'fixture'}
call = {'type': 'assistant', 'session_id': 'fixture',
        'message': {'content': [{'type': 'tool_use', 'id': 'call-1', 'name': 'Read',
                                 'input': {'file_path': secret}},
                                {'type': 'text', 'text': 'Write was denied! ' + secret}]}}
final = {'type': 'result', 'session_id': 'fixture', 'subtype': 'success',
         'is_error': False, 'terminal_reason': 'completed', 'permission_denials': [],
         'result': 'All writes denied: ' + secret}


def run(events, ok=True):
    path.write_text(''.join(json.dumps(x) + '\n' for x in events))
    p = subprocess.run(['python3', cli, '--stream', str(path)], capture_output=True, text=True)
    assert (p.returncode == 0) == ok, (p.returncode, p.stdout, p.stderr)
    assert secret not in p.stdout + p.stderr
    return json.loads(p.stdout) if p.stdout else None


summary = run([init, call, final])
assert summary['unavailable_tools'] == ['Bash', 'Edit', 'Write']
assert summary['actual_invocations'] == {'Read': 1}
assert summary['denial_event_count'] == 0
assert summary['native_permission_denials_reported'] == {}
assert summary['assistant_prose_used_as_evidence'] is False and summary['reviewer_go'] is False
# Repeated streaming presentation of one call is not a second invocation.
assert run([init, call, copy.deepcopy(call), final])['actual_invocations'] == {'Read': 1}
# A synthetic native denial RECEIPT is distinct from prose and tool removal.
# This validates parsing only; no actual Write permission or model is granted.
denied = copy.deepcopy(final)
denied['permission_denials'] = [{'tool_name': 'Write', 'tool_use_id': 'blocked-1',
                                 'tool_input': {'content': secret}}]
summary = run([init, call, denied])
assert summary['native_permission_denials_reported'] == {'Write': 1}
assert summary['denial_event_count'] == 1 and summary['actual_invocations'] == {'Read': 1}
assert summary['reviewer_go'] is False
# Exposed permissions are reported honestly, not relabeled read-only or denied.
unsafe = copy.deepcopy(init)
unsafe['tools'].append('Bash')
summary = run([unsafe, call, final])
assert 'Bash' in summary['available_tools'] and 'Bash' not in summary['unavailable_tools']
assert summary['reviewer_go'] is False
# Missing denial field is unknown, not a fabricated empty denial array.
missing = copy.deepcopy(final)
del missing['permission_denials']
run([init, call, missing], ok=False)
# Truncation, interrupted/failed completion, duplicate finals and session mixup reject.
run([init, call], ok=False)
run([init, call, final, final], ok=False)
run([init, call, final, {'type': 'trailing'}], ok=False)
for field, value in [('is_error', True), ('terminal_reason', 'interrupted'),
                     ('subtype', 'error'), ('session_id', 'other')]:
    broken = copy.deepcopy(final)
    broken[field] = value
    run([init, call, broken], ok=False)
future = copy.deepcopy(init)
future['claude_code_version'] = '9.9.9'
run([future, call, final], ok=False)
bad = copy.deepcopy(init)
bad['tools'] = [secret]
run([bad, call, final], ok=False)
path.write_text(secret + '{not json}')
p = subprocess.run(['python3', cli, '--stream', str(path)], capture_output=True, text=True)
assert p.returncode != 0 and secret not in p.stdout + p.stderr
print('ok - native evidence parser separates tool removal, actual invocations and native receipts; rejects incomplete/unknown streams without leaking prose')
# Canonical NON-EXECUTING probe recipe, exercised with a real fixture process
# that is explicitly a fake Claude. No installed native CLI/model is run.
import os
root = Path(cli).parent.parent
probe = lab / 'probe'
subject = probe / 'subject'
subject.mkdir(parents=True)
(probe / 'prompt.txt').write_text('synthetic probe only')
(probe / 'explicit-settings.json').write_text(json.dumps({'disableAllHooks': True, 'disableClaudeAiConnectors': True}))
(probe / 'mcp-empty.json').write_text('{"mcpServers":{}}')
profile = probe / 'profile.json'
profile.write_text('{"permissions":{"defaultMode":"manual"}}')
(subj_file := subject / 'canary').write_text('fixture')
for args in [('init', '-q', '-b', 'main'), ('add', 'canary'),
             ('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture')]:
    subprocess.run(['git', '-C', str(subject), *args], check=True)
head = subprocess.check_output(['git', '-C', str(subject), 'rev-parse', 'HEAD'], text=True).strip()
fakebin = lab / 'fakebin'
fakebin.mkdir()
fake = fakebin / 'claude'
fake.write_text('''#!/usr/bin/env python3
import json,os,sys
assert all(os.environ.get(k)=='1' for k in ['DISABLE_AUTOUPDATER','CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC','DISABLE_GROWTHBOOK'])
a=sys.argv[1:]
assert a[a.index('--tools')+1]=='Read,Glob,Grep'
assert a[a.index('--permission-mode')+1]=='manual' and a[a.index('--permission-prompts')+1]=='none'
assert '--restricted' in a and '--strict-mcp-config' in a and '--safe-mode' in a
assert not any('bypass' in x or 'skip-permissions' in x for x in a)
print(json.dumps({'type':'system','subtype':'init','claude_code_version':'2.1.312','tools':a[a.index('--tools')+1].split(','),'mcp_servers':[],'session_id':'fixture'}))
print(json.dumps({'type':'result','session_id':'fixture','subtype':'success','is_error':False,'terminal_reason':'completed','permission_denials':[]}))
''')
fake.chmod(0o755)
parent_environment = dict(os.environ)
env = dict(parent_environment, PATH=str(fakebin) + os.pathsep + os.environ['PATH'])
for variant in ('{}', '{"tengu_calm_nautilus":false,"tengu_umber_kestrel":true}'):
    env['CLAUDE_INTERNAL_FC_OVERRIDES'] = variant
    p = subprocess.run(['bash', str(root / 'bin/fm-spawn.sh'), '--exact-head-review-plan', str(probe)],
                       capture_output=True, text=True, env=env)
    assert p.returncode == 0, p.stderr
    plan = json.loads(p.stdout)
    assert plan['native_execution_authorized'] is False and plan['native_permission_proved'] is False
    assert plan['argv'][0] == str(fake.resolve())
    assert plan['environment'] == {'DISABLE_AUTOUPDATER':'1','CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC':'1','DISABLE_GROWTHBOOK':'1'}
    assert not (probe / 'stdout.jsonl').exists(), 'planner launched or captured a process'
# Snapshot before the child. Run only the fake fixture through the returned
# argv/process-local env, wait for termination, then let the parent capture.
guard = root / 'bin/fm-exact-head-guard.py'
state = probe / 'boundary.json'
subprocess.run(['python3', str(guard), 'snapshot', '--repo', str(subject), '--state', str(state),
                '--target', head, '--base', head, '--moving-ref', 'refs/heads/main', '--watch', str(profile)],
               check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
assert plan['argv'][0] == str(fake)
with open(plan['stdin'], 'rb') as inp, open(plan['stdout'], 'wb') as out, open(plan['stderr'], 'wb') as err:
    p = subprocess.run(plan['argv'], cwd=plan['cwd'], env=dict(env, **plan['environment']),
                       stdin=inp, stdout=out, stderr=err)
assert p.returncode == 0
assert dict(os.environ) == parent_environment
inbox = probe / 'inbox'
inbox.mkdir()
(inbox / '001.msg').write_text('pending instruction, never acknowledged by a permission receipt')
p = subprocess.run(plan['parent_capture_argv'], capture_output=True, text=True)
assert p.returncode == 0, p.stderr
receipt = probe / 'capture-receipt.json'
saved = json.loads(receipt.read_text())
assert saved['head'] == head and saved['postguard_passed'] is True
assert saved['reviewer_go'] is False and saved['native_admission'] is False
assert saved['inbox_acknowledged'] is False and (inbox / '001.msg').exists()
assert receipt.stat().st_mode & 0o777 == 0o600
# Existing output must survive unchanged; no receipt on partial/unsafe/changed input.
p = subprocess.run(plan['parent_capture_argv'], capture_output=True, text=True)
assert p.returncode != 0 and json.loads(receipt.read_text()) == saved
receipt.unlink()
# A receipt may not be placed in the protected subject or through an alias.
for destination in (subject / 'receipt.json', probe / 'alias-receipt.json'):
    if destination.name == 'alias-receipt.json':
        destination.symlink_to(probe / 'elsewhere.json')
    p = subprocess.run(['python3', cli, '--stream', plan['stdout'], '--guard-state', str(state),
                        '--report', str(destination)], capture_output=True, text=True)
    assert p.returncode != 0
    assert not (subject / 'receipt.json').exists() and not (probe / 'elsewhere.json').exists()
for events in ([init, call], [unsafe, call, final],
               [dict(init, mcp_servers=[{'name':'fixture'}]), call, final]):
    Path(plan['stdout']).write_text(''.join(json.dumps(x)+'\n' for x in events))
    p = subprocess.run(plan['parent_capture_argv'], capture_output=True, text=True)
    assert p.returncode != 0 and not receipt.exists()
Path(plan['stdout']).write_text(''.join(json.dumps(x)+'\n' for x in [init, call, final]))
profile.write_text('{"unknownPolicy":true}')
p = subprocess.run(plan['parent_capture_argv'], capture_output=True, text=True)
assert p.returncode != 0 and not receipt.exists() and (inbox / '001.msg').exists()
# Numeric truthy settings must not masquerade as native Boolean controls.
badprobe = lab / 'badprobe'
(badprobe / 'subject').mkdir(parents=True)
(badprobe / 'prompt.txt').write_text('fixture')
(badprobe / 'mcp-empty.json').write_text('{"mcpServers":{}}')
(badprobe / 'explicit-settings.json').write_text('{"disableAllHooks":1,"disableClaudeAiConnectors":1}')
p = subprocess.run(['bash', str(root / 'bin/fm-spawn.sh'), '--exact-head-review-plan', str(badprobe)],
                   capture_output=True, text=True, env=env)
assert p.returncode != 0 and not p.stdout
print('ok - canonical plan keeps restrictive argv/no-refresh env fixed; parent capture refuses partial/tools/MCP/settings failures without acknowledgement or review GO')
PY
pass 'synthetic evidence semantics only; no native denial or reviewer GO claimed'
