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

1. Copies `/opt/data` to `/opt/data/git/agent-state-backup`.
2. Excludes paths from `excludes.txt` in the skill directory. This file is the persistent source of truth for backup exclusions and currently excludes known credential-only files/directories, local git repositories, and rebuildable dependency/cache directories:
   - `auth.json`
   - `google_client_secret.json`
   - `google_token.json`
   - `keys/`
   - `git/`, which contains all local git repositories including the private backup repo and public skill checkouts
   - `node_modules/`, matching any `node_modules` directory at any depth
   - `.npm/`, npm cache/logs that can be rebuilt
   - `.npmrc`, npm config that may contain auth tokens for private registries
3. Force-includes paths from `includes.txt` in the skill directory. These patterns override `excludes.txt`, backup-time credential-like file removal/redaction, and scanner findings for user-approved false positives. Do not add real credentials here.
4. Removes additional standalone credential files by filename/content heuristics.
5. Redacts `TELEGRAM_BOT_TOKEN`, `GITHUB_TOKEN`, and `GH_TOKEN` from `.env`, and also redacts common token/key/secret/password environment variables.
6. Runs `gitleaks`, installing it locally if missing.
7. On first push from this skill checkout, runs `trufflehog`, installing it locally if missing.
8. Automatically redacts scanner-detected secrets when safe to do so, unless the file is force-included.
9. Stops and reports an error if a scanner finding cannot be safely redacted without likely corrupting data.
10. Writes non-secret audit details to `excluded.txt` in the backup repository. Explicit `excludes.txt` matches are logged as per-pattern summaries with counts and a few sample paths, not exhaustive file lists, to avoid huge logs for patterns like `git/` or `node_modules/`. Redacted assignment entries include the file path and parameter path/key, for example `config.yaml :: gateway.telegram.token` or `.env :: TELEGRAM_BOT_TOKEN`, so restore follow-up is actionable without exposing secret values. If backup-time cleanup discovers new credential-like files that should be skipped in future runs, it appends their relative paths to the skill's `excludes.txt`, not to the backup repository.
11. Commits as `backup YYYY-MM-DD HH:MM UTC` and pushes.

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
7. Copies files back to `/opt/data` while never deleting files that are absent from the backup snapshot.
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

## Verification Checklist

- [ ] `scripts/initialize.sh` created or linked `/opt/data/git/agent-state-backup` to the private repo.
- [ ] `.agent-state-backup.conf` exists locally and is not tracked.
- [ ] `scripts/backup.sh` runs successfully and pushes a commit.
- [ ] `excluded.txt` lists removed/redacted paths without secret values.
- [ ] `excludes.txt` exists in the skill directory, is tracked with the skill, and does not exclude user-requested state directories such as `sessions/`.
- [ ] `gitleaks detect --source /opt/data/git/agent-state-backup` returns clean.
- [ ] First run completed `trufflehog filesystem` successfully.
- [ ] `scripts/restore.sh --dry-run --commit HEAD` lists a restore summary without modifying files.
- [ ] `scripts/restore.sh` lists commits, uses a temporary worktree, preserves current `.env` and redacted config secrets, creates an overwrite safety snapshot, and never deletes files absent from the backup.
