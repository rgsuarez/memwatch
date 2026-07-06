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
LIC="$ROOT/licenses/LFM-Open-License-v1.0.txt"
if [ ! -f "$LIC" ]; then
  curl -fsSL -o "$LIC" "https://huggingface.co/$REPO/resolve/main/LICENSE"
fi
GOTLICSHA="$(shasum -a 256 "$LIC" | awk '{print $1}')"
if [ "$GOTLICSHA" != "$LICSHA" ]; then
  echo "get-model: license text hash mismatch (expected $LICSHA, got $GOTLICSHA)" >&2
  echo "get-model: refusing to proceed; the model repo's license changed - re-review it" >&2
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

echo "get-model: fetching $FILE from $REPO"
curl -fL --progress-bar -o "$OUT" "$URL"
GOT="$(shasum -a 256 "$OUT" | awk '{print $1}')"
if [ "$SHA" = "PENDING" ]; then
  echo "get-model: WARNING no pinned hash for $LABEL yet; computed $GOT" >&2
  echo "get-model: pin it in scripts/models.tsv before shipping this label" >&2
else
  if [ "$GOT" != "$SHA" ]; then
    rm -f "$OUT"
    echo "get-model: sha256 mismatch for $FILE (expected $SHA, got $GOT); deleted" >&2
    exit 1
  fi
  echo "get-model: verified $FILE ($SHA)"
fi
