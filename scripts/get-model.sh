#!/usr/bin/env bash
# get-model.sh: fetch a model listed in scripts/models.tsv and verify it.
#
# Usage: scripts/get-model.sh <label> [dest-dir]
#   scripts/get-model.sh 350M-Q4_K_M
#
# Every download goes through the registry: repo, filename, and pinned
# sha256 come from the row, never from arguments. A hash mismatch deletes
# the download and fails. The license text is fetched and verified against
# its pinned hash on every run, before anything is downloaded.
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
# The fetch tells an answer about the license from no usable answer.
# - A complete 200: the text is verified against its pin.
# - A 4xx other than 429 (the license removed, renamed or gated upstream),
#   or a final redirect curl did not follow: a refusal, whatever is on disk.
# - No usable answer: no network (000), a server error (5xx), rate limiting
#   (429), or a transfer that failed after a 2xx or a redirect (a body cut
#   short, or a redirect to a host that could not be reached: curl reports
#   the last status it received, the redirect's). The verified local copy
#   stands in, if there is one.
# - No status at all means curl itself did not run: a refusal.
set +e
CODE="$(curl -sSL --connect-timeout 10 --max-time 30 -o "$LICTMP" -w '%{http_code}' \
  "https://huggingface.co/$REPO/resolve/main/LICENSE" 2>/dev/null)"
RC=$?
set -e
NOANSWER=0
case "$CODE" in
  2??|3??) [ "$RC" -ne 0 ] && NOANSWER=1 ;;
  000|429|5??) NOANSWER=1 ;;
esac
if [ -z "$CODE" ]; then
  echo "get-model: curl did not run for the $REPO license (no status at all); refusing" >&2
  exit 1
elif [ "$CODE" = "200" ] && [ "$NOANSWER" = 0 ]; then
  GOTLICSHA="$(shasum -a 256 "$LICTMP" | awk '{print $1}')"
  if [ "$GOTLICSHA" != "$LICSHA" ]; then
    echo "get-model: $REPO license text hash mismatch (expected $LICSHA, got $GOTLICSHA)" >&2
    echo "get-model: refusing to proceed: the model repo's license changed, or its transfer was cut short where curl could not tell; retry, and if it persists, re-review the license" >&2
    exit 1
  fi
  if [ "$LIC" != "$CANON" ]; then cp "$LICTMP" "$LIC"; fi
elif [ "$NOANSWER" = 0 ]; then
  echo "get-model: the last answer upstream gave for the $REPO license was HTTP $CODE; refusing - re-review it" >&2
  exit 1
elif [ -f "$LIC" ] && [ "$(shasum -a 256 "$LIC" | awk '{print $1}')" = "$LICSHA" ]; then
  echo "get-model: no usable answer from upstream for the $REPO license (HTTP $CODE, curl exit $RC); using the verified local copy" >&2
else
  echo "get-model: cannot fetch or verify the $REPO license; refusing" >&2
  exit 1
fi

OUT="$DEST/$FILE"
# A run killed outright (a signal skips the EXIT trap) leaves its partial
# file. One found here is named, even beside a verified model, and left
# alone: it may be another fetch's, still running. This run's own is made
# below, after the scan.
for stale in "$OUT".partial.*; do
  [ -e "$stale" ] && echo "get-model: $stale may belong to another fetch still running, or be left from an interrupted one; remove it only when no fetch is running" >&2
done
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
# where the runtime looks, and the EXIT trap removes the partial file. Each
# run's partial file is its own (mktemp), so two runs fetching the same model
# never hash, rename or remove each other's bytes.
PART="$(mktemp "$OUT.partial.XXXXXX")"
echo "get-model: fetching $FILE from $REPO"
curl -fL --progress-bar -o "$PART" "$URL"
# mktemp makes the file owner-only. The weights are published 0644 whatever
# the umask, so any reader of the models directory, the runtime included,
# can load them.
chmod 644 "$PART"
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
