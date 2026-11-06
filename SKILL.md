---
name: agent-state-backup
description: Use when backing up or restoring a Hermes Agent state directory to a private GitHub repository while publishing the backup procedure as a reusable public skill.
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [hermes, backup, restore, github, secrets, cron]
    related_skills: [hermes-agent, github-auth, github-repo-management]
---

# Agent State Backup

## Overview

This skill maintains a Git-backed backup of a Hermes Agent state directory, normally `/opt/data`, in a private GitHub repository. It intentionally uses a broad backup strategy: copy nearly everything, then remove or redact known secrets and scanner-detected secrets before committing.

The skill itself is designed to live in a separate public repository. Runtime configuration, GitHub credentials, scanner binaries, and backup repository URLs are stored locally and are ignored by git.

## When to Use

Use this skill when the user wants to:

- initialize a private repository for Hermes Agent state backups;
- run a backup immediately or on a cron schedule;
- restore a Hermes Agent state from a previous backup commit;
- publish or reuse the backup workflow as a portable skill.

Do not use it as a replacement for a full encrypted disk snapshot. This workflow deliberately avoids backing up live credentials and requires manual re-entry of secrets after restore.

## Repository Layout

For the public-skill/private-backup split and safe handoff sequence, see `references/public-skill-private-backup-pattern.md`.

Expected public skill repository layout:

```text
agent-state-backup/
├── SKILL.md
├── README.md
├── scripts/
│   ├── initialize.sh
│   ├── backup.sh
│   ├── generate-hermes-patch.py
│   └── restore.sh
└── templates/
    └── config.example
```

Persistent include/exclude patterns live in the skill repository, not in the backup repository:

- `excludes.txt` — tracked skill file with user-approved persistent exclude patterns;
- `includes.txt` — tracked skill file with user-approved force-include patterns for false positives that must stay in the backup even if their names or scanner output look secret-like;
- `excluded.txt` — generated audit log inside the backup repository with files removed/redacted during backup.

Runtime files ignored by `.gitignore`:

- `.agent-state-backup.conf` — local config with private backup repo URL;
- `bin/` — downloaded scanner binaries;
- `*.log`, `*.tmp`.

## Main Commands

```bash
# Initialize backup working tree and create a Hermes cron job
./scripts/initialize.sh

# Run backup now
./scripts/backup.sh

# Restore from a previous backup commit
./scripts/restore.sh
```

## Behavior

### Initialization

`initialize.sh`:

1. Checks `/opt/data/git/agent-state-backup`.
2. If missing, prompts for the private backup repo URL and clones it there.
3. If present but not a git repo, initializes git and links it to the private repo.
4. If present but missing `origin`, prompts for the repo URL and adds it.
5. Saves the private repo URL to local `.agent-state-backup.conf` in the skill repo; this file must never be committed.
6. Prompts for a cron schedule, defaulting to `5 0 * * *` (00:05 UTC), then creates a Hermes cron no-agent job when the `hermes` CLI is available.

### Backup

`backup.sh`:

