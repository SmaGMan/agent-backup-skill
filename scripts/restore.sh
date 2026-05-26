#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$SKILL_DIR/.agent-state-backup.conf"
SOURCE_DIR="${SOURCE_DIR:-/opt/data}"
BACKUP_DIR="${BACKUP_DIR:-/opt/data/git/agent-state-backup}"

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
  BACKUP_DIR="${BACKUP_DIR:-/opt/data/git/agent-state-backup}"
}
save_config() {
  umask 077
  {
    printf 'BACKUP_REPO_URL=%q\n' "${BACKUP_REPO_URL:-$(git -C "$BACKUP_DIR" remote get-url origin 2>/dev/null || true)}"
    printf 'BACKUP_DIR=%q\n' "$BACKUP_DIR"
    printf 'SOURCE_DIR=%q\n' "$SOURCE_DIR"
    printf 'CRON_SCHEDULE=%q\n' "${CRON_SCHEDULE:-5 2 * * *}"
    printf 'TRUFFLEHOG_FIRST_PUSH_DONE=%q\n' "${TRUFFLEHOG_FIRST_PUSH_DONE:-false}"
  } > "$CONFIG_FILE"
}
ensure_repo() {
  if [ -z "${BACKUP_REPO_URL:-}" ]; then
    BACKUP_REPO_URL="$(ask 'Private backup repository URL')"
  fi
  [ -n "${BACKUP_REPO_URL:-}" ] || { say "ERROR: repo URL required" >&2; exit 1; }
  if [ ! -e "$BACKUP_DIR" ]; then
    mkdir -p "$(dirname "$BACKUP_DIR")"
    git clone "$BACKUP_REPO_URL" "$BACKUP_DIR"
  elif [ ! -d "$BACKUP_DIR/.git" ]; then
    git -C "$BACKUP_DIR" init
    git -C "$BACKUP_DIR" remote add origin "$BACKUP_REPO_URL"
    git -C "$BACKUP_DIR" fetch origin
  elif ! git -C "$BACKUP_DIR" remote get-url origin >/dev/null 2>&1; then
    git -C "$BACKUP_DIR" remote add origin "$BACKUP_REPO_URL"
    git -C "$BACKUP_DIR" fetch origin
  fi
  save_config
}
handle_local_changes() {
  if git -C "$BACKUP_DIR" diff --quiet && git -C "$BACKUP_DIR" diff --cached --quiet; then
    return 0
  fi
  say "Backup repo has local changes."
  local choice
  choice="$(ask 'Choose: snapshot/discard/abort' 'snapshot')"
  case "$choice" in
    snapshot) "$SCRIPT_DIR/backup.sh" ;;
    discard) git -C "$BACKUP_DIR" reset --hard && git -C "$BACKUP_DIR" clean -fd ;;
    *) say "Aborted."; exit 1 ;;
  esac
}
restore_files() {
  local commit="$1"
  python3 - "$SOURCE_DIR" "$BACKUP_DIR" "$commit" <<'PY'
import os, shutil, subprocess, re, sys
from pathlib import Path
source = Path(sys.argv[1]).resolve()
backup = Path(sys.argv[2]).resolve()
commit = sys.argv[3]
subprocess.check_call(['git','-C',str(backup),'checkout','--detach',commit], stdout=subprocess.DEVNULL)
excluded = set()
for name in ['excludes.txt']:
    p = backup / name
    if p.exists():
        for line in p.read_text(errors='ignore').splitlines():
            line=line.strip()
            if line and not line.startswith('#'):
                excluded.add(line.rstrip('/'))
secret_key_re = re.compile(r'(?i)(TOKEN|SECRET|PASSWORD|PRIVATE_KEY|API_KEY|ACCESS_KEY|CLIENT_SECRET)')
placeholder = 'REDACTED_BY_AGENT_STATE_BACKUP'

def should_skip(rel: Path):
    s = str(rel)
    if s in {'.git','excludes.txt','excluded.txt'} or s.startswith('.git/'):
        return True
    for e in excluded:
        if s == e or s.startswith(e.rstrip('/') + '/'):
            return True
    return False

def merge_env(src_env: Path, dst_env: Path):
    backup_lines = src_env.read_text(errors='ignore').splitlines()
    current = {}
    if dst_env.exists():
        for line in dst_env.read_text(errors='ignore').splitlines():
            if '=' in line and not line.lstrip().startswith('#'):
                k,v=line.split('=',1); current[k]=v
    out=[]
    for line in backup_lines:
        if '=' not in line or line.lstrip().startswith('#'):
            out.append(line); continue
        k,v=line.split('=',1)
        if secret_key_re.search(k) and k in current and current[k] and v in {'', placeholder}:
            out.append(f'{k}={current[k]}')
        elif secret_key_re.search(k) and k in current and current[k] and placeholder in v:
            out.append(f'{k}={current[k]}')
        else:
            out.append(line)
    dst_env.parent.mkdir(parents=True, exist_ok=True)
    dst_env.write_text('\n'.join(out)+'\n')

for root, dirs, files in os.walk(backup):
    rootp = Path(root)
    dirs[:] = [d for d in dirs if not should_skip((rootp/d).relative_to(backup))]
    for fn in files:
        sp = rootp / fn
        rel = sp.relative_to(backup)
        if should_skip(rel):
            continue
        dp = source / rel
        if str(dp).startswith(str(backup)):
            continue
        if rel == Path('.env'):
            merge_env(sp, dp)
            continue
        dp.parent.mkdir(parents=True, exist_ok=True)
        if sp.is_symlink():
            target=os.readlink(sp)
            if dp.exists() or dp.is_symlink(): dp.unlink()
            os.symlink(target, dp)
        else:
            shutil.copy2(sp, dp)
PY
}
main() {
  load_config
  ensure_repo
  git -C "$BACKUP_DIR" fetch --all --prune || true
  handle_local_changes
  say "Available backup commits:"
  git -C "$BACKUP_DIR" log --oneline --decorate --date=short --pretty=format:'%h %ad %s' -20 || true
  printf '\n'
  local commit
  commit="$(ask 'Commit hash/ref to restore' 'HEAD')"
  restore_files "$commit"
  say "Restore copied files from $commit."
  say "Manual follow-up: re-add intentionally excluded secrets if needed: GitHub auth, model API keys, Telegram bot token, Google OAuth files, and anything listed in $BACKUP_DIR/excluded.txt."
}
main "$@"
