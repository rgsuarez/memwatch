#!/usr/bin/env bash
# no-internal-refs.sh: the public-tree firewall.
#
# Scans the tracked tree, or the named input files about to leave the
# machine, for internal references and internal-only artifacts. Runs at
# every commit, before every external review send, and before every push.
# Deterministic grep only; artifact SHAPES are pinned by tests instead.
#
# Exit codes:
#   0  clean
#   1  an internal reference, or a tracked internal-only artifact, was found
#   2  refused to scan blind: the local term list is missing, or holds no
#      effective pattern (only blank and # lines); a pattern does not
#      compile; a named file cannot be read, or is a symlink (name its
#      target); a file cannot be scanned; or the tree scan found no files at
#      all (not a git tree). A public clone has no local list by design and
#      sets MEMWATCH_PUBLIC_CLONE=1 to scan with the structural patterns
#      alone.
#
# A hit is reported as its file and line and the pattern's number, never
# the matching text or a local term: the report itself stays bounded and
# carries nothing internal.
# test-no-internal-refs.sh pins this contract.
#
# Usage:
#   eval/checks/no-internal-refs.sh              # scan the tracked tree
#   eval/checks/no-internal-refs.sh <file>...    # scan the named files only
set -euo pipefail

# This script's own directory, resolved before any cd: the local term list
# lives beside it, wherever the script was invoked from.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Named files are resolved BEFORE moving to the repository root, so a path
# relative to the caller's directory scans the file the caller meant; a
# named file that cannot be read is a refusal, never a clean pass. Paths
# are physical (pwd -P), like the root below, so a symlinked directory
# cannot hide a file's place in the repository; a named symlink is refused
# (its name says nothing about what it points to).
NAMED=()
for f in "$@"; do
  if [ -L "$f" ]; then
    echo "no-internal-refs: $f is a symlink; name its target; refusing" >&2
    exit 2
  fi
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then
    echo "no-internal-refs: cannot read $f; refusing" >&2
    exit 2
  fi
  NAMED+=("$(cd "$(dirname "$f")" && pwd -P)/$(basename "$f")")
done

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo "$SCRIPT_DIR")/" 2>/dev/null || true
ROOT="$(pwd -P)"