1. Runs `scripts/generate-hermes-patch.py` before mirroring state. The generator is script-only (no LLM): an explicit verified SHA in `HERMES_IMAGE_REVISION` (or its existing aliases) takes precedence. Otherwise it reads `/etc/hermes/image-provenance.json.revision` for the canonical `/opt/hermes` install, the legacy `.hermes_build_sha`, and local `install-stamp.json.commit`; available exact commits must agree. Nonzero 40-hex commits are normalized to lowercase. An alternate `--source-dir` uses its own stamp/legacy marker, never the running container's `/etc` identity (the Python resolver accepts an explicitly scoped `image_provenance_path` for isolated probes). Invalid JSON/SHA, conflicting identities, or only unknown/null/zero markers (including an existing empty/all-zero legacy `.hermes_build_sha`) fail closed, rather than resolving a stale release-date tag or falling through to Git HEAD. Legacy fallback requires absence of identity markers, not merely absence of a usable SHA. Docker-tag fallback remains only for legacy installs without new metadata. It checks out a detached baseline worktree named `hermes-agent-base-<revision>` and compares `/opt/hermes` against that revision. Repository paths intentionally omitted from production images by `.dockerignore` (tests, desktop apps, documentation, packaging metadata, and similar build-only trees), plus Docker-generated files such as `.hermes_build_sha`, `.install_method`, root `install-stamp.json`, and `bin/hermes`, are excluded from customization counts. The patch/manifest is written under `/opt/data/hermes-patches/` so it is included in the backup. If the current image baseline changes, the generated filename and baseline worktree change with the commit; obsolete baseline worktrees are removed and stale registrations are pruned, while existing patches for older baselines are not deleted. If there are no local `/opt/hermes` customizations, the generator writes a manifest instead of a diff.
2. Copies `/opt/data` to `/opt/data/git/agent-state-backup`.
3. Excludes paths from `excludes.txt` in the skill directory. This file is the persistent source of truth for backup exclusions and currently excludes known credential-only files/directories, local git repositories, and rebuildable dependency/cache directories:
   - `auth.json`
   - `google_client_secret.json`
   - `google_token.json`
   - `keys/`
   - `git/`, which contains all local git repositories including the private backup repo and public skill checkouts
   - `node_modules/`, matching any `node_modules` directory at any depth
   - `.npm/`, npm cache/logs that can be rebuilt
   - `.npmrc`, npm config that may contain auth tokens for private registries
   - `.cache/` and `home/.cache/`, rebuildable local caches that can contain third-party test fixtures that look like secrets
   - `cache/uv/` — the rebuildable uv package cache under `/opt/data/cache/uv/`; this does not exclude other `cache/` content, installed environments or application state

Cache paths must not be force-included; if a scanner reports findings under cache directories, keep them excluded rather than adding them to `includes.txt`.
4. Force-includes paths from `includes.txt` in the skill directory. These patterns override `excludes.txt`, backup-time credential-like file removal/redaction, and scanner findings for user-approved false positives. Do not add real credentials here.
5. Removes additional standalone credential files by filename/content heuristics.
6. Redacts `TELEGRAM_BOT_TOKEN`, `GITHUB_TOKEN`, and `GH_TOKEN` from `.env`, and also redacts common token/key/secret/password environment variables.
7. Runs `gitleaks`, installing it locally if missing.
8. On first push from this skill checkout, runs `trufflehog`, installing it locally if missing.
9. Automatically redacts scanner-detected secrets when safe to do so, unless the file is force-included.
10. Stops and reports an error if a scanner finding cannot be safely redacted without likely corrupting data.
11. Large regular files above GitHub's single-blob limit safety threshold (default 95 MiB), including `state.db` when it grows too large, are stored as deterministic chunks under `.agent-state-backup-large-files/` with a manifest. Restore reassembles these chunks back to their original paths, so the state is still backed up without Git LFS.
12. Writes non-secret audit details to `excluded.txt` in the backup repository. Explicit `excludes.txt` matches are logged as per-pattern summaries with counts and a few sample paths, not exhaustive file lists, to avoid huge logs for patterns like `git/` or `node_modules/`. Redacted assignment entries include the file path and parameter path/key, for example `config.yaml :: gateway.telegram.token` or `.env :: TELEGRAM_BOT_TOKEN`, so restore follow-up is actionable without exposing secret values. If backup-time cleanup discovers new credential-like files that should be skipped in future runs, it appends their relative paths to the skill's `excludes.txt`, not to the backup repository.
13. Commits as `backup YYYY-MM-DD HH:MM UTC` and pushes.

To add something that was mistakenly backed up or should be skipped going forward, run:

```bash
./scripts/backup.sh --add-exclude relative/path/or-pattern
```

To force-include a user-approved false positive that would otherwise be excluded or stripped as secret-like, run:

```bash
./scripts/backup.sh --add-include relative/path/or-pattern
```

Then remove the path from `excludes.txt` if it was previously excluded. Force-includes are intentionally narrow and should not be used for real live credentials.

Then remove the already-backed-up path from the backup repository in a corrective commit or amend, depending on whether the last backup commit is being fixed.

### Restore

`restore.sh`:

