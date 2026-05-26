#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$SKILL_DIR/.agent-state-backup.conf"
BIN_DIR="$SKILL_DIR/bin"
LAST_ERROR="$SKILL_DIR/last_error.log"
EXCLUDES_FILE="$SKILL_DIR/excludes.txt"
SOURCE_DIR="${SOURCE_DIR:-/opt/data}"
BACKUP_DIR="${BACKUP_DIR:-/opt/data/git/agent-state-backup}"
mkdir -p "$BIN_DIR"

fail() { printf 'ERROR: %s\n' "$*" | tee "$LAST_ERROR" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
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
    printf 'CRON_SCHEDULE=%q\n' "${CRON_SCHEDULE:-5 0 * * *}"
    printf 'TRUFFLEHOG_FIRST_PUSH_DONE=%q\n' "${TRUFFLEHOG_FIRST_PUSH_DONE:-false}"
  } > "$CONFIG_FILE"
}
asset_url() {
  local repo="$1" pattern="$2"
  python3 - "$repo" "$pattern" <<'PY'
import json, re, sys, urllib.request
repo, pat = sys.argv[1], re.compile(sys.argv[2])
req = urllib.request.Request(f"https://api.github.com/repos/{repo}/releases/latest", headers={"User-Agent":"agent-state-backup"})
with urllib.request.urlopen(req, timeout=30) as r:
    data = json.load(r)
for a in data.get('assets', []):
    name = a.get('name','')
    if pat.search(name):
        print(a['browser_download_url'])
        break
else:
    raise SystemExit(f"no asset matching {pat.pattern}")
PY
}
ensure_tool() {
  local name="$1" repo="$2" pattern="$3" url tmp
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return 0
  fi
  if [ -x "$BIN_DIR/$name" ]; then
    printf '%s\n' "$BIN_DIR/$name"
    return 0
  fi
  say "Installing $name locally into $BIN_DIR..." >&2
  url="$(asset_url "$repo" "$pattern")" || fail "could not find release asset for $name"
  tmp="$(mktemp -d)"
  curl -fsSL "$url" -o "$tmp/$name.tar.gz" || fail "download failed for $name"
  tar -xzf "$tmp/$name.tar.gz" -C "$tmp" || fail "extract failed for $name"
  local found
  found="$(find "$tmp" -type f -name "$name" | head -n 1)"
  [ -n "$found" ] || fail "binary $name not found in archive"
  install -m 0755 "$found" "$BIN_DIR/$name"
  rm -rf "$tmp"
  printf '%s\n' "$BIN_DIR/$name"
}
ensure_gitleaks() {
  local arch pattern
  arch="$(uname -m)"
  case "$arch" in
    aarch64|arm64) pattern='linux_arm64\.tar\.gz$' ;;
    x86_64|amd64) pattern='linux_x64\.tar\.gz$|linux_amd64\.tar\.gz$' ;;
    *) fail "unsupported arch for gitleaks: $arch" ;;
  esac
  ensure_tool gitleaks gitleaks/gitleaks "$pattern"
}
ensure_trufflehog() {
  local arch pattern
  arch="$(uname -m)"
  case "$arch" in
    aarch64|arm64) pattern='linux_arm64\.tar\.gz$' ;;
    x86_64|amd64) pattern='linux_amd64\.tar\.gz$|linux_x86_64\.tar\.gz$' ;;
    *) fail "unsupported arch for trufflehog: $arch" ;;
  esac
  ensure_tool trufflehog trufflesecurity/trufflehog "$pattern"
}
ensure_excludes_file() {
  if [ -f "$EXCLUDES_FILE" ]; then
    return 0
  fi
  cat > "$EXCLUDES_FILE" <<'EOF'
# Persistent exclude patterns for agent-state-backup.
# This file belongs to the skill directory, not to the backup repository.
# Values are relative to SOURCE_DIR (/opt/data by default).
# Directory patterns may end with /. Glob patterns are supported.
auth.json
google_client_secret.json
google_token.json
keys/
git/
*/.agent-state-backup.conf
*/bin/gitleaks
*/bin/trufflehog
skills/devops/agent-state-backup/excludes.txt
EOF
}
add_exclude_patterns() {
  ensure_excludes_file
  python3 - "$EXCLUDES_FILE" "$@" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
new = [p.strip() for p in sys.argv[2:] if p.strip()]
lines = path.read_text(errors='ignore').splitlines() if path.exists() else []
existing = {line.strip() for line in lines if line.strip() and not line.lstrip().startswith('#')}
with path.open('a', encoding='utf-8') as f:
    for item in new:
        if item not in existing:
            f.write(item + '\n')
            existing.add(item)
PY
}
handle_args() {
  case "${1:-}" in
    --add-exclude)
      shift
      [ "$#" -gt 0 ] || fail "usage: $0 --add-exclude PATH [PATH...]"
      add_exclude_patterns "$@"
      say "Updated exclude patterns in $EXCLUDES_FILE"
      exit 0
      ;;
    --show-excludes)
      ensure_excludes_file
      cat "$EXCLUDES_FILE"
      exit 0
      ;;
  esac
}
mirror_source() {
  [ -d "$SOURCE_DIR" ] || fail "SOURCE_DIR missing: $SOURCE_DIR"
  mkdir -p "$BACKUP_DIR"
  [ -d "$BACKUP_DIR/.git" ] || fail "$BACKUP_DIR is not initialized as a git repository. Run initialize.sh first."
  ensure_excludes_file
  python3 - "$SOURCE_DIR" "$BACKUP_DIR" "$EXCLUDES_FILE" <<'PY'
import fnmatch, os, shutil, sys, stat
from pathlib import Path
src = Path(sys.argv[1]).resolve()
dst = Path(sys.argv[2]).resolve()
excludes_file = Path(sys.argv[3])
if src == dst or not str(dst).startswith(str(src) + os.sep):
    pass
# Clean destination except .git
for child in list(dst.iterdir()):
    if child.name == '.git':
        continue
    if child.is_dir() and not child.is_symlink():
        shutil.rmtree(child)
    else:
        child.unlink(missing_ok=True)

skip_parts = {'.git', '__pycache__'}
skip_suffixes = {'.pyc', '.pyo'}
patterns = []
if excludes_file.exists():
    for line in excludes_file.read_text(errors='ignore').splitlines():
        line = line.strip()
        if line and not line.startswith('#'):
            patterns.append(line)

def pattern_matches(pattern: str, rel: Path, is_dir: bool) -> bool:
    s = rel.as_posix()
    name = rel.name
    pat = pattern.strip().lstrip('/')
    if not pat:
        return False
    if pat.endswith('/'):
        base = pat.rstrip('/')
        return s == base or s.startswith(base + '/') or any(part == base for part in rel.parts)
    if '/' not in pat:
        return name == pat or fnmatch.fnmatch(name, pat)
    return s == pat or s.startswith(pat.rstrip('/') + '/') or fnmatch.fnmatch(s, pat)

def should_skip(p: Path) -> bool:
    rel = p.relative_to(src)
    parts = rel.parts
    if not parts:
        return False
    if any(part in skip_parts for part in parts):
        return True
    if p.suffix in skip_suffixes:
        return True
    return any(pattern_matches(pattern, rel, p.is_dir()) for pattern in patterns)

for root, dirs, files in os.walk(src):
    rootp = Path(root)
    dirs[:] = [d for d in dirs if not should_skip(rootp / d)]
    for fn in files:
        sp = rootp / fn
        if should_skip(sp):
            continue
        rel = sp.relative_to(src)
        dp = dst / rel
        dp.parent.mkdir(parents=True, exist_ok=True)
        try:
            if sp.is_symlink():
                target = os.readlink(sp)
                if dp.exists() or dp.is_symlink():
                    dp.unlink()
                os.symlink(target, dp)
            else:
                shutil.copy2(sp, dp)
        except FileNotFoundError:
            continue
PY
}
sanitation_pass() {
  ensure_excludes_file
  python3 - "$BACKUP_DIR" "$EXCLUDES_FILE" <<'PY'
import os, re, json, shutil, sys
from pathlib import Path
root = Path(sys.argv[1])
excludes_file = Path(sys.argv[2])
log = []
exclude_patterns = []
secret_file_re = re.compile(r'(^|[._-])(token|secret|credential|credentials|private[_-]?key|api[_-]?key)([._-]|$)', re.I)
private_key_re = re.compile(rb'-----BEGIN [A-Z ]*PRIVATE KEY-----')
text_exts = {'.env','.yaml','.yml','.json','.toml','.ini','.conf','.cfg','.txt','.md'}
assignment_re = re.compile(r'(?im)^([A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|PRIVATE_KEY|API_KEY|ACCESS_KEY|CLIENT_SECRET)[A-Z0-9_]*\s*=\s*)(.*)$')
yaml_re = re.compile(r'(?im)^(\s*[A-Za-z0-9_.-]*(?:token|secret|password|private_key|api_key|access_key|client_secret)[A-Za-z0-9_.-]*\s*:\s*)(.+)$')
json_re = re.compile(r'(?i)("[^"]*(?:token|secret|password|private_key|api_key|access_key|client_secret)[^"]*"\s*:\s*)"[^"]*"')

def rel(p): return str(p.relative_to(root))
def is_binary(data): return b'\0' in data[:4096]
for p in list(root.rglob('*')):
    if not p.is_file() or '.git' in p.parts:
        continue
    r = rel(p)
    name = p.name
    try:
        data = p.read_bytes()
    except Exception:
        continue
    if private_key_re.search(data) or (secret_file_re.search(name) and name not in {'.env','config.yaml','config.yml'}):
        p.unlink(missing_ok=True)
        log.append(f"removed credential-like file: {r}")
        exclude_patterns.append(r)
        continue
    if p.suffix.lower() in text_exts or name == '.env':
        if is_binary(data):
            continue
        text = data.decode('utf-8', errors='ignore')
        original = text
        text = assignment_re.sub(lambda m: m.group(1) + 'REDACTED_BY_AGENT_STATE_BACKUP', text)
        text = yaml_re.sub(lambda m: m.group(1) + 'REDACTED_BY_AGENT_STATE_BACKUP', text)
        text = json_re.sub(lambda m: m.group(1) + '"REDACTED_BY_AGENT_STATE_BACKUP"', text)
        text = re.sub(r'(?im)^((?:TELEGRAM_BOT_TOKEN|GITHUB_TOKEN|GH_TOKEN)\s*=\s*).+$', r'\1REDACTED_BY_AGENT_STATE_BACKUP', text)
        if text != original:
            p.write_text(text, encoding='utf-8')
            log.append(f"redacted secret-like assignments in: {r}")
with (root/'excluded.txt').open('a', encoding='utf-8') as f:
    if log:
        import datetime
        f.write(f"\n## {datetime.datetime.utcnow().strftime('%Y-%m-%d %H:%M UTC')}\n")
        for item in log:
            f.write(f"- {item}\n")
if exclude_patterns:
    existing = set()
    if excludes_file.exists():
        existing = {line.strip() for line in excludes_file.read_text(errors='ignore').splitlines() if line.strip() and not line.lstrip().startswith('#')}
    with excludes_file.open('a', encoding='utf-8') as f:
        for pth in exclude_patterns:
            if pth not in existing:
                f.write(pth + '\n')
PY
}
redact_gitleaks_findings() {
  local report="$1"
  python3 - "$BACKUP_DIR" "$report" <<'PY'
import json, re, sys
from pathlib import Path
root = Path(sys.argv[1]); report = Path(sys.argv[2])
try:
    findings = json.loads(report.read_text() or '[]')
except Exception as e:
    raise SystemExit(f"could not parse gitleaks report: {e}")
unresolved=[]; changed=[]
assign_re = re.compile(r'(?i)^\s*[^=:#]{0,120}(token|secret|password|api[_-]?key|private[_-]?key|access[_-]?key)[^=:#]{0,80}[=:#]')
for finding in findings:
    file = finding.get('File') or finding.get('file')
    secret = finding.get('Secret') or finding.get('secret')
    if not file:
        unresolved.append('unknown-file')
        continue
    p = (root / file).resolve()
    if not str(p).startswith(str(root.resolve())) or not p.exists() or not p.is_file():
        continue
    data = p.read_bytes()
    if b'\0' in data[:4096]:
        unresolved.append(file)
        continue
    text = data.decode('utf-8', errors='ignore')
    original = text
    if secret and secret in text:
        text = text.replace(secret, 'REDACTED_BY_AGENT_STATE_BACKUP')
    else:
        lines = text.splitlines(True)
        start = int(finding.get('StartLine') or finding.get('startLine') or 0)
        if start and 1 <= start <= len(lines) and assign_re.search(lines[start-1]):
            lines[start-1] = re.sub(r'([=:#]\s*).+$', r'\1REDACTED_BY_AGENT_STATE_BACKUP\n', lines[start-1])
            text = ''.join(lines)
        else:
            unresolved.append(file)
            continue
    if text != original:
        p.write_text(text, encoding='utf-8')
        changed.append(file)
if changed:
    with (root/'excluded.txt').open('a', encoding='utf-8') as f:
        f.write('\n## gitleaks auto-redaction\n')
        for file in sorted(set(changed)):
            f.write(f'- redacted scanner finding in: {file}\n')
if unresolved:
    raise SystemExit('unresolved scanner findings: ' + ', '.join(sorted(set(unresolved))))
PY
}
run_gitleaks_clean() {
  local gitleaks report status
  gitleaks="$(ensure_gitleaks)"
  report="$(mktemp)"
  trap 'rm -f "$report"' RETURN
  set +e
  "$gitleaks" detect --source "$BACKUP_DIR" --no-git --report-format json --report-path "$report" >/tmp/agent_state_backup_gitleaks.out 2>&1
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    rm -f /tmp/agent_state_backup_gitleaks.out "$report"
    trap - RETURN
    return 0
  fi
  redact_gitleaks_findings "$report" || fail "gitleaks found secrets that could not be safely redacted"
  rm -f "$report" /tmp/agent_state_backup_gitleaks.out
  trap - RETURN
  "$gitleaks" detect --source "$BACKUP_DIR" --no-git --redact >/tmp/agent_state_backup_gitleaks_final.out 2>&1 || fail "gitleaks still reports secrets after redaction"
  rm -f /tmp/agent_state_backup_gitleaks_final.out
}
run_trufflehog_once() {
  if [ "${TRUFFLEHOG_FIRST_PUSH_DONE:-false}" = "true" ]; then
    return 0
  fi
  local trufflehog out status
  trufflehog="$(ensure_trufflehog)"
  out="$(mktemp)"
  set +e
  "$trufflehog" filesystem "$BACKUP_DIR" --json --no-update > "$out" 2>/tmp/agent_state_backup_trufflehog.err
  status=$?
  set -e
  if [ -s "$out" ]; then
    if ! python3 - "$BACKUP_DIR" "$out" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1]).resolve()
