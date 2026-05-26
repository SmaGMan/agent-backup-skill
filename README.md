# Agent State Backup Skill

Reusable Hermes Agent skill for backing up `/opt/data` into a private GitHub repository while keeping this skill itself publishable in a public repository.

## What it backs up

By default the backup script copies most of `/opt/data` into `/opt/data/git/agent-state-backup`, then removes/redacts secrets before commit and push.

Known explicit excludes:

- `auth.json`
- `google_client_secret.json`
- `google_token.json`
- `keys/`
- `/opt/data/git/` — all local git repositories, including this public skill repo and the private backup repo
- local runtime files for this skill

The script also removes standalone key/token/secret files and redacts `TELEGRAM_BOT_TOKEN`, `GITHUB_TOKEN`, `GH_TOKEN`, and other common secret variables in text config files.

## Quick start

```bash
cd /path/to/agent-state-backup-skill
./scripts/initialize.sh
./scripts/backup.sh
```

`initialize.sh` will ask for the private backup repo URL if it is not configured yet.

Recommended private repo URL formats:

```text
git@github.com:OWNER/agent-state-backup.git
https://github.com/OWNER/agent-state-backup.git
```

## GitHub auth

Preferred auth methods:

1. `gh auth login` if GitHub CLI is installed.
2. SSH key added to GitHub.
3. Fine-grained PAT scoped only to the private backup repo and public skill repo.

Do not paste tokens into Telegram. Enter them only in a local terminal/device flow.

## Cron

During initialization, the script offers to create a Hermes cron job. Default schedule:

```cron
5 2 * * *
```

That is 02:05 UTC daily.

The job runs in `--no-agent` mode. On success it stays silent. On error it emits a concise message and writes a local `last_error.log`.

## Backup

```bash
./scripts/backup.sh
```

The script:

- mirrors `/opt/data` into `/opt/data/git/agent-state-backup`;
- removes known secrets;
- redacts `.env` and common config assignments;
- runs `gitleaks` every time;
- runs `trufflehog` before the first push from this skill checkout;
- commits as `backup YYYY-MM-DD HH:MM UTC`;
- pushes to `origin`.

Scanner binaries are installed locally to `./bin/` if missing. `./bin/` is ignored by git.

## Restore

```bash
./scripts/restore.sh
```

The restore script shows recent backup commits, asks which one to restore, checks it out, and copies files back to `/opt/data`.

Secrets are preserved from the current machine where possible. For example, if current `/opt/data/.env` has `TELEGRAM_BOT_TOKEN`, restore will not overwrite that value with a redacted or empty value from backup.

After restore, manually re-add intentionally excluded secrets:

- GitHub auth / SSH keys if needed;
- model provider API keys;
- Telegram bot token;
- Google OAuth token/client secret files;
- any files listed in `excluded.txt`.

## Risk note

This workflow intentionally favors broad state recovery over a strict allowlist. There remains a non-zero risk that an unknown secret format could leak. The scripts reduce that risk with explicit excludes, heuristic redaction, `gitleaks`, and `trufflehog`.
