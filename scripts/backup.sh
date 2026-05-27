#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$SKILL_DIR/.agent-state-backup.conf"
BIN_DIR="$SKILL_DIR/bin"
LAST_ERROR="$SKILL_DIR/last_error.log"
EXCLUDES_FILE="$SKILL_DIR/excludes.txt"
INCLUDES_FILE="$SKILL_DIR/includes.txt"
SOURCE_DIR="${SOURCE_DIR:-/opt/data}"
BACKUP_DIR="${BACKUP_DIR:-/opt/data/git/agent-state-backup}"
ADDED_COUNT=0
MODIFIED_COUNT=0
DELETED_COUNT=0
NEW_SECRET_FINDINGS=0
mkdir -p "$BIN_DIR"

print_report() {
  local status="$1" commit_msg="$2" secrets="$3" errors="$4"
  printf 'Status: %s\n' "$status"
  printf 'Commit: %s\n' "$commit_msg"
  printf 'Added files: %s\n' "$ADDED_COUNT"
  printf 'Modified files: %s\n' "$MODIFIED_COUNT"
  printf 'Deleted files: %s\n' "$DELETED_COUNT"
  printf 'New secrets: %s\n' "$secrets"
  printf 'Errors: %s\n' "$errors"
}
fail() {
  local msg="$*" secrets="unknown"
  if [ "${NEW_SECRET_FINDINGS:-0}" -gt 0 ]; then
    secrets="yes"
  fi
  printf 'ERROR: %s\n' "$msg" > "$LAST_ERROR"
  print_report "error" "not created" "$secrets" "$msg"
  exit 1
}
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
  # Keep cron reports concise; only the final report should be printed on success.
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
EOF
}
ensure_includes_file() {
  if [ -f "$INCLUDES_FILE" ]; then
    return 0
  fi
  cat > "$INCLUDES_FILE" <<'EOF'
# Persistent force-include patterns for agent-state-backup.
# Values are relative to SOURCE_DIR (/opt/data by default).
# These paths override excludes and backup-time secret-like file removal.
# Use only for user-approved false positives; real secrets should remain excluded/redacted.
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
add_include_patterns() {
  ensure_includes_file
  python3 - "$INCLUDES_FILE" "$@" <<'PY'
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
    --add-include)
      shift
      [ "$#" -gt 0 ] || fail "usage: $0 --add-include PATH [PATH...]"
      add_include_patterns "$@"
      say "Updated include patterns in $INCLUDES_FILE"
      exit 0
      ;;
    --show-excludes)
      ensure_excludes_file
      cat "$EXCLUDES_FILE"
      exit 0
      ;;
    --show-includes)
      ensure_includes_file
      cat "$INCLUDES_FILE"
      exit 0
      ;;
  esac
}
mirror_source() {
  [ -d "$SOURCE_DIR" ] || fail "SOURCE_DIR missing: $SOURCE_DIR"
  mkdir -p "$BACKUP_DIR"
  [ -d "$BACKUP_DIR/.git" ] || fail "$BACKUP_DIR is not initialized as a git repository. Run initialize.sh first."
  ensure_excludes_file
  ensure_includes_file
  python3 - "$SOURCE_DIR" "$BACKUP_DIR" "$EXCLUDES_FILE" "$INCLUDES_FILE" <<'PY'
import fnmatch, os, shutil, sys, stat
from pathlib import Path
src = Path(sys.argv[1]).resolve()
dst = Path(sys.argv[2]).resolve()
excludes_file = Path(sys.argv[3])
includes_file = Path(sys.argv[4])
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
include_patterns = []
if excludes_file.exists():
    for line in excludes_file.read_text(errors='ignore').splitlines():
        line = line.strip()
        if line and not line.startswith('#'):
            patterns.append(line)
if includes_file.exists():
    for line in includes_file.read_text(errors='ignore').splitlines():
        line = line.strip()
        if line and not line.startswith('#'):
            include_patterns.append(line)

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
    # .git internals and bytecode are always skipped; includes are for backup false positives, not VCS/cache internals.
    if any(part in skip_parts for part in parts) or p.suffix in skip_suffixes:
        return True
    if any(pattern_matches(pattern, rel, p.is_dir()) for pattern in include_patterns):
        return False
    if p.is_dir():
        s = rel.as_posix().rstrip('/')
        # Keep walking directories that contain a force-included descendant even if the directory itself matches an exclude.
        for pattern in include_patterns:
            pat = pattern.strip().lstrip('/').rstrip('/')
            if pat and (pat == s or pat.startswith(s + '/')):
                return False
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
  ensure_includes_file
  python3 - "$BACKUP_DIR" "$EXCLUDES_FILE" "$INCLUDES_FILE" <<'PY'
import os, re, json, shutil, sys
from pathlib import Path
root = Path(sys.argv[1])
excludes_file = Path(sys.argv[2])
includes_file = Path(sys.argv[3])
log = []
exclude_patterns = []
include_patterns = []
if includes_file.exists():
    for line in includes_file.read_text(errors='ignore').splitlines():
        line = line.strip()
        if line and not line.startswith('#'):
            include_patterns.append(line)
secret_file_re = re.compile(r'(^|[._-])(token|secret|credential|credentials|private[_-]?key|api[_-]?key)([._-]|$)', re.I)
private_key_re = re.compile(rb'-----BEGIN [A-Z ]*PRIVATE KEY-----')
text_exts = {'.env','.yaml','.yml','.json','.toml','.ini','.conf','.cfg','.txt','.md'}
secret_key_re = re.compile(r'(token|secret|password|private_key|private-key|api_key|api-key|access_key|access-key|client_secret|client-secret)', re.I)
assignment_re = re.compile(r'(?im)^([A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|PRIVATE_KEY|API_KEY|ACCESS_KEY|CLIENT_SECRET)[A-Z0-9_]*\s*=\s*)(.*)$')
yaml_re = re.compile(r'(?im)^(\s*[A-Za-z0-9_.-]*(?:token|secret|password|private[_-]?key|api[_-]?key|access[_-]?key|client[_-]?secret)[A-Za-z0-9_.-]*\s*:\s*)(.+)$')
json_re = re.compile(r'(?i)("[^"]*(?:token|secret|password|private[_-]?key|api[_-]?key|access[_-]?key|client[_-]?secret)[^"]*"\s*:\s*)"[^"]*"')
explicit_env_re = re.compile(r'(?im)^((?:TELEGRAM_BOT_TOKEN|GITHUB_TOKEN|GH_TOKEN)\s*=\s*).+$')

def rel(p): return str(p.relative_to(root))
def pattern_matches(pattern: str, relpath: str) -> bool:
    pat = pattern.strip().lstrip('/')
    if not pat:
        return False
    if pat.endswith('/'):
        base = pat.rstrip('/')
        return relpath == base or relpath.startswith(base + '/')
    return relpath == pat or relpath.startswith(pat.rstrip('/') + '/') or __import__('fnmatch').fnmatch(relpath, pat)
def is_force_included(relpath: str) -> bool:
    return any(pattern_matches(pattern, relpath) for pattern in include_patterns)
def is_binary(data): return b'\0' in data[:4096]
def clean_value(value): return value.strip().strip('"').strip("'")
def is_real_value(value):
    v = clean_value(value)
    return bool(v and v != 'REDACTED_BY_AGENT_STATE_BACKUP' and v not in {'{}', '[]', 'null', 'None', '~'})
def env_redaction_paths(text):
    paths = []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith('#') or '=' not in stripped:
            continue
        key, value = stripped.split('=', 1)
        key = key.strip()
        if key in {'TELEGRAM_BOT_TOKEN', 'GITHUB_TOKEN', 'GH_TOKEN'} or secret_key_re.search(key):
            if is_real_value(value):
                paths.append(key)
    return paths
def yaml_redaction_paths(text):
    paths, stack = [], []
    key_value_re = re.compile(r'^(\s*)([A-Za-z0-9_.-]+)\s*:\s*(.*)$')
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        m = key_value_re.match(line)
        if not m:
            continue
        indent = len(m.group(1).replace('\t', '  '))
        key = m.group(2)
        value = m.group(3).split('#', 1)[0].strip()
        while stack and stack[-1][0] >= indent:
            stack.pop()
        current = [item[1] for item in stack] + [key]
        if secret_key_re.search(key) and is_real_value(value):
            paths.append('.'.join(current))
        if value == '' or value in {'|', '>'}:
            stack.append((indent, key))
    return paths
def json_redaction_paths(text):
    paths = []
    def walk(obj, prefix=''):
        if isinstance(obj, dict):
            for key, value in obj.items():
                path = f'{prefix}.{key}' if prefix else str(key)
                if secret_key_re.search(str(key)) and not isinstance(value, (dict, list)) and is_real_value(str(value)):
                    paths.append(path)
                walk(value, path)
        elif isinstance(obj, list):
            for i, value in enumerate(obj):
                walk(value, f'{prefix}[{i}]')
    try:
        walk(json.loads(text))
    except Exception:
        pass
    return paths
def redaction_paths(name, suffix, text):
    found = []
    if name == '.env' or suffix in {'.env', '.conf', '.cfg', '.ini', '.txt', '.md'}:
        found.extend(env_redaction_paths(text))
    if suffix in {'.yaml', '.yml'} or name in {'config.yaml', 'config.yml'}:
        found.extend(yaml_redaction_paths(text))
    if suffix == '.json':
        found.extend(json_redaction_paths(text))
    if not found:
        found.extend(env_redaction_paths(text))
        found.extend(yaml_redaction_paths(text))
        found.extend(json_redaction_paths(text))
    return sorted(set(found))
for p in list(root.rglob('*')):
    if not p.is_file() or '.git' in p.parts:
        continue
    r = rel(p)
    name = p.name
    try:
        data = p.read_bytes()
    except Exception:
        continue
    if is_force_included(r):
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
        paths = redaction_paths(name, p.suffix.lower(), text)
        text = assignment_re.sub(lambda m: m.group(1) + 'REDACTED_BY_AGENT_STATE_BACKUP', text)
        text = yaml_re.sub(lambda m: m.group(1) + 'REDACTED_BY_AGENT_STATE_BACKUP', text)
        text = json_re.sub(lambda m: m.group(1) + '"REDACTED_BY_AGENT_STATE_BACKUP"', text)
        text = explicit_env_re.sub(r'\1REDACTED_BY_AGENT_STATE_BACKUP', text)
        if text != original:
            p.write_text(text, encoding='utf-8')
            if paths:
                for param in paths:
                    log.append(f"redacted secret-like assignment: {r} :: {param}")
            else:
                log.append(f"redacted secret-like assignment: {r} :: unknown parameter")
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
  python3 - "$BACKUP_DIR" "$report" "$INCLUDES_FILE" <<'PY'
import json, re, sys
from pathlib import Path
root = Path(sys.argv[1]).resolve(); report = Path(sys.argv[2]); includes_file = Path(sys.argv[3])
include_patterns=[]
if includes_file.exists():
    include_patterns=[line.strip() for line in includes_file.read_text(errors='ignore').splitlines() if line.strip() and not line.lstrip().startswith('#')]
def pattern_matches(pattern: str, relpath: str) -> bool:
    import fnmatch
    pat = pattern.strip().lstrip('/')
    if not pat:
        return False
    if pat.endswith('/'):
        base = pat.rstrip('/')
        return relpath == base or relpath.startswith(base + '/')
    return relpath == pat or relpath.startswith(pat.rstrip('/') + '/') or fnmatch.fnmatch(relpath, pat)
def is_force_included(relpath: str) -> bool:
    return any(pattern_matches(pattern, relpath) for pattern in include_patterns)
def normalize_finding_file(file: str) -> str:
    try:
        path = Path(file)
        if path.is_absolute():
            return str(path.resolve().relative_to(root))
    except Exception:
        pass
    return file
try:
    findings = json.loads(report.read_text() or '[]')
except Exception as e:
    raise SystemExit(f"could not parse gitleaks report: {e}")
unresolved=[]; changed=[]
assign_re = re.compile(r'(?i)^\s*[^=:#]{0,120}(token|secret|password|api[_-]?key|private[_-]?key|access[_-]?key)[^=:#]{0,80}[=:#]')
key_re = re.compile(r'^\s*["\']?([A-Za-z0-9_.-]*(?:token|secret|password|api[_-]?key|private[_-]?key|access[_-]?key|client[_-]?secret)[A-Za-z0-9_.-]*)["\']?\s*[=:#]', re.I)
def finding_location(file, text, finding, secret):
    lines = text.splitlines()
    start = int(finding.get('StartLine') or finding.get('startLine') or 0)
    candidates = []
    if start and 1 <= start <= len(lines):
        candidates.append((start, lines[start-1]))
    if secret:
        for i, line in enumerate(lines, 1):
            if secret in line:
                candidates.append((i, line))
                break
    for line_no, line in candidates:
        m = key_re.search(line)
        if m:
            return f"{file} :: {m.group(1)}"
        if line_no:
            return f"{file} :: line {line_no}"
    return f"{file} :: unknown parameter"
for finding in findings:
    raw_file = finding.get('File') or finding.get('file')
    secret = finding.get('Secret') or finding.get('secret')
    if not raw_file:
        unresolved.append('unknown-file')
        continue
    file = normalize_finding_file(raw_file)
    if is_force_included(file):
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
        changed.append(finding_location(file, original, finding, secret))
if changed:
    with (root/'excluded.txt').open('a', encoding='utf-8') as f:
        f.write('\n## gitleaks auto-redaction\n')
        for item in sorted(set(changed)):
            f.write(f'- redacted scanner finding: {item}\n')
if unresolved:
    raise SystemExit('unresolved scanner findings: ' + ', '.join(sorted(set(unresolved))))
PY
}
gitleaks_unincluded_count() {
  local report="$1"
  local root="$2"
  python3 - "$report" "$INCLUDES_FILE" "$root" <<'PY'
import fnmatch, json, sys
from pathlib import Path
report = Path(sys.argv[1]); includes_file = Path(sys.argv[2]); root = Path(sys.argv[3]).resolve()
patterns=[]
if includes_file.exists():
    patterns=[line.strip() for line in includes_file.read_text(errors='ignore').splitlines() if line.strip() and not line.lstrip().startswith('#')]
def matches(pattern, relpath):
    pat = pattern.strip().lstrip('/')
    if not pat:
        return False
    if pat.endswith('/'):
        base = pat.rstrip('/')
        return relpath == base or relpath.startswith(base + '/')
    return relpath == pat or relpath.startswith(pat.rstrip('/') + '/') or fnmatch.fnmatch(relpath, pat)
def included(relpath):
    return any(matches(p, relpath) for p in patterns)
def normalize_file(file):
    try:
        path = Path(file)
        if path.is_absolute():
            return str(path.resolve().relative_to(root))
    except Exception:
        pass
    return file
try:
    findings = json.loads(report.read_text() or '[]')
except Exception:
    print(1); raise SystemExit
count = 0
for finding in findings:
    file = normalize_file(finding.get('File') or finding.get('file') or '')
    if not file or not included(file):
        count += 1
print(count)
PY
}
run_gitleaks_clean() {
  local gitleaks report status findings_count
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
  findings_count="$(gitleaks_unincluded_count "$report" "$BACKUP_DIR")"
  if [ "$findings_count" -eq 0 ]; then
    rm -f /tmp/agent_state_backup_gitleaks.out "$report"
    trap - RETURN
    return 0
  fi
  NEW_SECRET_FINDINGS=$((NEW_SECRET_FINDINGS + findings_count))
  redact_gitleaks_findings "$report" || fail "gitleaks found secrets that could not be safely redacted"
  rm -f "$report" /tmp/agent_state_backup_gitleaks.out
  trap - RETURN
  local final_report final_count
  final_report="$(mktemp)"
  "$gitleaks" detect --source "$BACKUP_DIR" --no-git --report-format json --report-path "$final_report" >/tmp/agent_state_backup_gitleaks_final.out 2>&1 || true
  final_count="$(gitleaks_unincluded_count "$final_report" "$BACKUP_DIR")"
  rm -f "$final_report" /tmp/agent_state_backup_gitleaks_final.out
  [ "$final_count" -eq 0 ] || fail "gitleaks still reports non-included secrets after redaction"
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
    if ! python3 - "$BACKUP_DIR" "$out" "$INCLUDES_FILE" <<'PY'
import fnmatch, json, sys
from pathlib import Path
root = Path(sys.argv[1]).resolve()
report = Path(sys.argv[2])
includes_file = Path(sys.argv[3])
include_patterns = []
if includes_file.exists():
    include_patterns = [line.strip() for line in includes_file.read_text(errors='ignore').splitlines() if line.strip() and not line.lstrip().startswith('#')]
def matches(pattern, relpath):
    pat = pattern.strip().lstrip('/')
    if not pat:
        return False
    if pat.endswith('/'):
        base = pat.rstrip('/')
        return relpath == base or relpath.startswith(base + '/')
    return relpath == pat or relpath.startswith(pat.rstrip('/') + '/') or fnmatch.fnmatch(relpath, pat)
def included(relpath):
    return any(matches(p, relpath) for p in include_patterns)
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
    if included(rel):
        continue
    unresolved.append(rel)
if unresolved:
    raise SystemExit('unresolved trufflehog findings outside allowed state/cache paths: ' + ', '.join(sorted(set(unresolved))))
PY
    then
      NEW_SECRET_FINDINGS=1
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
  local counts
  counts="$(git -C "$BACKUP_DIR" diff --cached --name-status | python3 -c 'import sys
added = modified = deleted = 0
for line in sys.stdin:
    status = line.split("\t", 1)[0]
    code = status[:1]
    if code == "A":
        added += 1
    elif code == "D":
        deleted += 1
    else:
        modified += 1
print(added, modified, deleted)')"
  read -r ADDED_COUNT MODIFIED_COUNT DELETED_COUNT <<< "$counts"
  if git -C "$BACKUP_DIR" diff --cached --quiet; then
    rm -f "$LAST_ERROR"
    print_report "ok" "no changes" "no" "no"
    return 0
  fi
  local msg commit_out push_out token cred
  msg="backup $(date -u '+%Y-%m-%d %H:%M UTC')"
  commit_out="$(mktemp)"
  push_out="$(mktemp)"
  if ! git -C "$BACKUP_DIR" commit --quiet -m "$msg" >"$commit_out" 2>&1; then
    local err
    err="$(tail -n 5 "$commit_out" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
    rm -f "$commit_out" "$push_out"
    fail "git commit failed: $err"
  fi
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
    if ! git -C "$BACKUP_DIR" -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $cred" push --quiet -u origin HEAD >"$push_out" 2>&1; then
      local err
      err="$(tail -n 5 "$push_out" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
      rm -f "$commit_out" "$push_out"
      fail "git push failed: $err"
    fi
  else
    if ! git -C "$BACKUP_DIR" push --quiet -u origin HEAD >"$push_out" 2>&1; then
      local err
      err="$(tail -n 5 "$push_out" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
      rm -f "$commit_out" "$push_out"
      fail "git push failed: $err"
    fi
  fi
  rm -f "$commit_out" "$push_out" "$LAST_ERROR"
  if [ "$NEW_SECRET_FINDINGS" -gt 0 ]; then
    print_report "ok" "$msg" "yes ($NEW_SECRET_FINDINGS scanner findings auto-redacted/allowed)" "no"
  else
    print_report "ok" "$msg" "no" "no"
  fi
}
main() {
  load_config
  handle_args "$@"
  [ -d "$BACKUP_DIR/.git" ] || fail "backup repo not initialized: run $SCRIPT_DIR/initialize.sh"
  ensure_excludes_file
  ensure_includes_file
  mirror_source
  sanitation_pass
  run_gitleaks_clean
  run_trufflehog_once
  commit_and_push
}
main "$@"