1. Ensures the skill is available and has local config.
2. Ensures `/opt/data/git/agent-state-backup` exists and is linked to the configured private repo.
3. Supports safe options: `--dry-run`, `--commit REF`, `--source-dir DIR`, `--backup-dir DIR`, and `--yes`.
4. Fetches backup refs using the GitHub token from the environment or `SOURCE_DIR/.env` when available; if fetch fails, it warns and uses the local backup repo state.
5. If the backup working tree has local changes, prompts to create a new snapshot or discard changes.
6. Uses a temporary detached git worktree for the selected commit instead of detaching/modifying the main backup working tree.
7. Copies files back to `/opt/data` while never deleting files that are absent from the backup snapshot. Large-file chunk manifests under `.agent-state-backup-large-files/` are reassembled back to their original paths before copying, so chunked `state.db` restores as `state.db`.
8. Before overwriting live files, saves originals under `SOURCE_DIR/restore-safety-snapshots/<timestamp>/`.
9. Preserves current secret values when backup files contain `REDACTED_BY_AGENT_STATE_BACKUP` placeholders. `.env` is merged rather than replaced, preserving current secret keys and appending secret keys that are absent from the backup.
10. Prints `Secret restore details` with paths only, never values:
    - `restored/preserved secret values` lists each restored path such as `.env :: GITHUB_TOKEN` or `config.yaml :: mcp_servers.trello.env.TRELLO_TOKEN`;
    - `secrets requiring manual action` lists runtime secret/config paths that still need a real value;
    - `redacted placeholders restored in non-runtime files` summarizes docs/sessions/history placeholders that were restored as `REDACTED_BY_AGENT_STATE_BACKUP` and normally need no action.
11. If manual runtime secrets remain, prints explicit manual steps: open each listed path in `SOURCE_DIR`, re-enter the real value from the provider/password manager, and use the safety snapshot if needed.
12. Restore does not use today's skill-local `excludes.txt` as a snapshot manifest; older backup commits may contain an obsolete `excludes.txt` file in the backup repository, and restore skips that control file.
13. Reads `excluded.txt` from the selected backup commit and prints snapshot-specific redaction audit details for files that were removed/redacted during that backup.

## Cron Report Format and Failure Handling

The cron job should run `backup.sh` as a no-agent script. The script prints a concise report only; it must not list copied file paths. The report should stay under 30 lines and include:

- status;
- commit message, or `no changes` / `not created`;
- counts of added, modified, and deleted files;
- whether the `/opt/hermes` customization patch was generated, including the patch filename and compact `+added/~modified/-deleted` patch counts; when there are no local customizations, report the actual `.manifest.txt` filename instead of the compatibility `.patch` pointer;
- whether new scanner findings were detected;
- whether errors occurred.

If backup needs a human decision or cannot safely redact a secret, the script exits non-zero and writes a local `last_error.log` next to the skill config. When the user later asks about backups, inspect that file and help resolve the issue before re-running `backup.sh`.

## Security Model

This workflow reduces the chance of accidentally pushing secrets, but does not guarantee zero risk. It uses three layers:

1. Explicit excludes for known credential files/directories.
2. Heuristic redaction/removal for common token/key/secret files and assignment formats.
3. Secret scanners (`gitleaks`, plus `trufflehog` on first push).

Important: scanner reports are temporary local files, deleted after use, and secret values are never printed.

## Common Pitfalls