report = Path(sys.argv[2])
allowed_prefixes = ('.cache/', '.local/share/tirith/')
allowed_exact = {'state.db', 'state.db-wal', 'state.db-shm'}
unresolved = []
for line in report.read_text(errors='ignore').splitlines():
    try:
        obj = json.loads(line)
    except Exception:
        continue
    meta = obj.get('SourceMetadata') or {}
    data = meta.get('Data') or {}
    fs = data.get('Filesystem') or data.get('filesystem') or {}
    path = fs.get('file') or fs.get('File') or fs.get('path') or fs.get('Path')
    if not path:
        continue
    try:
        rel = str(Path(path).resolve().relative_to(root))
    except Exception:
        rel = path
    if rel in allowed_exact or rel.startswith(allowed_prefixes):
        continue
    unresolved.append(rel)
if unresolved:
    raise SystemExit('unresolved trufflehog findings outside allowed state/cache paths: ' + ', '.join(sorted(set(unresolved))))
PY
    then
      rm -f "$out" /tmp/agent_state_backup_trufflehog.err
      fail "trufflehog found possible secrets outside allowed state/cache paths"
    fi
  fi
  rm -f "$out" /tmp/agent_state_backup_trufflehog.err
  TRUFFLEHOG_FIRST_PUSH_DONE=true
  save_config
}
commit_and_push() {
  git -C "$BACKUP_DIR" add -A
  if git -C "$BACKUP_DIR" diff --cached --quiet; then
    say "No backup changes to commit."
    rm -f "$LAST_ERROR"
    return 0
  fi
  local msg
  msg="backup $(date -u '+%Y-%m-%d %H:%M UTC')"
  git -C "$BACKUP_DIR" commit -m "$msg"
  local token cred
  token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [ -z "$token" ] && [ -f "$SOURCE_DIR/.env" ]; then
    token="$(python3 - "$SOURCE_DIR/.env" <<'PY'
import os, re, sys
path = sys.argv[1]
for line in open(path, encoding='utf-8', errors='ignore'):
    line = line.strip()
    if not line or line.startswith('#') or '=' not in line:
        continue
    key, value = line.split('=', 1)
    key = key.strip()
    if key in {'GITHUB_TOKEN', 'GH_TOKEN'}:
        value = value.strip().strip('"').strip("'")
        if value:
            print(value)
            break
PY
)"
  fi
  if [ -n "$token" ]; then
    cred="$(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')"
    git -C "$BACKUP_DIR" -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $cred" push -u origin HEAD
  else
    git -C "$BACKUP_DIR" push -u origin HEAD
  fi
  rm -f "$LAST_ERROR"
  say "Backup pushed: $msg"
}
main() {
  load_config
  handle_args "$@"
  [ -d "$BACKUP_DIR/.git" ] || fail "backup repo not initialized: run $SCRIPT_DIR/initialize.sh"
  ensure_excludes_file
  mirror_source
  sanitation_pass
  run_gitleaks_clean
  run_trufflehog_once
  commit_and_push
}
main "$@"
