#!/usr/bin/env bash
# test-get-model.sh: get-model.sh fails closed, with no network and no
# real download.
#
# Runs a copy of get-model.sh in a throwaway tree whose registry has one
# synthetic row, with a stub curl first on PATH that serves fixture files.
# The stub answers as curl does: FAKE_FAIL (part of a URL) is no network at
# all (status 000); FAKE_HTTP=<file>=<code> is an HTTP answer without the
# file (with -f, exit 22); FAKE_PARTIAL=<file> breaks the transfer after a
# few bytes (exit 18); FAKE_NORUN (part of a URL) prints no status at all,
# as when curl itself cannot run. The first case is the positive control: the same
# setup that must refuse in the later cases fetches and verifies when
# nothing is wrong.
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
out=""; url=""; wfmt=""; fail=0
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) wfmt="$2"; shift 2 ;;
    --*) shift ;;
    -*) [[ "$1" == *f* ]] && fail=1; shift ;;
    *) url="$1"; shift ;;
  esac
done
name="${url##*/}"
status() { [ -n "$wfmt" ] && printf '%s' "$1"; return 0; }
if [ -n "${FAKE_FAIL:-}" ] && [[ "$url" == *"$FAKE_FAIL"* ]]; then status 000; exit 6; fi
if [ -n "${FAKE_NORUN:-}" ] && [[ "$url" == *"$FAKE_NORUN"* ]]; then exit 127; fi
if [ -n "${FAKE_HTTP:-}" ] && [ "${FAKE_HTTP%%=*}" = "$name" ]; then
  status "${FAKE_HTTP#*=}"; [ "$fail" = 1 ] && exit 22; exit 0
fi
src="$FAKE_SRV/$name"
if [ ! -f "$src" ]; then status 404; [ "$fail" = 1 ] && exit 22; exit 0; fi
if [ -n "${FAKE_PARTIAL:-}" ] && [ "$FAKE_PARTIAL" = "$name" ]; then
  head -c 9 "$src" > "$out"; exit 18
fi
cp "$src" "$out"
status 200
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
expect 1 "an HTTP answer without the license is refused, not taken for offline" FAKE_HTTP=LICENSE=404
expect 1 "a curl that did not run is refused, not taken for offline" FAKE_NORUN=LICENSE
check "  and says curl did not run" grep -q "curl did not run" "$tmp/out"
rm -f "$localLic" "$models/m.gguf"
expect 1 "offline with no verified local license, refused" FAKE_FAIL=LICENSE
check "  before any download" test ! -e "$models/m.gguf"

printf 'truncated' > "$tmp/srv/m.gguf"
expect 1 "a corrupt or partial download is refused"
check "  and deleted" test ! -e "$models/m.gguf"
printf 'synthetic weights\n' > "$tmp/srv/m.gguf"
noPartials() { ! ls "$models"/m.gguf.partial* >/dev/null 2>&1; }
expect 22 "an HTTP error on the weights is refused" FAKE_HTTP=m.gguf=503
check "  and leaves nothing behind" test ! -e "$models/m.gguf"
check "  nor any partial file" noPartials
expect 18 "an interrupted transfer is refused" FAKE_PARTIAL=m.gguf
check "  and leaves nothing where the runtime looks" test ! -e "$models/m.gguf"
check "  nor its partial file" noPartials

# Another run's partial files (the old shared name, and a unique one) are
# neither removed nor renamed into place by this run.
printf 'other run\n' > "$models/m.gguf.partial"
printf 'other run\n' > "$models/m.gguf.partial.OTHER1"
expect 0 "a fetch beside another run's partial files"
check "  is verified" hashIs "$models/m.gguf" "$msha"
check "  is published readable (0644)" test "$(stat -f %Lp "$models/m.gguf")" = 644
check "  and names a leftover partial file" grep -q "left from an interrupted fetch" "$tmp/out"
check "  and leaves the other run's files alone" \
  test "$(cat "$models/m.gguf.partial")" = "other run" -a "$(cat "$models/m.gguf.partial.OTHER1")" = "other run"
rm -f "$models/m.gguf" "$models/m.gguf.partial" "$models/m.gguf.partial.OTHER1"

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
