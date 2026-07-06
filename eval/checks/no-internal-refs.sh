#!/usr/bin/env bash
# no-internal-refs.sh: the public-tree firewall.
#
# Fails (exit 1) when internal references or internal-only artifacts appear in
# the tracked tree, or in a named input file about to leave the machine.
# Runs at every commit, before every external review send, and before every
# push. Deterministic grep only; artifact SHAPES are pinned by tests instead.
#
# Usage:
#   eval/checks/no-internal-refs.sh              # scan the tracked tree
#   eval/checks/no-internal-refs.sh <file>...    # scan the named files only
set -euo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || dirname "$0")/" 2>/dev/null || true

# Internal-reference patterns. Workspace document ids (dashed or bare 32-hex
# with the known prefixes), issue-tracker keys, internal team/hub names,
# session callsigns, and machine-local coordination paths. The model vendor's
# public names (model cards, HF repos, license) are PUBLIC and not matched.
PATTERNS=(
  '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
  '\b(28ecbef0|245cbef0|368cbef0|1073af5b|279cbef0|38ecbef0|31acbef0)[0-9a-f-]*'
  '\bLQOS-[0-9]+'
  'Multimodal LFM'
  'notion\.so|app\.notion\.com'
  '\bLFM1\b'
  'mission packet'
  '\.zeos|zeos-lane'
  'league:full'
)

fail=0

scan_file() {
  local f="$1"
  case "$f" in
    eval/checks/no-internal-refs.sh) return 0 ;;  # the pattern list itself
    lua/memwatch_report.lua|test_report.lua) return 0 ;; # emit/assert the league sentinel as a string literal; rendered ARTIFACTS carrying it are the leak class
    *.gguf|*.png) return 0 ;;                      # binary artifacts
  esac
  for pat in "${PATTERNS[@]}"; do
    if grep -InE "$pat" "$f" /dev/null 2>/dev/null | head -3 | grep -q .; then
      echo "INTERNAL-REF: pattern '$pat' in $f:" >&2
      grep -InE "$pat" "$f" 2>/dev/null | head -3 >&2
      fail=1
    fi
  done
}

if [ "$#" -gt 0 ]; then
  for f in "$@"; do scan_file "$f"; done
else
  # Tracked-tree scan, plus tracked-path class assertions: runtime and
  # internal-only artifacts must never be tracked.
  while IFS= read -r f; do scan_file "$f"; done < <(git ls-files)
  BAD_TRACKED="$(git ls-files -- 'models/*.gguf' 'eval/results/*' 'eval/tmp/*' 'eval/panel/*' 'reports/*' 'memwatch-lfm.jsonl' 'memwatch-frozen.json' 'memwatch-local.json' 2>/dev/null || true)"
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
