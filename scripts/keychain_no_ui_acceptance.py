#!/usr/bin/env python3
"""Two ad-hoc identities test legacy Keychain denial with UI disabled. Synthetic item only."""
import datetime
import json
import pathlib
import subprocess
import tempfile
import time
import uuid

repo = pathlib.Path(__file__).resolve().parent.parent
output = repo / 'evidence/0.4.0'
output.mkdir(parents=True, exist_ok=True)
result = {'scope': 'E1 synthetic Keychain item; no real credentials', 'status': 'FAIL',
          'time': datetime.datetime.now().astimezone().isoformat(), 'checks': []}
service = 'local.codex-account-switcher.no-ui-test.' + str(uuid.uuid4())
try:
    with tempfile.TemporaryDirectory(prefix='switcher-keychain-no-ui-') as temporary:
        root = pathlib.Path(temporary)
        owner, reader = root / 'owner', root / 'reader'
        sources = sorted((repo / 'Sources/SwitcherCore').glob('*.swift'))
        build = subprocess.run(['xcrun', 'swiftc', '-O', '-swift-version', '5', *map(str, sources),
                                str(repo / 'Tests/AcceptanceHarness/KeychainNoUIWorker.swift'), '-o', str(owner)],
                               capture_output=True, text=True, timeout=90)
        (output / 'keychain-no-ui-build.log').write_text(build.stdout + build.stderr)
        build.check_returncode()
        reader.write_bytes(owner.read_bytes()); reader.chmod(0o700)
        for binary in [owner, reader]:
            subprocess.run(['codesign', '--force', '--sign', '-', '--identifier',
                            'local.switcher.test.' + binary.name, str(binary)], check=True, capture_output=True)
        def run(binary, operation, reference=None):
            return subprocess.run([str(binary), operation, service, *([reference] if reference else [])],
                                  capture_output=True, text=True, timeout=8)
        created = run(owner, 'create')
        created.check_returncode()
        reference = created.stdout.strip()
        uuid.UUID(reference)  # Validate without lowercasing the case-sensitive Keychain account.
        result['synthetic_service'] = service
        result['synthetic_reference'] = reference
        try:
            control = run(owner, 'read', reference)
            result['owner_status'] = control.stdout.strip()
            result['owner_diagnostic'] = control.stderr.strip()
            assert (control.returncode, control.stdout.strip()) in [(0, 'READ_OK'), (1, 'keychainAuthorizationRequired')], 'unexpected owner read failure'
            result['checks'].append('fresh owner process returns without waiting; exact authorization status recorded')
            start = time.monotonic()
            denied = run(reader, 'read', reference)
            result['denial_seconds'] = round(time.monotonic() - start, 3)
            result['reader_status'] = denied.stdout.strip()
            assert denied.returncode == 1 and denied.stdout.strip() == 'keychainAuthorizationRequired', 'different signer was not denied as expected'
            result['checks'].append('different identity returns authorization-required without waiting for user input')
        finally:
            removed = run(owner, 'delete', reference)
            removed.check_returncode()
            missing = run(owner, 'read', reference)
            assert missing.returncode == 1 and 'item=-25300' in missing.stderr, 'synthetic item deletion not confirmed'
            result['checks'].append('owner removed the synthetic item')
        result['status'] = 'PASS'
except Exception as error:
    result['error_type'] = type(error).__name__
finally:
    (output / 'keychain-no-ui.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False))
raise SystemExit(0 if result['status'] == 'PASS' else 1)
