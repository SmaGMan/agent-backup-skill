"""Image baseline regressions; all source trees and Git repos are temporary."""
from __future__ import annotations

import importlib.util
import inspect
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "generate-hermes-patch.py"
SPEC = importlib.util.spec_from_file_location("patch_generator_provenance_tests", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

REVISION = "bf0203a794a07aac3ff764972ab9087baa4e4f4e"
ENV_NAMES = (
    "HERMES_IMAGE_REVISION", "HERMES_DOCKER_IMAGE_REVISION",
    "OCI_IMAGE_REVISION", "HERMES_BASE_REVISION",
)


class ProvenanceTests(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory(prefix="hermes-provenance-test-", dir="/tmp")
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        home = self.root / "home"
        tmpdir = self.root / "tmp"
        home.mkdir()
        tmpdir.mkdir()
        # Whitelist only: discard inherited Git routing/config, credentials,
        # revision aliases and PATH before any fixture Git subprocess runs.
        env = mock.patch.dict(os.environ, {
            "PATH": "/usr/bin:/bin", "HOME": str(home), "TMPDIR": str(tmpdir),
            "LANG": "C.UTF-8", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.hooksPath",
            "GIT_CONFIG_VALUE_0": "/dev/null", "GIT_ALLOW_PROTOCOL": "file",
            "GIT_TERMINAL_PROMPT": "0",
        }, clear=True)
        env.start()
        self.addCleanup(env.stop)
        tempdir = mock.patch.object(tempfile, "tempdir", str(tmpdir))
        tempdir.start()
        self.addCleanup(tempdir.stop)
        self.source = self.root / "install"
        self.source.mkdir()
        init = self.source / "hermes_cli" / "__init__.py"
        init.parent.mkdir()
        init.write_text('__release_date__ = "2026.9.24"\n', encoding="utf-8")
        registry = mock.patch.object(
            MODULE, "revision_from_docker_tag",
            side_effect=AssertionError("must not look up the stale release-date tag"),
        )
        registry.start()
        self.addCleanup(registry.stop)

    def write_stamp(self, **fields: object) -> Path:
        path = self.source / "install-stamp.json"
        path.write_text(json.dumps({
            "schemaVersion": 2, "commit": REVISION, "distribution": "docker",
            "baseVersion": "0.22.5", "displayVersion": "0.22.5", **fields,
        }), encoding="utf-8")
        return path

    def test_image_provenance_matches_stamp_without_registry(self) -> None:
        self.write_stamp()
        provenance = self.root / "image-provenance.json"
        provenance.write_text(json.dumps({"schema": 1, "revision": REVISION}), encoding="utf-8")
        self.assertIn("image_provenance_path", inspect.signature(MODULE.resolve_baseline_revision).parameters)
        info = MODULE.resolve_baseline_revision(self.source, image_provenance_path=provenance)
        self.assertEqual(info["revision"], REVISION)
        self.assertEqual(info["method"], "image_provenance")
        self.assertEqual(info["local_version"], "0.22.5")

    def test_conflicting_markers_fail_instead_of_choosing_a_baseline(self) -> None:
        self.write_stamp(commit="1" * 40)
        provenance = self.root / "image-provenance.json"
        provenance.write_text(json.dumps({"revision": REVISION}), encoding="utf-8")
        with self.assertRaisesRegex(RuntimeError, "conflict"):
            MODULE.resolve_baseline_revision(self.source, image_provenance_path=provenance)

    def test_invalid_or_unknown_new_stamp_never_uses_release_date(self) -> None:
        for value in ["x" * 40, "abc123", "0" * 40, "", None, 123]:
            with self.subTest(commit=value):
                self.write_stamp(commit=value)
                with self.assertRaisesRegex(RuntimeError, "baseline metadata"):
                    MODULE.resolve_baseline_revision(self.source)

    def test_unreadable_json_shapes_have_actionable_metadata_errors(self) -> None:
        for content in ["{broken", "[]", '"text"']:
            with self.subTest(content=content):
                (self.source / "install-stamp.json").write_text(content, encoding="utf-8")
                with self.assertRaisesRegex(RuntimeError, "baseline metadata"):
                    MODULE.resolve_baseline_revision(self.source)

    def test_invalid_explicit_override_never_falls_back(self) -> None:
        self.write_stamp()
        for value in ["not-a-revision", "0" * 40]:
            with (
                self.subTest(value=value),
                mock.patch.dict(os.environ, {"HERMES_IMAGE_REVISION": value}),
                self.assertRaisesRegex(RuntimeError, "HERMES_IMAGE_REVISION"),
            ):
                MODULE.resolve_baseline_revision(self.source)

    def test_only_root_install_stamp_is_excluded(self) -> None:
        self.assertTrue(MODULE.is_excluded("install-stamp.json"))
        self.assertFalse(MODULE.is_excluded("agent/install-stamp.json"))
        self.write_stamp()
        self.assertNotIn("install-stamp.json", list(MODULE.iter_current_files(self.source)))

    def test_install_stamp_commit_precedes_stale_release_date(self) -> None:
        self.write_stamp()
        info = MODULE.resolve_baseline_revision(self.source)
        self.assertEqual(info["revision"], REVISION)
        self.assertEqual(info["method"], "install_stamp")
        self.assertEqual(info["local_version"], "0.22.5")

    def test_default_image_identity_is_scoped_to_canonical_install(self) -> None:
        self.write_stamp()
        provenance = self.root / "image-provenance.json"
        provenance.write_text(json.dumps({"revision": "1" * 40}), encoding="utf-8")
        with mock.patch.object(MODULE, "DEFAULT_IMAGE_PROVENANCE_PATH", provenance):
            info = MODULE.resolve_baseline_revision(self.source)
        self.assertEqual(info["revision"], REVISION)
        self.assertEqual(info["method"], "install_stamp")

    def test_canonical_install_automatically_reads_image_provenance(self) -> None:
        self.write_stamp()
        provenance = self.root / "image-provenance.json"
        provenance.write_text(json.dumps({"revision": REVISION}), encoding="utf-8")
        # Resolve only the temporary source as the canonical install. No /opt
        # files are written; the JSON files themselves are real fixture files.
        with mock.patch.object(MODULE, "DEFAULT_IMAGE_PROVENANCE_PATH", provenance), mock.patch.object(
            Path, "resolve", autospec=True,
            side_effect=lambda path: Path("/opt/hermes") if path == self.source else path,
        ):
            info = MODULE.resolve_baseline_revision(self.source)
        self.assertEqual(info["method"], "image_provenance")

    def test_valid_image_works_without_stamp(self) -> None:
        provenance = self.root / "image-provenance.json"
        provenance.write_text(json.dumps({"revision": REVISION.upper()}), encoding="utf-8")
        info = MODULE.resolve_baseline_revision(self.source, image_provenance_path=provenance)
        self.assertEqual(info["revision"], REVISION)
        self.assertEqual(info["method"], "image_provenance")

    def test_null_image_revision_falls_back_to_valid_stamp(self) -> None:
        self.write_stamp(commit=REVISION.upper())
        provenance = self.root / "image-provenance.json"
        provenance.write_text(json.dumps({"revision": None}), encoding="utf-8")
        info = MODULE.resolve_baseline_revision(self.source, image_provenance_path=provenance)
        self.assertEqual(info["revision"], REVISION)
        self.assertEqual(info["method"], "install_stamp")

    def test_unknown_image_revision_without_stamp_cannot_resolve_legacy_tag(self) -> None:
        provenance = self.root / "image-provenance.json"
        for revision in [None, "0" * 40, ""]:
            with self.subTest(revision=revision):
                provenance.write_text(json.dumps({"revision": revision}), encoding="utf-8")
                with self.assertRaisesRegex(RuntimeError, "unknown baseline metadata"):
                    MODULE.resolve_baseline_revision(self.source, image_provenance_path=provenance)

    def test_bad_image_metadata_is_not_hidden_by_valid_stamp(self) -> None:
        self.write_stamp()
        provenance = self.root / "image-provenance.json"
        for content in ['{"revision": "bad"}', "[]", "{bad"]:
            with self.subTest(content=content):
                provenance.write_text(content, encoding="utf-8")
                with self.assertRaisesRegex(RuntimeError, "baseline metadata"):
                    MODULE.resolve_baseline_revision(self.source, image_provenance_path=provenance)

    def test_explicit_missing_marker_is_not_silently_ignored(self) -> None:
        self.write_stamp()
        with self.assertRaisesRegex(RuntimeError, "missing baseline metadata"):
            MODULE.resolve_baseline_revision(self.source, image_provenance_path=self.root / "missing.json")

    def test_metadata_io_failure_is_actionable(self) -> None:
        with (
            mock.patch.object(Path, "read_text", side_effect=PermissionError("fixture permission denial")),
            self.assertRaisesRegex(RuntimeError, "cannot read baseline metadata"),
        ):
            MODULE.resolve_baseline_revision(self.source)

    def test_explicit_verified_revision_overrides_conflicting_or_corrupt_metadata(self) -> None:
        self.write_stamp(commit="different")
        for name in ENV_NAMES:
            with self.subTest(name=name), mock.patch.dict(os.environ, {name: REVISION.upper()}):
                info = MODULE.resolve_baseline_revision(self.source)
                self.assertEqual(info["revision"], REVISION)
                self.assertEqual(info["method"], f"env:{name}")

    def test_simultaneous_env_aliases_keep_existing_precedence(self) -> None:
        aliases = dict(zip(ENV_NAMES, ("1" * 40, "2" * 40, "3" * 40, "4" * 40)))
        for name in ENV_NAMES:
            with self.subTest(first_nonempty_alias=name), mock.patch.dict(os.environ, aliases):
                info = MODULE.resolve_baseline_revision(self.source)
                self.assertEqual(info["revision"], aliases[name])
                self.assertEqual(info["method"], f"env:{name}")
            aliases[name] = ""

    def test_legacy_build_marker_and_stamp_are_cross_checked(self) -> None:
        self.write_stamp()
        marker = self.source / ".hermes_build_sha"
        marker.write_text("1" * 40, encoding="utf-8")
        with self.assertRaisesRegex(RuntimeError, "conflict"):
            MODULE.resolve_baseline_revision(self.source)
        marker.write_text(REVISION.upper(), encoding="utf-8")
        info = MODULE.resolve_baseline_revision(self.source)
        self.assertEqual(info["revision"], REVISION)
        self.assertEqual(info["method"], "baked_build_sha")

    def test_unknown_legacy_marker_never_uses_release_date_fallback(self) -> None:
        for content in ["0" * 40, ""]:
            with self.subTest(content=content):
                (self.source / ".hermes_build_sha").write_text(content, encoding="utf-8")
                with (
                    mock.patch.object(MODULE, "run", side_effect=AssertionError("Git fallback forbidden")),
                    self.assertRaisesRegex(RuntimeError, "unknown baseline metadata"),
                ):
                    MODULE.resolve_baseline_revision(self.source)

    def test_unknown_legacy_marker_never_uses_local_git_fallback(self) -> None:
        (self.source / "hermes_cli" / "__init__.py").write_text("", encoding="utf-8")
        (self.source / ".git").mkdir()  # Presence only; no real Git invocation.
        for content in ["0" * 40, ""]:
            with self.subTest(content=content):
                (self.source / ".hermes_build_sha").write_text(content, encoding="utf-8")
                with (
                    mock.patch.object(MODULE, "run", side_effect=AssertionError("Git fallback forbidden")),
                    self.assertRaisesRegex(RuntimeError, "unknown baseline metadata"),
                ):
                    MODULE.resolve_baseline_revision(self.source)

    def test_unknown_legacy_marker_accepts_valid_metadata(self) -> None:
        provenance = self.root / "image-provenance.json"
        for content in ["0" * 40, ""]:
            for origin in ["stamp", "image", "both"]:
                with self.subTest(content=content, origin=origin):
                    (self.source / ".hermes_build_sha").write_text(content, encoding="utf-8")
                    (self.source / "install-stamp.json").unlink(missing_ok=True)
                    provenance.unlink(missing_ok=True)
                    if origin in {"stamp", "both"}:
                        self.write_stamp()
                    if origin in {"image", "both"}:
                        provenance.write_text(json.dumps({"revision": REVISION.upper()}), encoding="utf-8")
                    with mock.patch.object(MODULE, "run", side_effect=AssertionError("Git fallback forbidden")):
                        info = MODULE.resolve_baseline_revision(
                            self.source, image_provenance_path=provenance if origin != "stamp" else None,
                        )
                    self.assertEqual(info["revision"], REVISION)
                    self.assertEqual(info["method"], "install_stamp" if origin == "stamp" else "image_provenance")

    def test_nonzero_legacy_marker_works_without_json_metadata(self) -> None:
        (self.source / ".hermes_build_sha").write_text(REVISION.upper() + "\n", encoding="utf-8")
        with mock.patch.object(MODULE, "run", side_effect=AssertionError("Git fallback forbidden")):
            info = MODULE.resolve_baseline_revision(self.source)
        self.assertEqual(info["revision"], REVISION)
        self.assertEqual(info["method"], "baked_build_sha")

    def test_legacy_local_git_fallback_is_retained_without_markers(self) -> None:
        (self.source / "hermes_cli" / "__init__.py").write_text("", encoding="utf-8")
        (self.source / ".git").mkdir()
        result = subprocess.CompletedProcess(["git", "rev-parse", "HEAD"], 0, stdout=REVISION + "\n")
        with mock.patch.object(MODULE, "run", return_value=result) as git:
            info = MODULE.resolve_baseline_revision(self.source)
        git.assert_called_once_with(["git", "rev-parse", "HEAD"], cwd=self.source)
        self.assertEqual(info["revision"], REVISION)
        self.assertEqual(info["method"], "local_git_head")

    def test_legacy_release_date_fallback_is_retained_without_new_metadata(self) -> None:
        expected = {"revision": REVISION, "method": "docker_registry_tag_label"}
        with mock.patch.object(MODULE, "revision_from_docker_tag", return_value=expected.copy()) as lookup:
            info = MODULE.resolve_baseline_revision(self.source)
        lookup.assert_called_once_with("v2026.9.24", arch=os.uname().machine)
        self.assertEqual(info["revision"], REVISION)

    def test_real_generator_uses_local_repo_and_patch_applies(self) -> None:
        # A real, local Git repository, not a synthesized git response. main()
        # may clone/fetch/create worktrees only below this temporary root.
        upstream = self.root / "upstream"
        upstream.mkdir()
        def git(*args: str, cwd: Path = upstream) -> str:
            return subprocess.run(["git", *args], cwd=cwd, check=True, text=True, capture_output=True).stdout.strip()
        git("init", "-q")
        git("config", "user.name", "Fixture")
        git("config", "user.email", "fixture@example.invalid")
        (upstream / "source.py").write_text("value = 1\n", encoding="utf-8")
        shutil.copytree(self.source / "hermes_cli", upstream / "hermes_cli")
        git("add", ".")
        git("commit", "-qm", "fixture baseline")
        revision = git("rev-parse", "HEAD")
        (self.source / "source.py").write_text("value = 1\n", encoding="utf-8")
        self.write_stamp(commit=revision)
        repo = self.root / "clones" / "hermes-agent"
        output = self.root / "patch-output"
        status_path = self.root / "status.json"
        argv = ["--source-dir", str(self.source), "--repo-dir", str(repo),
                "--repo-url", str(upstream), "--output-dir", str(output),
                "--status-file", str(status_path), "--quiet"]
        with mock.patch.object(MODULE.urllib.request, "urlopen", side_effect=AssertionError("network forbidden")):
            self.assertEqual(MODULE.main(argv), 0)
            status = json.loads(status_path.read_text(encoding="utf-8"))
            self.assertEqual(status["baseline_revision"], revision)
            self.assertEqual([status[k] for k in ("added", "modified", "deleted")], [0, 0, 0])
            self.assertEqual(status["status"], "no changes")
            manifest = Path(status["manifest_path"]).read_text(encoding="utf-8")
            self.assertIn("baseline_method: install_stamp", manifest)
            (self.source / "source.py").write_text("value = 2\n", encoding="utf-8")
            self.assertEqual(MODULE.main(argv), 0)
        status = json.loads(status_path.read_text(encoding="utf-8"))
        self.assertEqual([status[k] for k in ("added", "modified", "deleted")], [0, 1, 0])
        patch = Path(status["patch_path"])
        self.assertNotIn("install-stamp", patch.read_text(encoding="utf-8"))
        baseline = repo.parent / f"hermes-agent-base-{revision[:12]}"
        git("apply", "--check", str(patch), cwd=baseline)
        git("apply", str(patch), cwd=baseline)
        self.assertEqual((baseline / "source.py").read_text(encoding="utf-8"), "value = 2\n")


if __name__ == "__main__":
    unittest.main()
