#!/usr/bin/env python3
import pathlib
import tempfile
import unittest
import zipfile
from privacy_audit import audit, check_bytes

class PrivacyAuditTests(unittest.TestCase):
    def test_private_path_is_reported_without_value(self):
        value = b'/Users/' + b'private-person/project'
        result = check_bytes(value, 'binary')
        self.assertEqual(result[0]['rule'], 'private_home_path')
        self.assertNotIn('private-person', str(result))
    def test_real_email_shape_is_rejected_but_demo_is_allowed(self):
        self.assertTrue(check_bytes(b'name' + b'@' + b'personal.example', 'doc'))
        self.assertFalse(check_bytes(b'a@example.invalid', 'doc'))
    def test_generated_secret_shapes_are_blocked(self):
        for value in [b'sk-' + b'A' * 40, b'ghp_' + b'B' * 40, b'eyJ' + b'A' * 20 + b'.' + b'B' * 20 + b'.' + b'C' * 20]:
            self.assertTrue(check_bytes(value, 'fixture'))
    def test_additional_private_identity_is_not_printed(self):
        result = check_bytes(b'local-person', 'fixture', [b'local-person'])
        self.assertEqual(result, [{'file': 'fixture', 'rule': 'private_identifier'}])
    def test_zip_contents_are_examined(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / 'app.zip'
            with zipfile.ZipFile(path, 'w') as archive:
                archive.writestr('App.app/Contents/MacOS/App', b'/Users/' + b'private-person/file')
            self.assertEqual(audit(path)['status'], 'FAIL')
    def test_unreviewed_source_path_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary)
            (path / 'personal-notes.md').write_text('unreviewed')
            self.assertEqual(audit(path)['findings'][0]['rule'], 'unreviewed_source_path')
    def test_private_state_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary)
            (path / 'docs').mkdir(); (path / 'docs/auth.json').write_text('{}')
            self.assertTrue(any(x['rule']=='private_artifact_type' for x in audit(path)['findings']))

if __name__ == '__main__': unittest.main()
