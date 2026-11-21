#!/usr/bin/env python3
"""Black-box regression checks that never opt in to foreground interaction.

Requires macOS and a signed-in Gemini profile. Does not submit prompts. Legacy
running-job checks only observe an already-running App; they never launch it.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--bin', required=True, type=Path)
args = parser.parse_args()
binary = str(args.bin.resolve())
env = dict(os.environ)
for key in ('GEMINI_TASK_BACKGROUND_WORKER', 'GEMINI_TASK_NO_NAVIGATION'):
    env.pop(key, None)
passed = 0

def run(argv, error=None, code=1, extra_env=None):
    global passed
    proc = subprocess.run([binary, *argv], env={**env, **(extra_env or {})}, capture_output=True, text=True, timeout=15)
    result = json.loads(proc.stdout)
    assert proc.returncode == code, (argv, proc.returncode, result)
    if error:
        assert result.get('error') == error, (argv, result)
    passed += 1
    return result

with tempfile.TemporaryDirectory(prefix='gemini-task-policy-') as tmp:
    env['GEMINI_TASK_STATE_DIR'] = tmp
    doctor = run(['doctor', '--ui'], code=0)
    assert doctor['default_mode'] == 'background'
    assert doctor['foreground_requires_flag'] == '--interactive'
    assert doctor['worker_policy'] == 'single_app'
    for argv in (
        ['models'], ['models', '--worker'],
        ['start', '--cwd', tmp, '--prompt', 'MUST NOT SUBMIT', '--attach', 'missing.m4a'],
        ['run', '--cwd', tmp, '--prompt', 'MUST NOT SUBMIT', '--allow-new-folder'],
        ['start', '--cwd', tmp, '--prompt', 'MUST NOT SUBMIT', '--allow-new-folder', '--attach', 'missing.m4a'],
        ['follow-up', 'no-such-job', '--prompt', 'MUST NOT SUBMIT', '--attach', 'missing.m4a'],
    ):
        run(argv, 'interactive_required')
    for argv, extra_env in (
        (['doctor', '--interactive', '--worker'], {}),
        (['doctor', '--interactive', '--no-navigation'], {}),
        (['doctor', '--interactive'], {'GEMINI_TASK_BACKGROUND_WORKER': '1'}),
        (['doctor', '--interactive'], {'GEMINI_TASK_NO_NAVIGATION': '1'}),
        (['tasks', '--interactive'], {}),
        (['read', 'c_test', '--interactive'], {}),
    ):
        run(argv, 'usage', extra_env=extra_env)
    for argv in (
        ['start', '--no-navigation', '--cwd', tmp, '--prompt', 'MUST NOT SUBMIT'],
        ['run', '--no-navigation', '--cwd', tmp, '--prompt', 'MUST NOT SUBMIT'],
        ['open', 'c_1234', '--no-navigation'],
        ['tasks', '--query', 'MUST NOT SEARCH', '--no-navigation'],
        ['read', 'c_1234', '--no-navigation'],
        ['follow-up', 'c_1234', '--cwd', tmp, '--prompt', 'MUST NOT SUBMIT', '--no-navigation'],
    ):
        run(argv, 'would_navigate')
    account = doctor.get('account_id')
    assert account, 'A signed-in local Gemini profile is required for archive checks'
    root = Path(tmp) / 'accounts' / account
    root.mkdir(parents=True, exist_ok=True)
    now = time.time() - 978307200
    running_id, completed_id = str(uuid.uuid4()), str(uuid.uuid4())
    for job_id, state in ((running_id, 'running'), (completed_id, 'completed')):
        job = dict(jobID=job_id, marker='GT-POLICY-UNMATCHED-' + job_id, cwd=tmp,
                   state=state, artifacts=[], updatedAt=now)
        if state == 'completed':
            job['transcript'] = dict(messages=[
                dict(role='user', text='[' + job['marker'] + ']\nCurrent turn'),
                dict(role='assistant', text='ARCHIVED POLICY ANSWER')], capturedAt=now)
        (root / (job_id + '.json')).write_text(json.dumps(job))
    stale_id = str(uuid.uuid4())
    stale = dict(job, jobID=stale_id, marker='GT-CURRENT-TURN-NOT-ARCHIVED')
    (root / (stale_id + '.json')).write_text(json.dumps(stale))
    run(['answer', stale_id], 'answer_not_archived')
    run(['follow-up', completed_id, '--prompt', 'MUST NOT SUBMIT'], 'interactive_required')
    run(['cancel', running_id], 'interactive_required')
    run(['open', running_id], 'interactive_required')
    assert run(['answer', completed_id], code=0)['answer'] == 'ARCHIVED POLICY ANSWER'
    assert run(['status', completed_id], code=0)['status'] == 'completed'
    assert run(['wait', completed_id, '--timeout', '1'], code=0)['status'] == 'completed'
    run(['status', '--worker', running_id], 'not_worker_job')
    if doctor['app_process_count']:
        if doctor.get('ui', {}).get('responsive') is False:
            run(['status', running_id], 'app_unresponsive')
            run(['wait', running_id, '--timeout', '1'], 'app_unresponsive')
        else:
            selected = run(['status', running_id], code=0)
            assert selected['status'] == 'running'
            assert 'no-navigation' in selected.get('progress', '')
            pending = run(['wait', running_id, '--timeout', '1'], code=3)
            assert pending['status'] == 'running'
    else:
        run(['status', running_id], 'would_navigate')
    after = run(['doctor'], code=0)
    assert after['app_process_count'] == doctor['app_process_count'], 'App count changed during non-mutating checks'
print(json.dumps({'passed': passed, 'default_mode': 'background', 'submitted_prompts': 0}))
