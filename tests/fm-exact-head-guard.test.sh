#!/usr/bin/env bash
# Public CLI regressions; these are file-boundary tests, not native admission.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-exact-head-guard)
python3 - "$ROOT/bin/fm-exact-head-guard.py" "$LAB" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys

cli, lab = Path(sys.argv[1]), Path(sys.argv[2])
repo = lab / 'subject'
repo.mkdir()


def git(*args):
    return subprocess.check_output(['git', '-C', str(repo), *args], text=True).strip()


def run(*args, ok=True, message=None):
    result = subprocess.run(['python3', str(cli), *map(str, args)], capture_output=True, text=True)
    assert (result.returncode == 0) == ok, (args, result.returncode, result.stdout, result.stderr)
    if message:
        assert message in result.stdout + result.stderr, result
    return result


git('init', '-q')
git('config', 'user.name', 'Fixture')
git('config', 'user.email', 'fixture@example.invalid')
(repo / 'tracked').write_text('baseline\n')
git('add', '.')
git('commit', '-qm', 'baseline')
git('branch', '-M', 'main')
sha = git('rev-parse', 'HEAD')
settings = lab / 'settings.json'
settings.write_text('{"mode":"manual"}\n')
state = lab / 'state.json'


def snap(output=state, watch=settings, target=sha, base=sha, ref='refs/heads/main', ok=True, message=None):
    return run('snapshot', '--repo', repo, '--state', output, '--target', target,
               '--base', base, '--moving-ref', ref, '--watch', watch, ok=ok, message=message)


def verify(ok=True, message=None):
    return run('verify', '--state', state, ok=ok, message=message)


snap()
assert state.stat().st_mode & 0o777 == 0o600
verify(message='NOT reviewer GO')
snap(ok=False, message='already exists')
# Directly pins the red case reproduced against the external installed helper:
# retargeting a previously watched lexical pathname must NEVER verify.
original = settings.read_bytes()
settings.unlink()
replacement = lab / 'bypass.json'
replacement.write_text('{"mode":"bypassPermissions"}\n')
settings.symlink_to(replacement)
verify(ok=False, message='symlinked')
state.unlink()
snap(ok=False, message='symlinked')
settings.unlink()
settings.write_bytes(original)
# A symlink in an ancestor is equally unsupported, even when target bytes match.
real = lab / 'real'
real.mkdir()
(real / 'settings.json').write_bytes(original)
alias = lab / 'alias'
alias.symlink_to(real, target_is_directory=True)
snap(watch=alias / 'settings.json', ok=False, message='symlinked')
alias.unlink()
# Swapping an initially real ancestor for a symlink after snapshot also refuses.
alias.mkdir()
(alias / 'settings.json').write_bytes(original)
snap(watch=alias / 'settings.json')
(alias / 'settings.json').unlink()
alias.rmdir()
alias.symlink_to(real, target_is_directory=True)
verify(ok=False, message='symlinked')
state.unlink()
# Missing settings and missing ancestor are recorded, not ignored.
missing = lab / 'missing-parent' / 'settings.json'
snap(watch=missing)
verify()
missing.parent.mkdir()
missing.write_text('{}')
verify(ok=False, message='changed')
state.unlink()
# A replaced real directory is detected even with identical settings contents.
snap(watch=real / 'settings.json')
real.rename(lab / 'old-real')
real.mkdir()
(real / 'settings.json').write_bytes(original)
verify(ok=False, message='changed')
state.unlink()
# In-place settings mutation is detected.
snap()
settings.write_text('{"mode":"bypassPermissions"}\n')
verify(ok=False, message='changed')
settings.write_bytes(original)
state.unlink()
# Tracked and untracked writes, wrong head, changed ref and ambiguous SHA refuse.
snap()
(repo / 'tracked').write_text('mutated\n')
verify(ok=False, message='dirty')
(repo / 'tracked').write_text('baseline\n')
(repo / 'untracked').write_text('untracked')
verify(ok=False, message='dirty')
snap(output=lab / 'dirty.json', ok=False, message='dirty')
(repo / 'untracked').unlink()
git('commit', '--allow-empty', '-qm', 'next')
new = git('rev-parse', 'HEAD')
verify(ok=False, message='HEAD')
# Detached HEAD stays fixed while the explicitly watched branch moves.
git('checkout', '--detach', '-q', sha)
verify(ok=False, message='moving ref')
git('update-ref', 'refs/heads/main', sha)
verify()
state.unlink()
snap(target=sha[:8], ok=False, message='full lowercase')
snap(base='HEAD', ok=False, message='full lowercase')
snap(ref='HEAD', ok=False, message='full refs/')
snap(output=repo / 'unsafe-state', ok=False, message='outside')
# Sparse and hidden tracked modifications cannot produce a clean baseline.
git('config', 'core.sparseCheckout', 'true')
snap(ok=False, message='sparse')
git('config', 'core.sparseCheckout', 'false')
git('update-index', '--assume-unchanged', 'tracked')
snap(ok=False, message='assume-unchanged')
git('update-index', '--no-assume-unchanged', 'tracked')
git('update-index', '--skip-worktree', 'tracked')
snap(ok=False, message='skip-worktree')
git('update-index', '--no-skip-worktree', 'tracked')
# Private parent-owned snapshots cannot be replaced by permissive state files.
snap()
state.chmod(0o644)
verify(ok=False, message='0600')
state.chmod(0o600)
state.write_text('[]')
verify(ok=False, message='schema')
state.write_text(json.dumps({'schema': 'firstmate-file-exact-head.v1', 'boundary': {}}))
verify(ok=False, message='malformed')
state.unlink()
# Settings special files must not hang or get treated as empty configuration.
fifo = lab / 'fifo'
os.mkfifo(fifo)
snap(watch=fifo, ok=False, message='regular file')
# Submodules are refused even when clean: no recursive hidden-change claim.
module = lab / 'module'
subprocess.run(['git', 'init', '-q', str(module)], check=True)
subprocess.run(['git', '-C', str(module), '-c', 'user.name=Fixture', '-c',
                'user.email=fixture@example.invalid', 'commit', '--allow-empty', '-qm', 'module'], check=True)
