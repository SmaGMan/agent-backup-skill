from __future__ import annotations

import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "generate-hermes-patch.py"
SPEC = importlib.util.spec_from_file_location("generate_hermes_patch", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ExclusionTests(unittest.TestCase):
    def test_docker_context_omissions_are_excluded(self) -> None:
        excluded = [
            "tests/test_gateway.py",
            "website/docs/intro.md",
            "apps/desktop/main.ts",
            "nix/module.nix",
            ".env.example",
            "flake.lock",
            ".hermes_build_sha",
            ".install_method",
            "bin/hermes",
        ]
        for path in excluded:
            with self.subTest(path=path):
                self.assertTrue(MODULE.is_excluded(path))

    def test_runtime_workspace_and_source_are_kept(self) -> None:
        kept = [
            "apps/shared/src/index.ts",
            "agent/agent_init.py",
            "gateway/run.py",
            "tools/send_message_tool.py",
        ]
        for path in kept:
            with self.subTest(path=path):
                self.assertFalse(MODULE.is_excluded(path))


class BaselineResolutionTests(unittest.TestCase):
    def test_baked_build_sha_wins_without_registry_lookup(self) -> None:
        revision = "9de9c25f620ff7f1ce0fd5457d596052d5159596"
        with tempfile.TemporaryDirectory() as td:
            source = Path(td)
            (source / ".hermes_build_sha").write_text(revision + "\n", encoding="utf-8")
            init = source / "hermes_cli" / "__init__.py"
            init.parent.mkdir()
            init.write_text(
                '__version__ = "0.18.2"\n__release_date__ = "2026.7.7.2"\n',
                encoding="utf-8",
            )
            env = {
                name: ""
                for name in (
                    "HERMES_IMAGE_REVISION",
                    "HERMES_DOCKER_IMAGE_REVISION",
                    "OCI_IMAGE_REVISION",
                    "HERMES_BASE_REVISION",
                )
            }
            with mock.patch.dict(os.environ, env):
                with mock.patch.object(
                    MODULE,
                    "revision_from_docker_tag",
                    side_effect=AssertionError("registry lookup must not run"),
                ):
                    info = MODULE.resolve_baseline_revision(source)

        self.assertEqual(info["revision"], revision)
        self.assertEqual(info["method"], "baked_build_sha")
        self.assertEqual(info["local_version"], "0.18.2")
        self.assertEqual(info["local_release_date"], "2026.7.7.2")


class WorktreeTests(unittest.TestCase):
    def test_stale_target_directory_is_replaced_with_current_revision(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            repo = root / "hermes-agent"
            repo.mkdir()
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.email", "test@example.invalid"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "Test"], cwd=repo, check=True)
            (repo / "source.py").write_text("value = 1\n", encoding="utf-8")
            subprocess.run(["git", "add", "source.py"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-q", "-m", "baseline"], cwd=repo, check=True)
            revision = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=repo,
                check=True,
                text=True,
                stdout=subprocess.PIPE,
            ).stdout.strip()

            target = root / f"hermes-agent-base-{revision[:12]}"
            target.mkdir()
            (target / "stale.txt").write_text("stale\n", encoding="utf-8")

            worktree = MODULE.ensure_worktree(repo, revision)

            self.assertEqual(worktree, target)
            self.assertTrue((worktree / ".git").exists())
            self.assertFalse((worktree / "stale.txt").exists())
            actual = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=worktree,
                check=True,
                text=True,
                stdout=subprocess.PIPE,
            ).stdout.strip()
            self.assertEqual(actual, revision)

    def test_obsolete_baseline_worktree_is_removed(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            repo = root / "hermes-agent"
            repo.mkdir()
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.email", "test@example.invalid"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "Test"], cwd=repo, check=True)

            (repo / "source.py").write_text("value = 1\n", encoding="utf-8")
            subprocess.run(["git", "add", "source.py"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-q", "-m", "old baseline"], cwd=repo, check=True)
            old_revision = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=repo,
                check=True,
                text=True,
                stdout=subprocess.PIPE,
            ).stdout.strip()
            old_worktree = root / f"hermes-agent-base-{old_revision[:12]}"
            subprocess.run(
                ["git", "worktree", "add", "--detach", str(old_worktree), old_revision],
                cwd=repo,
                check=True,
                stdout=subprocess.PIPE,
            )

            (repo / "source.py").write_text("value = 2\n", encoding="utf-8")
            subprocess.run(["git", "add", "source.py"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-q", "-m", "current baseline"], cwd=repo, check=True)
            current_revision = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=repo,
                check=True,
                text=True,
                stdout=subprocess.PIPE,
            ).stdout.strip()

            current_worktree = MODULE.ensure_worktree(repo, current_revision)

            self.assertFalse(old_worktree.exists())
            self.assertEqual(
                current_worktree,
                root / f"hermes-agent-base-{current_revision[:12]}",
            )
            self.assertTrue((current_worktree / ".git").exists())


if __name__ == "__main__":
    unittest.main()
