#!/usr/bin/env bash
# test-get-model.sh: get-model.sh fails closed, with no network and no
# real download.
#
# Runs a copy of get-model.sh in a throwaway tree whose registry has one
# synthetic row, with a stub curl first on PATH that serves fixture files
# (or fails, as curl -f does, when FAKE_FAIL names part of the URL). The
# first case is the positive control: the same setup that must refuse in
# the later cases fetches and verifies when nothing is wrong.
#
# Usage: bash scripts/test-get-model.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/root/scripts" "$tmp/srv" "$tmp/bin"
cp "$here/get-model.sh" "$tmp/root/scripts/get-model.sh"
gm="$tmp/root/scripts/get-model.sh"
models="$tmp/models"

printf 'synthetic license text\n' > "$tmp/srv/LICENSE"
printf 'synthetic weights\n' > "$tmp/srv/m.gguf"
licsha="$(shasum -a 256 "$tmp/srv/LICENSE" | awk '{print $1}')"
msha="$(shasum -a 256 "$tmp/srv/m.gguf" | awk '{print $1}')"
row() { printf 'T\towner/repo\tm.gguf\t%s\t%s\n' "$1" "$licsha" > "$tmp/root/scripts/models.tsv"; }
row "$msha"
localLic="$tmp/root/licenses/owner_repo.LICENSE"

cat > "$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
if [ -n "${FAKE_FAIL:-}" ] && [[ "$url" == *"$FAKE_FAIL"* ]]; then exit 22; fi
src="$FAKE_SRV/${url##*/}"
[ -f "$src" ] || exit 22
cp "$src" "$out"
STUB
chmod +x "$tmp/bin/curl"

fails=0
expect() {  # expect <want-exit> <name> [VAR=value ...]
  local want="$1" name="$2" got=0
  shift 2
  (cd "$tmp/root" && env PATH="$tmp/bin:$PATH" FAKE_SRV="$tmp/srv" ${1+"$@"} bash "$gm" T "$models") \
    >"$tmp/out" 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then
    echo "ok    $name"
  else
    echo "FAIL  $name got=$got want=$want"
    sed 's/^/      /' "$tmp/out"
    fails=$((fails + 1))
  fi
}
check() {  # check <name> <command...>: the command must succeed
  local name="$1"
  shift
  if "$@"; then echo "ok    $name"; else echo "FAIL  $name"; fails=$((fails + 1)); fi
}
hashIs() { [ -f "$1" ] && [ "$(shasum -a 256 "$1" | awk '{print $1}')" = "$2" ]; }

expect 0 "a license and model matching their pins are fetched and verified"
check "  the model is in place, with its pinned hash" hashIs "$models/m.gguf" "$msha"
check "  the verified license copy is kept" hashIs "$localLic" "$licsha"
expect 0 "a present, verified model is not fetched again" FAKE_FAIL=m.gguf

rm -f "$models/m.gguf"
printf 'synthetic license text, amended\n' > "$tmp/srv/LICENSE"
expect 1 "a license that changed upstream is refused"
check "  before any download" test ! -e "$models/m.gguf"
printf 'synthetic license text\n' > "$tmp/srv/LICENSE"

expect 0 "offline, a previously verified local license stands" FAKE_FAIL=LICENSE
rm -f "$localLic" "$models/m.gguf"
expect 1 "offline with no verified local license, refused" FAKE_FAIL=LICENSE
check "  before any download" test ! -e "$models/m.gguf"

printf 'truncated' > "$tmp/srv/m.gguf"
expect 1 "a corrupt or partial download is refused"
check "  and deleted" test ! -e "$models/m.gguf"
printf 'synthetic weights\n' > "$tmp/srv/m.gguf"

mkdir -p "$models"
printf 'stale bytes\n' > "$models/m.gguf"
expect 0 "a present but unverified model is fetched again"
check "  and verified" hashIs "$models/m.gguf" "$msha"

rm -f "$models/m.gguf"
row PENDING
expect 1 "a row with no pinned hash is refused"
check "  before any download" test ! -e "$models/m.gguf"

if [ "$fails" -eq 0 ]; then
  echo
  echo "ALL PASS"
else
  echo
  echo "$fails FAILED"
  exit 1
fi
