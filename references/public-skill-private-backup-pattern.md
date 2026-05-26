# Public skill repository + private backup repository pattern

Use this reference when turning a Hermes state-backup workflow into a reusable public skill while keeping actual user state private.

## Repository split

- Public repository: contains the reusable skill and deterministic scripts only.
  - Safe to publish: `SKILL.md`, `README.md`, `scripts/initialize.sh`, `scripts/backup.sh`, `scripts/restore.sh`, `templates/config.example`, `.gitignore`, `LICENSE`.
  - Never publish: private backup repo URL, scanner downloads, logs, local config, tokens.
- Private repository: contains sanitized snapshots of the Hermes state directory, normally `/opt/data`.
  - Default local checkout: `/opt/data/git/agent-state-backup`.
  - Must be excluded from its own backup copy step.

## Local install pattern

A useful session pattern is to maintain both:

1. a public git checkout for publishing the skill, e.g. `/opt/data/git/hermes-agent-backup-skill`;
2. an installed local skill symlink, e.g. `/opt/data/skills/devops/agent-state-backup -> /opt/data/git/hermes-agent-backup-skill`.

The public checkout is the source for GitHub publishing; the installed symlink is what future Hermes sessions can load immediately without duplicating files. Keep `/opt/data/git/` out of the private backup snapshot.

## Safe initialization sequence

1. Validate all shell scripts with `bash -n` before any GitHub or backup side effect.
2. Initialize and commit the public skill repo locally first.
3. Do not run `initialize.sh` or `backup.sh` until the user provides/approves the private backup repo URL.
4. Prefer GitHub device-flow or SSH auth outside chat for credentials.
5. After repo URLs are known:
   - push the public skill repo;
   - run `initialize.sh` for the private backup repo;
   - run one manual backup and verify scanner output before relying on cron.

## Secret-safety expectations

- `.agent-state-backup.conf` stores the private repo URL locally and must be ignored.
- The public skill repo should include a simple secret sweep before publishing.
- The private backup script should copy broadly, then explicitly exclude/redact, then scan before commit/push.
- First push deserves the strictest gate: run both `gitleaks` and `trufflehog` before allowing the initial history to leave the machine.

## User-facing handoff

When stopping before GitHub push because auth or repo URLs are missing, give the user exactly the missing inputs:

- private backup repository URL;
- public skill repository URL;
- whether they want help with GitHub auth, repo creation, push, and initialization.

Avoid implying that the backup is already active until `initialize.sh`, one manual `backup.sh`, and cron creation have actually completed.