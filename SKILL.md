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
6. Prompts for a cron schedule, defaulting to `5 2 * * *` (02:05 UTC), then creates a Hermes cron no-agent job when the `hermes` CLI is available.

### Backup

`backup.sh`:

1. Copies `/opt/data` to `/opt/data/git/agent-state-backup`.
2. Excludes the backup repo itself and known credential-only files/directories:
   - `auth.json`
   - `google_client_secret.json`
   - `google_token.json`
   - `keys/`
   - `/opt/data/git/`, which contains all local git repositories including the private backup repo and public skill checkouts
3. Removes additional standalone credential files by filename/content heuristics.
4. Redacts `TELEGRAM_BOT_TOKEN`, `GITHUB_TOKEN`, and `GH_TOKEN` from `.env`, and also redacts common token/key/secret/password environment variables.
5. Runs `gitleaks`, installing it locally if missing.
6. On first push from this skill checkout, runs `trufflehog`, installing it locally if missing.
7. Automatically redacts scanner-detected secrets when safe to do so.
8. Stops and reports an error if a scanner finding cannot be safely redacted without likely corrupting data.
9. Writes non-secret audit details to `excluded.txt` and persistent exclude patterns to `excludes.txt` in the backup repository.
10. Commits as `backup YYYY-MM-DD HH:MM UTC` and pushes.

### Restore

`restore.sh`:

1. Ensures the skill is available and has local config.
2. Ensures `/opt/data/git/agent-state-backup` exists and is linked to the configured private repo.
3. Shows available backup commits.
4. If the backup working tree has local changes, prompts to create a new snapshot or discard changes.
5. Checks out the selected commit.
6. Copies files back to `/opt/data` while respecting `excludes.txt` and preserving current secrets in `.env`.
7. Prints manual steps needed to restore secrets that were intentionally excluded.

## Cron Failure Handling

The cron job should run `backup.sh` with `--no-agent`. Empty stdout means success/silent. Any non-empty stdout or non-zero exit is delivered as a notification. If backup needs a human decision or cannot safely redact a secret, the script exits non-zero and writes a local `last_error.log` next to the skill config. When the user later asks about backups, inspect that file and help resolve the issue before re-running `backup.sh`.

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
- [ ] `gitleaks detect --source /opt/data/git/agent-state-backup` returns clean.
- [ ] First run completed `trufflehog filesystem` successfully.
- [ ] `scripts/restore.sh` lists commits and preserves existing `.env` secrets during restore.