1. **Backing up repositories into the backup repo.** Always exclude `/opt/data/git/`.
2. **Assuming `.gitignore` is enough.** It is not. The script copies then removes/redacts and scans before commit.
3. **Publishing local config.** Never commit `.agent-state-backup.conf` or `bin/` from the skill repo.
4. **Restoring secrets from backup.** Secrets are intentionally excluded or redacted; re-enter them manually after restore.
5. **Cron creating duplicate jobs.** `initialize.sh` prints existing matching cron jobs where possible; remove duplicates with `hermes cron list/remove`.
6. **Scanner unavailable.** The scripts try to install local binaries, but if network access is unavailable they stop rather than push unscanned data.
7. **Transient `dubious ownership` errors on mounted state volumes.** Verify the affected repository is the expected Hermes-owned checkout, then add only its exact path to Git's global safe-directory list (for example, `git config --global --add safe.directory /opt/data/git/hermes-agent` and the exact private backup working-tree path). Never use `safe.directory '*'`. Retry the failed fetch/backup and verify the pushed remote ref matches local `HEAD`.
8. **Upstream fetch fails on conflicting remote-tracking refs.** A deleted remote branch such as `onboarding` can block a newly created `onboarding/next` because the local `refs/remotes/origin/onboarding` occupies the namespace. Confirm with `git ls-remote --heads origin onboarding onboarding/next` that the old branch is absent; delete *only* the stale remote-tracking ref using `git update-ref -d refs/remotes/origin/onboarding <old-sha>`, then fetch again. Never delete a local branch or user files.
9. **Large push exceeds command timeout after commit.** A timed-out `backup.sh` can leave a clean local working tree with `HEAD` ahead of `origin/master` and a stale `last_error.log`. Its no-changes path does not push an already-created commit. Verify the scanners completed before commit, push the existing commit without force using the configured GitHub authentication and a long-running tracked process, and compare `git ls-remote origin refs/heads/master` against local `HEAD`. Clear only the exact stale error log after confirming remote equality. `gitleaks detect --no-git` may report user-approved false positives in `includes.txt`; map chunk paths through `.agent-state-backup-large-files/manifest.json` before classifying any finding.

10. **Duplicate scanner findings can look like failed redaction.** If a report repeats the same `(file, Secret)`, the first finding may replace every occurrence and later duplicates wrongly fail because the value is gone. Read the script-only cron output for the unresolved path, then inspect scanner metadata without printing values. Skip exact duplicates only after successful redaction of that file/value; binary/unresolved findings must still block, and final rescanning remains mandatory. Regression tests: `python3 -m unittest discover -s tests -v`, including `test_duplicate_redaction.py`. Do not exclude durable state or add includes to bypass this bug.

11. **Overlapping scanner values and sentinel false positives.** Exact-duplicate handling alone is insufficient when one reported secret contains another. Process longer values first; accept a now-absent shorter value only when a successfully redacted value from the same file contained it and no literal/serialized occurrence remains. Gitleaks `curl-auth-header` may flag the exact public `REDACTED_BY_AGENT_STATE_BACKUP` sentinel; ignore only exact sentinel equality, never values containing it or whole rules/paths. Keep final rescanning mandatory and binary findings blocking. Regression coverage in `tests/test_duplicate_redaction.py` includes both overlap orders, containment-only values, and sentinel-plus-suffix rejection. Reproduce against an isolated copy of the unresolved file before another full backup; scanner reports must stay temporary and values must not be printed.

12. **Root-owned generated install lock in customization comparison.** Exclude only the exact `tools/.install.lock` path from patch generation: it is an advisory runtime mutex, may be root-owned mode 0600, and is not a source customization. Do not delete it, change its permissions, or skip arbitrary unreadable source files. Cover the narrow exclusion and source-file retention with `tests/test_generate_hermes_patch.py`. If generation then fails on managed Python terminfo symlinks, treat it as a separate generator defect; a corrected lock exclusion alone does not establish backup success. Respect a one-attempt recovery policy rather than starting repeated full backups.

13. **User-approved whole root-tree exclusions.** Exclude `/opt/hermes/tools/` and `/opt/hermes/uv-cache/` completely from customization comparison, including both baseline and current files, and prune before traversal/copy. This replaces the earlier Python-only exclusion and also omits source modifications inside the root `tools/` tree. Match only the first relative path component; keep `agent/tools/`, similarly named paths, `/opt/data/tools/`, and `/opt/data` backup rules unchanged. Document the exclusion in the generated manifest and test root pruning, nested-path retention, and real generation. An exclusion change is not a completed backup: report patch-generation results separately from scanner/commit/push results.

14. **Case-distinct filenames collide on macOS-backed scratch storage.** Reproduce patch-generation `Errno 17` with symlinks named `2621A` and `2621a` in a self-owned `TemporaryDirectory` under the configured scratch path. Managed Python terminfo contains both names on the container filesystem, but a case-insensitive bind mount cannot materialize both. Do not overwrite/unlink the first name, deduplicate case-insensitively, change the installed runtime, or rerun an unchanged full backup. A durable generator fix must preserve both paths (for example, Git object/index-based diff generation with case-collision and patch-apply regression tests), or dependency-only comparison exclusions need explicit approval. Do not silently broaden backup exclusions or move temporary files outside configured scratch storage. Verify remote HEAD with existing authentication without printing credentials, and retain the error log until a real backup succeeds.

