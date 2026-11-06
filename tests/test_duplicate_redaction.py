"""Regression coverage for duplicate scanner findings (synthetic values only)."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'backup.sh'


class DuplicateRedactionTest(unittest.TestCase):
    def run_redaction(self, binary=False, duplicate=True):
        source = SCRIPT.read_text().split('redact_gitleaks_findings() {', 1)[1]
        code = source.split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            secret = 'synthetic-regression-value-not-a-credential'
            content = ('\\x00' if binary else '') + 'message: ' + secret + '\n'
            if binary:
                content = '\x00' + 'message: ' + secret + '\n'
            target = root / 'pending.json'
            target.write_text(content)
            report = root / 'report.json'
            finding = {'File': str(target), 'Secret': secret, 'StartLine': 1}
            report.write_text(json.dumps([finding] * (2 if duplicate else 1)))
            includes = root / 'includes.txt'
            includes.write_text('')
            result = subprocess.run(['python3', '-', str(root), str(report), str(includes)], input=code, text=True, capture_output=True)
            return result, target.read_text()

    def test_duplicate_findings_are_redacted_once_without_failure(self):
        result, text = self.run_redaction()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('REDACTED_BY_AGENT_STATE_BACKUP', text)
        self.assertNotIn('synthetic-regression-value-not-a-credential', text)

    def test_nested_findings_are_redacted_in_both_orders(self):
        source = SCRIPT.read_text().split('redact_gitleaks_findings() {', 1)[1]
        code = source.split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
        short = 'synthetic-nested-value'
        long = short + '-extended'
        for values in ([short, long], [long, short]):
            with self.subTest(order=values), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                target = root / 'fixture.txt'
                target.write_text('example ' + long + '\nexample ' + short + '\n')
                report = root / 'report.json'
                report.write_text(json.dumps([
                    {'File': str(target), 'Secret': value, 'StartLine': 1}
                    for value in values
                ]))
                includes = root / 'includes.txt'
                includes.write_text('')
                result = subprocess.run(['python3', '-', str(root), str(report), str(includes)], input=code, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn(short, target.read_text())
                self.assertNotIn('-extended', target.read_text())

    def test_contained_only_finding_is_already_sanitized(self):
        source = SCRIPT.read_text().split('redact_gitleaks_findings() {', 1)[1]
        code = source.split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / 'fixture.txt'
            target.write_text('example synthetic-nested-value-extended\n')
            report = root / 'report.json'
            report.write_text(json.dumps([
                {'File': str(target), 'Secret': value, 'StartLine': 1}
                for value in ['synthetic-nested-value', 'synthetic-nested-value-extended']
            ]))
            includes = root / 'includes.txt'
            includes.write_text('')
            result = subprocess.run(['python3', '-', str(root), str(report), str(includes)], input=code, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(target.read_text(), 'example REDACTED_BY_AGENT_STATE_BACKUP\n')

    def test_count_ignores_only_exact_redaction_placeholder(self):
        source = SCRIPT.read_text().split('gitleaks_unincluded_count() {', 1)[1]
        code = source.split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            report = root / 'report.json'
            includes = root / 'includes.txt'
            includes.write_text('')
            report.write_text(json.dumps([
                {'File': 'example.txt', 'Secret': value}
                for value in ['REDACTED_BY_AGENT_STATE_BACKUP',
                              'REDACTED_BY_AGENT_STATE_BACKUP-still-sensitive',
                              'synthetic-unhandled-value']
            ]))
            result = subprocess.run(['python3', '-', str(report), str(includes), str(root)], input=code, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), '2')

    def test_binary_findings_still_block(self):
        result, text = self.run_redaction(binary=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('synthetic-regression-value-not-a-credential', text)


if __name__ == '__main__':
    unittest.main()