# Internal-reference patterns. STRUCTURAL only, so this tracked script
# carries no specific internal identifier: any Notion-style workspace UUID
# (dashed or bare 32-hex), any issue-tracker key, Notion URLs, and the
# report's full-league render sentinel. The model vendor's public names
# (model cards, HF repos, license) are PUBLIC and not matched. A local,
# gitignored eval/checks/internal-terms.txt (one pattern per line) adds
# machine-specific terms without ever committing them to the public tree.
# The sentinel the report files emit, named once: the pattern list and its
# exemption below both use it, so neither can drift from the other.
SENTINEL='league:full'
PATTERNS=(
  '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
  '\b[0-9a-f]{32}\b'
  '\b[A-Z]{2,6}-[0-9]{2,}\b'
  'notion\.so|app\.notion\.com'
  "$SENTINEL"
)
STRUCTURAL=${#PATTERNS[@]}   # patterns past this index are local terms
SENTINEL_SLOT=0                # the sentinel's 1-based slot among the structural patterns
for i in "${!PATTERNS[@]}"; do
  if [ "${PATTERNS[$i]}" = "$SENTINEL" ]; then SENTINEL_SLOT=$((i + 1)); break; fi
done
[ "$SENTINEL_SLOT" -gt 0 ] || { echo "no-internal-refs: the sentinel is missing from the structural patterns" >&2; exit 2; }
LOCAL_TERMS="$SCRIPT_DIR/internal-terms.txt"
if [ -f "$LOCAL_TERMS" ] && [ ! -r "$LOCAL_TERMS" ]; then
  # Present but unreadable: as blind as missing, so the same refusal (2), not
  # a bare read error that would exit like a found reference.
  echo "no-internal-refs: $LOCAL_TERMS cannot be read; refusing" >&2
  exit 2
fi
if [ -f "$LOCAL_TERMS" ]; then
  effective=0
  # `|| [ -n "$pat" ]` keeps a final line that has no trailing newline.
  # Each line is judged trimmed: an indented comment is a comment, and a
  # padded term is the term (padding would make it unmatchable as written).
  while IFS= read -r pat || [ -n "$pat" ]; do
    pat="${pat#"${pat%%[![:space:]]*}"}"         # trim leading space
    pat="${pat%"${pat##*[![:space:]]}"}"         # trim trailing space
    [ -z "$pat" ] && continue                    # blank
    [ "${pat#\#}" != "$pat" ] && continue        # comment
    PATTERNS+=("$pat")
    effective=$((effective + 1))
  done < "$LOCAL_TERMS"
  # Fail closed: a list with no effective pattern scans as blind as a missing
  # one, so it gets the same refusal and the same public-clone opt-in.
  if [ "$effective" -eq 0 ] && [ "${MEMWATCH_PUBLIC_CLONE:-0}" != "1" ]; then
    echo "no-internal-refs: $LOCAL_TERMS has no effective pattern (only blank and # lines)," >&2
    echo "no-internal-refs: so the scan would be blind; refusing (MEMWATCH_PUBLIC_CLONE=1 opts out)" >&2
    exit 2
  fi
elif [ "${MEMWATCH_PUBLIC_CLONE:-0}" != "1" ]; then
  # Fail closed: a maintainer worktree without the local term list would scan
  # with only the structural patterns and pass blind. A plain public clone
  # (no local terms by design) opts in explicitly with MEMWATCH_PUBLIC_CLONE=1.
  echo "no-internal-refs: $LOCAL_TERMS is missing (symlink it into this worktree," >&2
  echo "no-internal-refs: or set MEMWATCH_PUBLIC_CLONE=1 in a public clone); refusing" >&2
  exit 2
fi

# A pattern that does not compile would make every grep fail, and a failing
# grep reads like no match: refuse instead of scanning blind.
for pat in "${PATTERNS[@]}"; do
  rc=0
  grep -E -e "$pat" /dev/null >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ge 2 ]; then
    echo "no-internal-refs: pattern '$pat' does not compile; refusing" >&2
    exit 2
  fi
done

fail=0
scanned=0

# A path's place in this repository: repository-relative for a tracked
# path (the tree scan lists them so) or a named file under the root; empty
# for a named file anywhere else, which no exemption by name ever covers.
repo_path() {
  case "$1" in
    "$ROOT"/*) printf '%s' "${1#"$ROOT"/}" ;;
    /*) printf '' ;;
    *) printf '%s' "$1" ;;
  esac
}

scan_file() {
  local f="$1" rel sentinelOk=0
  rel="$(repo_path "$f")"
  case "$rel" in
    eval/checks/no-internal-refs.sh) return 0 ;;  # the pattern list itself
    # These two emit or assert the league sentinel as a string literal (the
    # rendered ARTIFACTS carrying it are the leak class): exempt from that one
    # pattern only, and scanned for every other.
    lua/memwatch_report.lua|test_report.lua) sentinelOk=1 ;;
  esac
  case "$f" in
    *.gguf|*.png) return 0 ;;                      # binary artifacts
  esac
  scanned=$((scanned + 1))
  local idx=0
  for pat in "${PATTERNS[@]}"; do
    idx=$((idx + 1))
    # The exemption is the sentinel's own slot, never its text: a local term
    # that happens to equal it is still scanned.
    if [ "$sentinelOk" = 1 ] && [ "$idx" = "$SENTINEL_SLOT" ]; then continue; fi
    # grep -q itself, never a pipe: under pipefail a pipe into head turns a
    # large match set into SIGPIPE, which would read as no match. 0 is a
    # match, 1 none, anything else a file that could not be scanned. -a reads
    # a binary file as text: a NUL byte must not hide a term (the exempt
    # binary classes are skipped above).
    local rc=0
    grep -aqE -e "$pat" -- "$f" 2>/dev/null || rc=$?
    if [ "$rc" -eq 0 ]; then
      # Where, never what: the first matching line's number (cut keeps only
      # it, however long the line), and the pattern by number.
      local line what
      line="$({ grep -anE -m 1 -e "$pat" -- "$f" 2>/dev/null || true; } | cut -d: -f1)"
      if [ "$idx" -le "$STRUCTURAL" ]; then what="structural pattern $idx"; else what="local term $((idx - STRUCTURAL))"; fi
      echo "INTERNAL-REF: $what in $f, line ${line:-?}" >&2
      fail=1
    elif [ "$rc" -ge 2 ]; then
      echo "no-internal-refs: could not scan $f; refusing" >&2
      exit 2
    fi
  done
}

# Runtime and internal-only artifacts never leave the machine, whatever
# they hold: the same classes the tracked-tree check below refuses, by name
# anywhere, and by repository path inside this tree.
internal_artifact() {
  local f="$1" rel
  rel="$(repo_path "$f")"
  case "$(basename "$f")" in
    memwatch-lfm.jsonl*|memwatch-observe.jsonl*|memwatch-frozen.json*|memwatch-local.json*|memwatch.log*) return 0 ;;
  esac
  case "$rel" in
    models/*.gguf|eval/results/*|eval/tmp/*|eval/panel/*|reports/*) return 0 ;;
  esac
  return 1
}

if [ "${#NAMED[@]}" -gt 0 ]; then
  for f in "${NAMED[@]}"; do
    if internal_artifact "$f"; then
      echo "INTERNAL-ARTIFACT (must not leave the machine): $f" >&2
      fail=1
      continue
    fi
    scan_file "$f"
  done
else
  # Tracked-tree scan, plus tracked-path class assertions: runtime and
  # internal-only artifacts must never be tracked. A tree scan that finds
  # no file at all (not a git tree) is blind, not clean.
  while IFS= read -r f; do scan_file "$f"; done < <(git ls-files 2>/dev/null)
  if [ "$scanned" -eq 0 ]; then
    echo "no-internal-refs: the tree scan found no tracked files (not a git tree?); refusing" >&2
    exit 2
  fi
  BAD_TRACKED="$(git ls-files -- 'models/*.gguf' 'eval/results/*' 'eval/tmp/*' 'eval/panel/*' 'reports/*' 'memwatch-lfm.jsonl*' 'memwatch-observe.jsonl*' 'memwatch-frozen.json*' 'memwatch-local.json*' 'memwatch.log*' 2>/dev/null || true)"
  if [ -n "$BAD_TRACKED" ]; then
    echo "INTERNAL-ARTIFACT TRACKED (must stay gitignored):" >&2
    echo "$BAD_TRACKED" >&2
    fail=1
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "no-internal-refs: FAIL" >&2
  exit 1
fi
echo "no-internal-refs: clean"