git('checkout', '-q', 'main')
git('-c', 'protocol.file.allow=always', 'submodule', 'add', '-q', str(module), 'child')
git('commit', '-qm', 'submodule')
module_head = git('rev-parse', 'HEAD')
snap(target=module_head, ok=False, message='submodule subjects are unsupported')
(repo / 'child' / 'untracked').write_text('dirty child')
snap(target=module_head, ok=False, message='dirty')
print('ok - exact-head/settings CLI guards reject alias retarget, ancestor replacement, dirty/ref/sparse changes and unsafe state')
# Privacy-preserving mixed-profile preparation. These are synthetic offline
# JSON fixtures, NOT the real user profile, credentials, or a native canary.
profile = lab / 'profile.json'
profile_state = lab / 'profile-state.json'
secret = 'DO_NOT_PERSIST_SENSITIVE_VALUE_5972'
private_key = '/private/project/person@example.invalid'
baseline = {'numStartups': 10, 'permissions': {'defaultMode': 'manual'},
            'projects': {private_key: {'trusted': False}},
            'private-unknown-key-7162': secret}
profile.write_text(json.dumps(baseline))


def profile_snap(ok=True):
    return run('profile-snapshot', '--profile', profile, '--state', profile_state, ok=ok)


def profile_verify(ok=True):
    result = run('profile-verify', '--state', profile_state, ok=ok)
    for sensitive in (secret, private_key, 'private-unknown-key-7162'):
        assert sensitive not in result.stdout + result.stderr
    return json.loads(result.stdout) if result.stdout else None