## Read-only storage audits

Separate the mirrored working tree, `.agent-state-backup-large-files/` (required restore data, not disposable cache), and `.git/` (history). Use `du -x -B1 --max-depth=2`, `git count-objects -vH`, and, for history attribution, process `git rev-list --objects --all` with `git cat-file --batch-check='%(objectname) %(objecttype) %(objectsize) %(objectsize:disk)'`. Aggregate blob disk bytes by path without printing contents; attribution is approximate for identical objects stored under multiple names. Current `state.db` size is not the cumulative size of its historical chunks.

Cleanup estimates must account for hardlinks using `(st_dev, st_ino)` and `st_nlink`: reclaim bytes only when all links are inside the proposed cleanup set. Independent `du` calls can double-count shared cache/environment files. The mirror uses `shutil.copy2` without preserving hardlinks, so backup copies may be larger than source directory totals. Check live config, interpreter symlinks and process paths before calling something unused; do not dump credential-bearing command lines or environments.

Before deleting audit/test sandboxes, resolve local Markdown links from retained reports as well as evidence manifests. A directory named `sandbox` may contain unique result artifacts such as `delta.json`, `schema-diff.json`, or `migration.result.json`; retain those files at their linked paths or archive them with an explicit link migration. Preserve hashes of retained reports/results and check every local report link after cleanup. If an artifact must be recovered from the local backup mirror, copy only the exact required files, verify their hashes and redaction sentinels, and leave the backup checkout unchanged.

For approved uv cache cleanup, use `uv cache prune --cache-dir <exact-path>` without `--force`. On mounted filesystems, `Directory not empty (os error 39)` can leave partial progress; bounded retries are reasonable only while the failing path or contents demonstrably advance. Require a final zero exit; never label a partial prune successful or replace it with recursive manual cache deletion. Report allocated-space reduction separately from uv's logical removed-file sizes.

Excluding `.cache/` does not automatically exclude `cache/uv/`; keep the explicitly approved `cache/uv/` pattern in `excludes.txt`. This omits that cache from future snapshots without deleting the live cache or rewriting backup history. Literal `uv-cache` directories elsewhere, compatibility-test virtualenvs and generated audio under `tmp/` remain separate decisions. Inspect actual excludes. Cleanup/exclusion changes require user approval. Removing originals/current mirror copies does not erase Git history; `git gc` does not discard reachable versions. Never delete chunks, rewrite history or replace a clone during an audit. Any separately approved shallow-clone strategy must verify remote availability/sync and explain that older local restore points would require fetching remote history.

## Verification Checklist

For baseline resolver changes, run `python3 -B -m unittest discover -s tests -v` with an isolated HOME/TMPDIR and no revision/credential environment overrides. `tests/test_baseline_provenance.py` covers new/legacy metadata, invalid and conflicting identities, source-directory scoping, and real patch generation/apply against a temporary local Git repository. This test does not run the working backup, its scanners, or restore; a passing suite is not a production Docker smoke.

- [ ] `scripts/initialize.sh` created or linked `/opt/data/git/agent-state-backup` to the private repo.
- [ ] `.agent-state-backup.conf` exists locally and is not tracked.
- [ ] `scripts/backup.sh` runs successfully and pushes a commit.
- [ ] `excluded.txt` lists removed/redacted paths without secret values.
- [ ] `excludes.txt` exists in the skill directory, is tracked with the skill, and does not exclude user-requested state directories such as `sessions/`.
- [ ] `gitleaks detect --source /opt/data/git/agent-state-backup` returns clean.
- [ ] First run completed `trufflehog filesystem` successfully.
- [ ] `scripts/restore.sh --dry-run --commit HEAD` lists a restore summary without modifying files.
- [ ] `scripts/restore.sh` lists commits, uses a temporary worktree, preserves current `.env` and redacted config secrets, creates an overwrite safety snapshot, and never deletes files absent from the backup.
