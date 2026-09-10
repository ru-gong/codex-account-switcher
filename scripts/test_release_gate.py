#!/usr/bin/env python3
"""Release preflight tests use synthetic evidence and mocked identities; no signing/upload."""
import json
import pathlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import package_candidate as packaging

class ReleaseGateTests(unittest.TestCase):
    identity = 'Developer ID Application: Synthetic Test (TESTTEAM00)'
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='switcher-release-gate-')
        self.addCleanup(self.tmp.cleanup)
        self.evidence = pathlib.Path(self.tmp.name) / 'acceptance.json'
        self.data = {'version': packaging.VERSION, 'source_id': 'synthetic-source', 'status': 'GO',
                     'checks': dict.fromkeys(packaging.REQUIRED_CHECKS, 'PASS')}
    def run_preflight(self, **changes):
        args = dict(identity=self.identity, notary_profile='synthetic', acceptance=self.evidence, source_id='synthetic-source')
        args.update(changes)
        self.evidence.write_text(json.dumps(self.data))
        return packaging.release_preflight(**args)
    def identity_result(self):
        return subprocess.CompletedProcess([], 0, f'  1) {"A" * 40} "{self.identity}"\n', '')
    def test_adhoc_rejected_without_keychain_access(self):
        with patch.object(packaging.subprocess, 'run') as run:
            with self.assertRaises(ValueError): self.run_preflight(identity='-')
            run.assert_not_called()
    def test_unavailable_identity_rejected(self):
        with patch.object(packaging.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '0 valid identities found', '')):
            with self.assertRaises(ValueError): self.run_preflight()
    def test_missing_profile_or_acceptance_rejected(self):
        with patch.object(packaging.subprocess, 'run', return_value=self.identity_result()):
            for change in [{'notary_profile': None}, {'acceptance': None}]:
                with self.assertRaises(ValueError): self.run_preflight(**change)
    def test_stale_source_or_no_go_rejected(self):
        with patch.object(packaging.subprocess, 'run', return_value=self.identity_result()):
            with self.assertRaises(ValueError): self.run_preflight(source_id='different-source')
            self.data['status'] = 'NO_GO'
            with self.assertRaises(ValueError): self.run_preflight()
    def test_each_unfinished_check_rejected(self):
        with patch.object(packaging.subprocess, 'run', return_value=self.identity_result()):
            for key in packaging.REQUIRED_CHECKS:
                self.data['checks'][key] = 'NOT_RUN'
                with self.assertRaises(ValueError): self.run_preflight()
                self.data['checks'][key] = 'PASS'
    def test_complete_matching_evidence_passes_preflight_only(self):
        with patch.object(packaging.subprocess, 'run', return_value=self.identity_result()):
            self.assertEqual(self.run_preflight()['source_id'], 'synthetic-source')
    def test_adhoc_distribution_needs_no_developer_account(self):
        with patch.object(packaging.subprocess, 'run') as run:
            result = self.run_preflight(distribution='adhoc', identity=None, notary_profile=None)
            self.assertEqual(result['status'], 'GO')
            run.assert_not_called()
    def test_adhoc_still_rejects_incomplete_acceptance(self):
        self.data['checks']['keychain'] = 'NOT_RUN'
        with patch.object(packaging.subprocess, 'run') as run:
            with self.assertRaises(ValueError): self.run_preflight(distribution='adhoc', identity=None, notary_profile=None)
            run.assert_not_called()
    def test_rejected_release_creates_no_artifact_or_upload(self):
        repo = pathlib.Path(self.tmp.name)
        with patch.object(packaging, 'freeze', return_value={'source_id': 'synthetic-source'}), patch.object(packaging.subprocess, 'run') as run:
            with self.assertRaises(ValueError): packaging.package(repo, release=True, distribution='developer-id', identity='-')
            self.assertFalse((repo / 'dist').exists())
            run.assert_not_called()

if __name__ == '__main__': unittest.main()
