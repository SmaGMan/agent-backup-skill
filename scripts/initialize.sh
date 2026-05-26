#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$SKILL_DIR/.agent-state-backup.conf"
SOURCE_DIR="${SOURCE_DIR:-/opt/data}"
BACKUP_DIR="${BACKUP_DIR:-/opt/data/agent-state-backup}"
DEFAULT_CRON="5 2 * * *"

say() { printf '%s\n' "$*"; }
ask() {
  local prompt="$1" default="${2:-}" answer
  if [ -n "$default" ]; then
    read -r -p "$prompt [$default]: " answer || true
    printf '%s' "${answer:-$default}"
  else
    read -r -p "$prompt: " answer || true
    printf '%s' "$answer"
  fi
}
load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
  fi
  SOURCE_DIR="${SOURCE_DIR:-/opt/data}"
  BACKUP_DIR="${BACKUP_DIR:-/opt/data/agent-state-backup}"
}
save_config() {
  umask 077
  {
    printf 'BACKUP_REPO_URL=%q\n' "${BACKUP_REPO_URL:-}"
    printf 'BACKUP_DIR=%q\n' "$BACKUP_DIR"
    printf 'SOURCE_DIR=%q\n' "$SOURCE_DIR"
    printf 'CRON_SCHEDULE=%q\n' "${CRON_SCHEDULE:-$DEFAULT_CRON}"
    printf 'TRUFFLEHOG_FIRST_PUSH_DONE=%q\n' "${TRUFFLEHOG_FIRST_PUSH_DONE:-false}"
  } > "$CONFIG_FILE"
}
ensure_git_auth_hint() {
  say "Checking GitHub auth..."
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    say "GitHub CLI is authenticated."
    return 0
  fi
  if ssh -T git@github.com >/tmp/agent_state_backup_ssh_check.log 2>&1; then
    say "SSH auth to GitHub works."
    rm -f /tmp/agent_state_backup_ssh_check.log
    return 0
  fi
  rm -f /tmp/agent_state_backup_ssh_check.log
  say "GitHub auth was not verified. Use one of these safe methods before push:"
  say "  1. gh auth login"
  say "  2. add an SSH key to https://github.com/settings/keys"
  say "  3. use a fine-grained PAT in a local terminal, not in chat"
}
ensure_backup_repo() {
  if [ -z "${BACKUP_REPO_URL:-}" ]; then
    BACKUP_REPO_URL="$(ask 'Private backup repository URL')"
  fi
  if [ -z "$BACKUP_REPO_URL" ]; then
    say "ERROR: private backup repository URL is required." >&2
    exit 1
  fi

  if [ ! -e "$BACKUP_DIR" ]; then
    mkdir -p "$(dirname "$BACKUP_DIR")"
    say "Cloning $BACKUP_REPO_URL -> $BACKUP_DIR"
    git clone "$BACKUP_REPO_URL" "$BACKUP_DIR" || {
      say "Clone failed. Creating local repo and linking origin; push may fail until remote exists/auth works."
      mkdir -p "$BACKUP_DIR"
      git -C "$BACKUP_DIR" init
      git -C "$BACKUP_DIR" remote add origin "$BACKUP_REPO_URL"
    }
  elif [ ! -d "$BACKUP_DIR/.git" ]; then
    say "$BACKUP_DIR exists but is not a git repo. Initializing and preserving current files as local changes."
    git -C "$BACKUP_DIR" init
    git -C "$BACKUP_DIR" remote add origin "$BACKUP_REPO_URL"
  else
    local origin
    origin="$(git -C "$BACKUP_DIR" remote get-url origin 2>/dev/null || true)"
    if [ -z "$origin" ]; then
      say "$BACKUP_DIR is a git repo but has no origin. Linking origin."
      git -C "$BACKUP_DIR" remote add origin "$BACKUP_REPO_URL"
    elif [ "$origin" != "$BACKUP_REPO_URL" ]; then
      say "Existing origin: $origin"
      local answer
      answer="$(ask 'Replace origin with configured private repo? yes/no' 'no')"
      if [ "$answer" = "yes" ]; then
        git -C "$BACKUP_DIR" remote set-url origin "$BACKUP_REPO_URL"
      else
        BACKUP_REPO_URL="$origin"
      fi
    fi
  fi
  save_config
}
install_cron() {
  local schedule answer cron_script hermes_bin
  schedule="$(ask 'Backup schedule in cron format' "${CRON_SCHEDULE:-$DEFAULT_CRON}")"
  CRON_SCHEDULE="$schedule"
  save_config

  answer="$(ask 'Create Hermes cron job now? yes/no' 'yes')"
  [ "$answer" = "yes" ] || return 0

  hermes_bin="$(command -v hermes || true)"
  if [ -z "$hermes_bin" ] && [ -x /opt/hermes/hermes ]; then hermes_bin=/opt/hermes/hermes; fi
  if [ -z "$hermes_bin" ]; then
    say "Hermes CLI not found. Create cron manually later:"
    say "  hermes cron create '$schedule' --name 'Agent state backup' --script agent-state-backup.sh --no-agent --deliver origin"
    return 0
  fi

  mkdir -p "${HERMES_HOME:-/opt/data}/scripts"
  cron_script="${HERMES_HOME:-/opt/data}/scripts/agent-state-backup.sh"
  cat > "$cron_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "$SCRIPT_DIR/backup.sh"
EOF
  chmod +x "$cron_script"

  say "Creating Hermes cron job at $schedule"
  "$hermes_bin" cron create "$schedule" --name "Agent state backup" --script "agent-state-backup.sh" --no-agent --deliver origin || {
    say "Cron creation failed. You can create it manually with:"
    say "  $hermes_bin cron create '$schedule' --name 'Agent state backup' --script agent-state-backup.sh --no-agent --deliver origin"
  }
}

main() {
  load_config
  ensure_git_auth_hint
  ensure_backup_repo
  install_cron
  say "Initialized. Run: $SCRIPT_DIR/backup.sh"
}
main "$@"
