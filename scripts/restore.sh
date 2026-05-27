#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$SKILL_DIR/.agent-state-backup.conf"
SOURCE_DIR="${SOURCE_DIR:-/opt/data}"
BACKUP_DIR="${BACKUP_DIR:-/opt/data/git/agent-state-backup}"
COMMIT_REF=""
DRY_RUN=false
ASSUME_YES=false
SOURCE_DIR_OVERRIDE=""
BACKUP_DIR_OVERRIDE=""

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
usage() {
  cat <<'EOF'
Usage: restore.sh [--commit REF] [--source-dir DIR] [--backup-dir DIR] [--dry-run] [--yes]

Restores files from the backup repository into SOURCE_DIR.
Safety behavior:
- does not delete files that are absent from the backup snapshot;
- uses a temporary git worktree, so the backup repository branch is not detached/modified;
- before overwriting live files, saves originals under SOURCE_DIR/restore-safety-snapshots/;
- preserves current secret values when backup files contain REDACTED_BY_AGENT_STATE_BACKUP placeholders;
- merges .env instead of replacing it, preserving current secret keys and appending keys absent from the backup.
EOF
}
parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --commit) shift; [ "$#" -gt 0 ] || { usage >&2; exit 2; }; COMMIT_REF="$1" ;;
      --source-dir) shift; [ "$#" -gt 0 ] || { usage >&2; exit 2; }; SOURCE_DIR_OVERRIDE="$1" ;;
      --backup-dir) shift; [ "$#" -gt 0 ] || { usage >&2; exit 2; }; BACKUP_DIR_OVERRIDE="$1" ;;
      --dry-run) DRY_RUN=true ;;
      --yes|-y) ASSUME_YES=true ;;
      --help|-h) usage; exit 0 ;;
      *) say "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done
}
load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
  fi
  SOURCE_DIR="${SOURCE_DIR_OVERRIDE:-${SOURCE_DIR:-/opt/data}}"
  BACKUP_DIR="${BACKUP_DIR_OVERRIDE:-${BACKUP_DIR:-/opt/data/git/agent-state-backup}}"
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
    say "ERROR: $BACKUP_DIR exists but is not a git repository. Refusing to initialize over an existing directory during restore." >&2
    exit 1
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
read_github_token() {
  local token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [ -z "$token" ] && [ -f "$SOURCE_DIR/.env" ]; then
    token="$(python3 - "$SOURCE_DIR/.env" <<'PY'
import sys
for line in open(sys.argv[1], encoding='utf-8', errors='ignore'):
    line = line.strip()
    if not line or line.startswith('#') or '=' not in line:
        continue
    key, value = line.split('=', 1)
    if key.strip() in {'GITHUB_TOKEN', 'GH_TOKEN'}:
        print(value.strip().strip('"').strip("'"))
        break
PY
)"
  fi
  printf '%s' "$token"
}
fetch_updates() {
  local err token cred
  err="$(mktemp)"
  if git -C "$BACKUP_DIR" fetch --all --prune --quiet 2>"$err"; then
    rm -f "$err"
    return 0
  fi
  token="$(read_github_token)"
  if [ -n "$token" ]; then
    cred="$(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')"
    if git -C "$BACKUP_DIR" -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $cred" fetch --all --prune --quiet 2>"$err"; then
      rm -f "$err"
      return 0
    fi
  fi
  say "Warning: could not fetch latest backup refs; using local backup repo state." >&2
  rm -f "$err"
}
restore_files() {
  local commit="$1" worktree
  worktree="$(mktemp -d "${TMPDIR:-/tmp}/agent-state-restore.XXXXXX")"
  git -C "$BACKUP_DIR" worktree add --detach --quiet "$worktree" "$commit"
  set +e
  python3 - "$SOURCE_DIR" "$worktree" "$commit" "$DRY_RUN" <<'PY'
import os, shutil, sys, time, re
from pathlib import Path
source = Path(sys.argv[1]).resolve()
snapshot = Path(sys.argv[2]).resolve()
commit = sys.argv[3]
dry_run = sys.argv[4].lower() == 'true'
placeholder = 'REDACTED_BY_AGENT_STATE_BACKUP'
secret_key_re = re.compile(r'(?i)(TOKEN|SECRET|PASSWORD|PRIVATE_KEY|API_KEY|ACCESS_KEY|CLIENT_SECRET)')
assign_re = re.compile(r'^(\s*["\']?)([A-Za-z0-9_.-]+)(["\']?\s*[:=]\s*)(.*?)(\s*)$')
audit_items = []
audit_secret_paths = []
restored_secret_paths = []
unresolved_secret_paths = []
other_redacted_paths = []
audit = snapshot / 'excluded.txt'

def normalize_audit_file(file: str) -> str:
    file = file.strip()
    try:
        path = Path(file)
        if path.is_absolute():
            return str(path.resolve().relative_to(snapshot))
    except Exception:
        pass
    return file

def canonical_secret_path(rel, param):
    rel_s = str(rel).replace('\\', '/')
    param = str(param).strip()
    for audit_rel, audit_param in audit_secret_paths:
        if audit_rel == rel_s and (audit_param == param or audit_param.endswith('.' + param) or audit_param.endswith(':: ' + param)):
            return f'{audit_rel} :: {audit_param}'
    return f'{rel_s} :: {param}'

def add_unique(seq, item):
    if item not in seq:
        seq.append(item)

def is_runtime_secret_path(item: str) -> bool:
    rel = item.split(' :: ', 1)[0]
    name = Path(rel).name
    if rel in {'.env', 'config.yaml', 'config.yml'}:
        return True
    if rel.startswith(('keys/', 'secrets/', 'credentials/')):
        return True
    if name in {'auth.json', 'google_client_secret.json', 'google_token.json', '.npmrc'}:
        return True
    if re.search(r'(?i)(token|secret|credential|private[_-]?key|api[_-]?key)', name):
        return True
    return False

if audit.exists():
    for line in audit.read_text(errors='ignore').splitlines():
        stripped = line.strip()
        if stripped.startswith('- '):
            item = stripped[2:]
            audit_items.append(item)
            m = re.match(r'(?:redacted secret-like assignment|redacted scanner finding):\s+(.+?)\s+::\s+(.+)$', item)
            if m:
                audit_secret_paths.append((normalize_audit_file(m.group(1)), m.group(2).strip()))

def should_skip(rel: Path):
    s = rel.as_posix()
    return s in {'.git','excludes.txt','excluded.txt'} or s.startswith('.git/')

def parse_env_lines(lines):
    result = {}
    for line in lines:
        if '=' in line and not line.lstrip().startswith('#'):
            k, v = line.split('=', 1)
            result[k] = v
    return result

def merge_env(src_env: Path, dst_env: Path):
    backup_lines = src_env.read_text(errors='ignore').splitlines()
    current_lines = dst_env.read_text(errors='ignore').splitlines() if dst_env.exists() else []
    current = parse_env_lines(current_lines)
    seen = set()
    out=[]
    restored=[]
    unresolved=[]
    for line in backup_lines:
        if '=' not in line or line.lstrip().startswith('#'):
            out.append(line); continue
        k,v=line.split('=',1)
        seen.add(k)
        secretish = bool(secret_key_re.search(k))
        redacted = v in {'', placeholder} or placeholder in v
        if secretish and redacted and k in current and current[k]:
            out.append(f'{k}={current[k]}')
            restored.append(canonical_secret_path('.env', k))
        else:
            out.append(line)
            if secretish and redacted:
                unresolved.append(canonical_secret_path('.env', k))
    for line in current_lines:
        if '=' not in line or line.lstrip().startswith('#'):
            continue
        k, _ = line.split('=', 1)
        if k not in seen and secret_key_re.search(k):
            out.append(line)
            restored.append(f'.env :: {k} (preserved current-only)')
    return '\n'.join(out)+'\n', restored, unresolved

def preserve_redacted_values(rel: Path, backup_text: str, current_text: str):
    current_by_key = {}
    for line in current_text.splitlines():
        m = assign_re.match(line)
        if m:
            current_by_key[m.group(2).lower()] = line
    out=[]; restored=[]; unresolved=[]
    for line_no, line in enumerate(backup_text.splitlines(), 1):
        if placeholder not in line:
            out.append(line); continue
        m = assign_re.match(line)
        if m and m.group(2).lower() in current_by_key:
            out.append(current_by_key[m.group(2).lower()])
            restored.append(canonical_secret_path(rel, m.group(2)))
        else:
            out.append(line)
            param = m.group(2) if m else f'line {line_no}'
            unresolved.append(canonical_secret_path(rel, param))
    return '\n'.join(out) + ('\n' if backup_text.endswith('\n') else ''), restored, unresolved

def is_text_file(path: Path):
    if path.name == '.env':
        return True
    if path.suffix.lower() in {'.env','.yaml','.yml','.json','.toml','.ini','.conf','.cfg','.txt','.md'}:
        return True
    try:
        data = path.read_bytes()[:4096]
        return b'\0' not in data
    except Exception:
        return False

def copy_existing_to_safety(dst: Path, rel: Path, safety_root: Path):
    target = safety_root / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    if dst.is_symlink():
        if target.exists() or target.is_symlink(): target.unlink()
        os.symlink(os.readlink(dst), target)
    elif dst.is_file():
        shutil.copy2(dst, target)
    elif dst.exists():
        raise RuntimeError(f'refusing to overwrite non-file path: {dst}')

files=[]
for root, dirs, names in os.walk(snapshot):
    rootp = Path(root)
    dirs[:] = [d for d in dirs if not should_skip((rootp/d).relative_to(snapshot))]
    for name in names:
        sp = rootp / name
        rel = sp.relative_to(snapshot)
        if not should_skip(rel):
            files.append((sp, rel, source / rel))

added=sum(1 for _,_,dp in files if not dp.exists() and not dp.is_symlink())
overwritten=len(files)-added
safety_root = source / 'restore-safety-snapshots' / time.strftime('%Y%m%d_%H%M%S')

def classify_secret_restore(sp: Path, rel: Path, dp: Path):
    if rel == Path('.env'):
        _, restored, unresolved = merge_env(sp, dp)
        return restored, unresolved
    if not is_text_file(sp):
        return [], []
    text = sp.read_text(errors='ignore')
    if placeholder not in text:
        return [], []
    current = dp.read_text(errors='ignore') if dp.exists() and dp.is_file() else ''
    _, restored, unresolved = preserve_redacted_values(rel, text, current)
    return restored, unresolved

for sp, rel, dp in files:
    restored, unresolved = classify_secret_restore(sp, rel, dp)
    for item in restored:
        add_unique(restored_secret_paths, item)
    for item in unresolved:
        if is_runtime_secret_path(item):
            add_unique(unresolved_secret_paths, item)
        else:
            add_unique(other_redacted_paths, item)

if dry_run:
    print('Restore dry-run summary:')
    print(f'- commit: {commit}')
    print(f'- source dir: {source}')
    print(f'- files to copy: {len(files)}')
    print(f'- would add: {added}')
    print(f'- would overwrite: {overwritten}')
    print('- would delete: 0')
else:
    source.mkdir(parents=True, exist_ok=True)
    for sp, rel, dp in files:
        if str(dp).startswith(str(snapshot) + os.sep):
            continue
        existed = dp.exists() or dp.is_symlink()
        if existed:
            copy_existing_to_safety(dp, rel, safety_root)
        dp.parent.mkdir(parents=True, exist_ok=True)
        if rel == Path('.env'):
            text, _, _ = merge_env(sp, dp)
            dp.write_text(text, encoding='utf-8')
            continue
        if sp.is_symlink():
            if dp.exists() or dp.is_symlink():
                if dp.is_dir() and not dp.is_symlink():
                    raise RuntimeError(f'refusing to replace directory with symlink: {dp}')
                dp.unlink()
            os.symlink(os.readlink(sp), dp)
        elif is_text_file(sp):
            text = sp.read_text(errors='ignore')
            if placeholder in text and dp.exists() and dp.is_file():
                text, _, _ = preserve_redacted_values(rel, text, dp.read_text(errors='ignore'))
            if dp.exists() and dp.is_dir():
                raise RuntimeError(f'refusing to replace directory with file: {dp}')
            dp.write_text(text, encoding='utf-8')
            shutil.copystat(sp, dp, follow_symlinks=False)
        else:
            if dp.exists() and dp.is_dir():
                raise RuntimeError(f'refusing to replace directory with file: {dp}')
            shutil.copy2(sp, dp)
    print('Restore summary:')
    print(f'- commit: {commit}')
    print(f'- source dir: {source}')
    print(f'- files copied: {len(files)}')
    print(f'- added: {added}')
    print(f'- overwritten: {overwritten}')
    print('- deleted: 0')
    if overwritten:
        print(f'- overwritten-file safety snapshot: {safety_root}')
print('Secret restore details:')
print(f'- restored/preserved secret values: {len(restored_secret_paths)}')
for item in restored_secret_paths[:80]:
    print(f'  - restored: {item}')
if len(restored_secret_paths) > 80:
    print(f'  - ... {len(restored_secret_paths)-80} more restored items omitted')
print(f'- secrets requiring manual action: {len(unresolved_secret_paths)}')
for item in unresolved_secret_paths[:80]:
    print(f'  - manual: {item}')
if len(unresolved_secret_paths) > 80:
    print(f'  - ... {len(unresolved_secret_paths)-80} more manual items omitted')
if other_redacted_paths:
    print(f'- redacted placeholders restored in non-runtime files: {len(other_redacted_paths)}')
    for item in other_redacted_paths[:20]:
        print(f'  - non-runtime: {item}')
    if len(other_redacted_paths) > 20:
        print(f'  - ... {len(other_redacted_paths)-20} more non-runtime items omitted')
if unresolved_secret_paths:
    print('Manual steps:')
    print('  - Open each listed file/path in the restored SOURCE_DIR.')
    print('  - Re-enter the real value from the original provider or password manager.')
    print(f'  - Previous overwritten originals, if any, are in: {safety_root}')
elif other_redacted_paths:
    print('Manual steps:')
    print('  - No runtime secret needs manual action.')
    print('  - These REDACTED placeholders were restored into docs/sessions/history files and can be ignored unless you specifically need the original historical text.')
if audit_items:
    print('Backup redaction audit from excluded.txt:')
    for item in audit_items[:50]:
        print(f'- {item}')
    if len(audit_items) > 50:
        print(f'- ... {len(audit_items)-50} more audit items omitted')
PY
  local restore_status=$?
  set -e
  git -C "$BACKUP_DIR" worktree remove --force "$worktree" >/dev/null 2>&1 || rm -rf "$worktree"
  return "$restore_status"
}
main() {
  parse_args "$@"
  load_config
  ensure_repo
  fetch_updates
  handle_local_changes
  say "Available backup commits:"
  git -C "$BACKUP_DIR" log --oneline --decorate --date=short --pretty=format:'%h %ad %s' -20 || true
  printf '\n'
  local commit
  commit="${COMMIT_REF:-$(ask 'Commit hash/ref to restore' 'HEAD')}"
  git -C "$BACKUP_DIR" rev-parse --verify "$commit^{commit}" >/dev/null
  if [ "$DRY_RUN" != "true" ] && [ "$ASSUME_YES" != "true" ]; then
    say "About to restore commit $commit into $SOURCE_DIR. Existing files may be overwritten, but originals will be saved under restore-safety-snapshots/."
    [ "$(ask 'Proceed? type yes to continue' 'no')" = "yes" ] || { say "Aborted."; exit 1; }
  fi
  restore_files "$commit"
  if [ "$DRY_RUN" = "true" ]; then
    say "Dry-run completed; no files were changed."
  else
    say "Restore copied files from $commit."
    say "Manual follow-up: re-add intentionally excluded secrets if needed. Snapshot-specific audit above is read from excluded.txt in the restored commit."
  fi
}
main "$@"