profile_snap()
assert profile_state.stat().st_mode & 0o777 == 0o600
stored = profile_state.read_text()
assert all(x not in stored for x in (secret, private_key, 'private-unknown-key-7162', 'manual'))
assert '"numStartups": 10' not in stored
assert profile_verify()['integrity_passed'] is True
# Diagnostic comparison of a separate before-image never becomes admission,
# even when the after-file has identical semantic contents.
other_profile = lab / 'other-profile.json'
other_profile.write_text(json.dumps(baseline))
result = run('profile-diff', '--state', profile_state, '--after-profile', other_profile, ok=False)
assert json.loads(result.stdout)['comparison_only'] is True
assert json.loads(result.stdout)['integrity_passed'] is False
# An observed exact counter increment is evidence of the arithmetic delta,
# never a policy exception or automatic admission.
changed = dict(baseline, numStartups=11)
profile.write_text(json.dumps(changed))
delta = profile_verify(ok=False)
assert any(x['category'] == 'counter-increment-observed-NOT-authorized' for x in delta['changes'])
assert delta['bookkeeping_exceptions_applied'] == 0 and delta['native_admission'] is False
assert delta['before_file_sha256'] != delta['after_file_sha256']
# A simultaneous policy change cannot hide behind the counter update.
changed['permissions'] = {'defaultMode': 'bypassPermissions'}
profile.write_text(json.dumps(changed))
delta = profile_verify(ok=False)
assert any(x['category'] == 'policy' for x in delta['changes'])
assert any(x['category'] == 'counter-increment-observed-NOT-authorized' for x in delta['changes'])
# Unknown key addition/deletion/value changes remain opaque AND rejecting.
changed = dict(baseline, **{'new-private-field-7719': secret})
profile.write_text(json.dumps(changed))
delta = profile_verify(ok=False)
assert any(x['category'] == 'unknown' and x['change'] == 'added' for x in delta['changes'])
assert 'new-private-field-7719' not in json.dumps(delta)
changed = dict(baseline)
del changed['private-unknown-key-7162']
profile.write_text(json.dumps(changed))
assert any(x['change'] == 'removed' for x in profile_verify(ok=False)['changes'])
changed = dict(baseline, **{'private-unknown-key-7162': 'different-private-value'})
profile.write_text(json.dumps(changed))
assert any(x['category'] == 'unknown' for x in profile_verify(ok=False)['changes'])
# No 'counter' exemption for jumps, deletions, strings or Booleans.
for value in (12, '11', True, None):
    profile.write_text(json.dumps(dict(baseline, numStartups=value)))
    delta = profile_verify(ok=False)
    assert not any(x['category'] == 'counter-increment-observed-NOT-authorized' for x in delta['changes'])
# Even byte-identical inode replacement and serialization-only changes refuse.
profile.write_text(json.dumps(baseline))
profile_state.unlink()
profile_snap()
profile.rename(lab / 'old-profile.json')
profile.write_text(json.dumps(baseline))
delta = profile_verify(ok=False)
assert delta['path_identity_changed'] and not delta['changes']
profile.write_text(json.dumps(baseline, indent=2))
assert profile_verify(ok=False)['file_boundary_changed']
# Dedicated credential stores refuse BEFORE opening; a FIFO must not hang.
credential_fifo = lab / '.credentials.json'
os.mkfifo(credential_fifo)
run('profile-snapshot', '--profile', credential_fifo, '--state', lab / 'bad-state',
    ok=False, message='credential stores')
assert not (lab / 'bad-state').exists()
# Recognized credential-bearing objects do not produce a before-image.
profile_state.unlink()
profile.write_text('{"primaryApiKey":"' + secret + '"}')
profile_snap(ok=False)
assert not profile_state.exists()
# Malformed/ambiguous JSON cannot quietly discard unknown or duplicate keys.
for contents in ('[]', '{"x":1,"x":2}', '{"x":NaN}', '{"' + secret + '":'):
    profile.write_text(contents)
    result = run('profile-snapshot', '--profile', profile, '--state', profile_state, ok=False)
    assert secret not in result.stdout + result.stderr
    assert not profile_state.exists()
# Symlink ancestry still refuses, and permissive snapshot modes refuse.
profile.write_text(json.dumps(baseline))
profile_snap()
profile_state.chmod(0o644)
profile_verify(ok=False)
profile_state.chmod(0o600)
profile.unlink()
profile.symlink_to(lab / 'old-profile.json')
profile_verify(ok=False)
print('ok - private structural profile diagnostics reject policy/unknown/counter changes without raw profile output or blanket exceptions')
PY
pass 'file-only exact-head guard regression; no native permission admission claimed'
