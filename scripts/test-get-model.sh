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
    --connect-timeout|--max-time) shift 2 ;;
    --*) shift ;;
    -*) [[ "$1" == *f* ]] && fail=1; shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$url" >> "$FAKE_SRV/requests.log"
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
  # A transfer cut after the headers: curl still reports the 200 it got.
  head -c 9 "$src" > "$out"; status 200; exit 18
fi
if [ -n "${FAKE_REDIRECT_DEAD:-}" ] && [ "$FAKE_REDIRECT_DEAD" = "$name" ]; then
  # A redirect whose target cannot be reached: the 302 it got, exit 7.
  status 302; exit 7
fi
if [ -n "${FAKE_SHORT:-}" ] && [ "$FAKE_SHORT" = "$name" ]; then
  # A cut curl cannot see (no length given): a short body, a 200, exit 0.
  head -c 9 "$src" > "$out"; status 200; exit 0
fi
cp "$src" "$out"
status 200
STUB
chmod +x "$tmp/bin/curl"

fails=0
expect() {  # expect <want-exit> <name> [VAR=value ...]
  local want="$1" name="$2" got=0
  shift 2
  : > "$tmp/srv/requests.log"
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
# No request for the weights reached the server (a fetch that downloaded
# them and then cleaned up would leave nothing on disk to show it).
noWeightsAsked() { ! grep -q 'm.gguf' "$tmp/srv/requests.log"; }
saysNot() { ! grep -q "$1" "$tmp/out"; }

expect 0 "a license and model matching their pins are fetched and verified"
check "  the model is in place, with its pinned hash" hashIs "$models/m.gguf" "$msha"
check "  the verified license copy is kept" hashIs "$localLic" "$licsha"
expect 0 "a present, verified model is not fetched again" FAKE_FAIL=m.gguf

rm -f "$models/m.gguf"
printf 'synthetic license text, amended\n' > "$tmp/srv/LICENSE"
expect 1 "a license that changed upstream is refused"
check "  before any download" noWeightsAsked
printf 'synthetic license text\n' > "$tmp/srv/LICENSE"

expect 0 "offline, a previously verified local license stands" FAKE_FAIL=LICENSE
expect 1 "an HTTP answer without the license is refused, not taken for offline" FAKE_HTTP=LICENSE=404
check "  before any download" noWeightsAsked
rm -f "$models/m.gguf"
expect 0 "a server error on the license is no answer: the verified local copy stands" FAKE_HTTP=LICENSE=503
check "  and the weights are then fetched and verified" hashIs "$models/m.gguf" "$msha"
expect 0 "so is rate limiting" FAKE_HTTP=LICENSE=429
# No usable answer upstream and a local copy that fails its pin: nothing
# verified stands in, so the run is refused before any download.
printf 'tampered license text\n' > "$localLic"
rm -f "$models/m.gguf"
expect 1 "no usable answer beside a local license that fails its pin is refused" FAKE_HTTP=LICENSE=503
check "  before any download" noWeightsAsked
cp "$tmp/srv/LICENSE" "$localLic"
expect 0 "and a license transfer cut short after its 200" FAKE_PARTIAL=LICENSE
check "  not read as a changed license" saysNot "license changed"
rm -f "$models/m.gguf"
expect 0 "a redirect to a host that cannot be reached is no answer: the verified copy stands" FAKE_REDIRECT_DEAD=LICENSE
check "  and the weights are then fetched and verified" hashIs "$models/m.gguf" "$msha"
expect 1 "a final redirect on the license is refused" FAKE_HTTP=LICENSE=302
check "  before any download" noWeightsAsked
expect 1 "a cut curl cannot see is refused" FAKE_SHORT=LICENSE
check "  naming the cut as well as a changed license" grep -q "or its transfer was cut short" "$tmp/out"
expect 1 "a curl that did not run is refused, not taken for offline" FAKE_NORUN=LICENSE
check "  and says curl did not run" grep -q "curl did not run" "$tmp/out"
rm -f "$localLic" "$models/m.gguf"
expect 1 "offline with no verified local license, refused" FAKE_FAIL=LICENSE
check "  before any download" noWeightsAsked

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
check "  and names a partial file, as maybe another fetch's" grep -q "may belong to another fetch still running" "$tmp/out"
check "  and leaves the other run's files alone" \
  test "$(cat "$models/m.gguf.partial")" = "other run" -a "$(cat "$models/m.gguf.partial.OTHER1")" = "other run"
expect 0 "a verified model beside a partial file"
check "  is not fetched again" grep -q "already present and verified" "$tmp/out"
check "  and still names the partial file" grep -q "m.gguf.partial.OTHER1 may belong to another fetch" "$tmp/out"
rm -f "$models/m.gguf" "$models/m.gguf.partial" "$models/m.gguf.partial.OTHER1"

mkdir -p "$models"
printf 'stale bytes\n' > "$models/m.gguf"
expect 0 "a present but unverified model is fetched again"
check "  and verified" hashIs "$models/m.gguf" "$msha"

rm -f "$models/m.gguf"
row PENDING
expect 1 "a row with no pinned hash is refused"
check "  before any download" noWeightsAsked

if [ "$fails" -eq 0 ]; then
  echo
  echo "ALL PASS"
else
  echo
  echo "$fails FAILED"
  exit 1
fi
