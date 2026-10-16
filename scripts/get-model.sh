#!/usr/bin/env bash
# get-model.sh: fetch a model listed in scripts/models.tsv and verify it.
#
# Usage: scripts/get-model.sh <label> [dest-dir]
#   scripts/get-model.sh 350M-Q4_K_M
#
# Every download goes through the registry: repo, filename, and pinned
# sha256 come from the row, never from arguments. A hash mismatch deletes
# the download and fails. The license text is fetched alongside the first
# model and verified against its pinned hash.
set -euo pipefail

LABEL="${1:?usage: get-model.sh <label> [dest-dir]}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${2:-$ROOT/models}"
TSV="$ROOT/scripts/models.tsv"

ROW="$(grep -v '^#' "$TSV" | awk -F'\t' -v l="$LABEL" '$1 == l { print }' | head -1)"
if [ -z "$ROW" ]; then
  echo "get-model: unknown label '$LABEL' (see $TSV)" >&2
  exit 1
fi
REPO="$(printf '%s' "$ROW" | cut -f2)"
FILE="$(printf '%s' "$ROW" | cut -f3)"
SHA="$(printf '%s' "$ROW" | cut -f4)"
LICSHA="$(printf '%s' "$ROW" | cut -f5)"
URL="https://huggingface.co/$REPO/resolve/main/$FILE"

mkdir -p "$DEST" "$ROOT/licenses"

# License first: the operator sees what governs the weights before the fetch.
# Each row pins its own license hash. The repo's LICENSE is re-fetched and
# re-verified on every run, so an upstream license change is caught even when
# a local copy exists; offline, a previously verified local copy stands. Rows
# whose pin matches the tracked LFM Open License copy verify against it;
# other repos (same license text, different bytes) keep a fetched copy under
# licenses/<owner>_<repo>.LICENSE (gitignored).
CANON="$ROOT/licenses/LFM-Open-License-v1.0.txt"
CANONSHA=""
if [ -f "$CANON" ]; then CANONSHA="$(shasum -a 256 "$CANON" | awk '{print $1}')"; fi
if [ "$LICSHA" = "$CANONSHA" ]; then
  LIC="$CANON"
else
  LIC="$ROOT/licenses/$(printf '%s' "$REPO" | tr '/' '_').LICENSE"
fi
LICTMP="$(mktemp)"
PART=""
trap 'rm -f "$LICTMP" ${PART:+"$PART"}' EXIT
# The HTTP status tells an answer from no network: only no response at all
# (000) falls back to the verified local copy. Any other status (a license
# removed, renamed or gated upstream) is a refusal.
CODE="$(curl -sSL -o "$LICTMP" -w '%{http_code}' "https://huggingface.co/$REPO/resolve/main/LICENSE" 2>/dev/null || true)"
if [ "$CODE" = "200" ]; then
  GOTLICSHA="$(shasum -a 256 "$LICTMP" | awk '{print $1}')"
  if [ "$GOTLICSHA" != "$LICSHA" ]; then
    echo "get-model: $REPO license text hash mismatch (expected $LICSHA, got $GOTLICSHA)" >&2
    echo "get-model: refusing to proceed; the model repo's license changed - re-review it" >&2
    exit 1
  fi
  if [ "$LIC" != "$CANON" ]; then cp "$LICTMP" "$LIC"; fi
elif [ "$CODE" != "000" ] && [ -n "$CODE" ]; then
  echo "get-model: upstream answered HTTP $CODE for the $REPO license; refusing - re-review it" >&2
  exit 1
elif [ -f "$LIC" ] && [ "$(shasum -a 256 "$LIC" | awk '{print $1}')" = "$LICSHA" ]; then
  echo "get-model: could not reach upstream for the $REPO license; using the verified local copy" >&2
else
  echo "get-model: cannot fetch or verify the $REPO license; refusing" >&2
  exit 1
fi

OUT="$DEST/$FILE"
if [ -f "$OUT" ]; then
  GOT="$(shasum -a 256 "$OUT" | awk '{print $1}')"
  if [ "$SHA" != "PENDING" ] && [ "$GOT" = "$SHA" ]; then
    echo "get-model: $FILE already present and verified"
    exit 0
  fi
  echo "get-model: $FILE present but unverified; re-downloading" >&2
  rm -f "$OUT"
fi

# A PENDING (unpinned) row must never arm the adjudicator with unverified
# weights on the install path. Refuse by default; --allow-unpinned is the
# explicit escape hatch used only while first pinning a new combo's hash.
if [ "$SHA" = "PENDING" ] && [ "${ALLOW_UNPINNED:-0}" != "1" ]; then
  echo "get-model: $LABEL has no pinned sha256 in scripts/models.tsv; refusing." >&2
  echo "get-model: pin the hash first, or re-run with ALLOW_UNPINNED=1 to compute it." >&2
  exit 1
fi

# The download lands beside the final path and takes its name only once
# verified: an interrupted transfer (set -e stops at curl) leaves nothing
# where the runtime looks, and the EXIT trap removes the partial file.
PART="$OUT.partial"
rm -f "$PART"
echo "get-model: fetching $FILE from $REPO"
curl -fL --progress-bar -o "$PART" "$URL"
GOT="$(shasum -a 256 "$PART" | awk '{print $1}')"
if [ "$SHA" = "PENDING" ]; then
  mv "$PART" "$OUT"
  echo "get-model: ALLOW_UNPINNED set; computed $GOT (NOT verified)" >&2
  echo "get-model: pin it in scripts/models.tsv before shipping this label" >&2
else
  if [ "$GOT" != "$SHA" ]; then
    echo "get-model: sha256 mismatch for $FILE (expected $SHA, got $GOT); deleted" >&2
    exit 1
  fi
  mv "$PART" "$OUT"
  echo "get-model: verified $FILE ($SHA)"
fi
