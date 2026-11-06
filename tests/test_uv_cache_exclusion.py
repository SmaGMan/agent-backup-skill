from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class UvCacheExclusionTests(unittest.TestCase):
    def test_real_mirror_skips_uv_cache_and_keeps_other_state(self):
        script = (ROOT / 'scripts/backup.sh').read_text()
        marker = '  python3 - "$SOURCE_DIR" "$BACKUP_DIR" "$EXCLUDES_FILE" "$INCLUDES_FILE" <<\'PY\'\n'
        mirror = script.split(marker, 1)[1].split('\nPY\n', 1)[0]
        excludes = ROOT / 'excludes.txt'
        self.assertIn('cache/uv/', excludes.read_text().splitlines())
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            src, dst = root / 'source', root / 'backup'
            src.mkdir()
            dst.mkdir()
            samples = {
                'cache/uv/archive-v0/package/data.bin': b'package cache',
                'cache/uv-extra/keep.bin': b'other cache',
                'cache/images/keep.bin': b'user image',
                'tools/custom.py': b'user tool',
                'sessions/keep.json': b'{}',
                'state.db': b'durable state',
            }
            for rel, data in samples.items():
                path = src / rel
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            includes = root / 'includes.txt'
            includes.write_text((ROOT / 'includes.txt').read_text())
            subprocess.run(
                [sys.executable, '-', str(src), str(dst), str(excludes), str(includes)],
                input=mirror, text=True, check=True, capture_output=True,
            )
            self.assertFalse((dst / 'cache/uv').exists())
            for rel, data in samples.items():
                self.assertEqual((src / rel).read_bytes(), data)
                if not rel.startswith('cache/uv/'):
                    self.assertEqual((dst / rel).read_bytes(), data)
            self.assertIn('cache/uv/', (dst / 'excluded.txt').read_text())


if __name__ == '__main__':
    unittest.main()
