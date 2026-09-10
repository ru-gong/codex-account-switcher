#!/usr/bin/env python3
"""Real subprocess crashes/concurrency against the same Swift engine used by the app. Synthetic fixtures only."""
import argparse, json, os, pathlib, signal, subprocess, tempfile, time, hashlib

p = argparse.ArgumentParser()
p.add_argument('--binary', default='.build/debug/switcherctl')
p.add_argument('--output', default='evidence/process-acceptance.json')
args = p.parse_args()
binary = str(pathlib.Path(args.binary).resolve())
results = []

def run(root, *parts, expected=0):
    proc = subprocess.run([binary, 'demo-worker', str(root), *parts], capture_output=True, text=True, timeout=25)
    assert proc.returncode == expected, (parts, proc.returncode, proc.stdout)
    assert 'SYNTHETIC_REFRESH' not in proc.stdout + proc.stderr
    return proc.stdout

def setup(root):
    subprocess.run([binary, 'demo-init', str(root)], check=True, stdout=subprocess.PIPE, timeout=25)

def wait_barrier(root, proc):
    deadline = time.monotonic() + 10
    while not (root/'barrier').exists():
        assert proc.poll() is None, 'worker exited before barrier'
        assert time.monotonic() < deadline, 'barrier timeout'
        time.sleep(.01)

def ledger(root): return json.loads((root/'state/accounts.json').read_text())
def main_identity(root): return json.loads((root/'codex-home/auth.json').read_text())['tokens']['account_id']

def check(name, fn):
    with tempfile.TemporaryDirectory(prefix='switcher-process-tests-') as tmp:
        root = pathlib.Path(tmp).resolve()
        setup(root)
        start = time.monotonic()
        try:
            fn(root)
            results.append(dict(test=name, status='PASS', seconds=round(time.monotonic()-start,3)))
        except Exception as exc:
            results.append(dict(test=name, status='FAIL', error=type(exc).__name__))
            raise

def concurrent_imports(root):
    proc = subprocess.Popen([binary,'demo-worker',str(root),'import','D','ledgerBeforeRename'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        wait_barrier(root,proc)
        assert 'busy' in run(root,'import','E',expected=1)
        (root/'release').touch(mode=0o600)
        out,err=proc.communicate(timeout=20); assert proc.returncode==0
        run(root,'import','E')
        assert len(ledger(root)['accounts'])==5
    finally:
        if proc.poll() is None: proc.kill(); proc.wait()

def switch_vs_rollback(root):
    proc = subprocess.Popen([binary,'demo-worker',str(root),'switch','B','prepared'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        wait_barrier(root,proc)
        assert 'busy' in run(root,'rollback','A',expected=1)
        (root/'release').touch(mode=0o600)
        proc.communicate(timeout=20); assert proc.returncode==0
        assert main_identity(root)=='demo-workspace-B'
        run(root,'rollback','A')
        assert main_identity(root)=='demo-workspace-A' and ledger(root).get('transaction') is None
    finally:
        if proc.poll() is None: proc.kill(); proc.wait()

def crash(root, point):
    run(root,'switch','B',point,'crash',expected=86)
    assert ledger(root).get('transaction') is not None
    identity = main_identity(root)
    assert identity == ('demo-workspace-A' if point=='prepared' else 'demo-workspace-B')
    run(root,'rollback','A')
    assert main_identity(root)=='demo-workspace-A' and ledger(root).get('transaction') is None

def sigkill(root):
    proc = subprocess.Popen([binary,'demo-worker',str(root),'switch','B','prepared'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        wait_barrier(root,proc); os.kill(proc.pid,signal.SIGKILL); proc.communicate(timeout=10)
        assert proc.returncode==-signal.SIGKILL
        run(root,'rollback','A')
        assert ledger(root).get('transaction') is None and main_identity(root)=='demo-workspace-A'
    finally:
        if proc.poll() is None: proc.kill(); proc.wait()

def rollback_crash(root):
    run(root,'switch','B')
    run(root,'rollback','A','rollbackWritten','crash',expected=86)
    run(root,'rollback','A')
    assert ledger(root).get('transaction') is None and main_identity(root)=='demo-workspace-A'

check('Q03_two_new_imports_shared_lock_and_retry', concurrent_imports)
check('Q02_real_switch_vs_rollback_same_lock', switch_vs_rollback)
check('crash_after_prepared', lambda r: crash(r,'prepared'))
check('crash_after_auth_rename_before_ledger', lambda r: crash(r,'authWritten'))
check('sigkill_lock_released_and_no_replay', sigkill)
check('crash_after_rollback_write', rollback_crash)
out=pathlib.Path(args.output); out.parent.mkdir(parents=True,exist_ok=True)
out.write_text(json.dumps({'scope':'E0 synthetic subprocesses','binary_sha256':hashlib.sha256(pathlib.Path(binary).read_bytes()).hexdigest(),'results':results},ensure_ascii=False,indent=2)+'\n')
print(f'{len(results)} PASS; evidence: {out}')
