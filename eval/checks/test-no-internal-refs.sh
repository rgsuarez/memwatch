#!/usr/bin/env bash
# test-no-internal-refs.sh: the exit-code contract of no-internal-refs.sh.
#
# Runs a copy of the firewall inside a throwaway git tree with synthetic
# term lists, so it never reads, prints or copies the local term list. Each
# case that must scan carries a positive control: the same setup has to
# catch a planted hit, or a clean exit could be a blind one.
#
# Usage: bash eval/checks/test-no-internal-refs.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/eval/checks"
cp "$here/no-internal-refs.sh" "$tmp/eval/checks/no-internal-refs.sh"
fw="$tmp/eval/checks/no-internal-refs.sh"
terms="$tmp/eval/checks/internal-terms.txt"
printf 'eval/checks/internal-terms.txt\n' > "$tmp/.gitignore"
printf 'plain tracked text\n' > "$tmp/probe.txt"
git -c init.defaultBranch=main -C "$tmp" init -q
git -C "$tmp" add .gitignore probe.txt eval/checks/no-internal-refs.sh

# A synthetic term, and a structural hit (an issue-key-shaped token)
# assembled at run time so this file never carries one itself.
term="zqxsyntheticterm"
key="$(printf '%s-%s' ZQX 4242)"
clean() { printf 'plain tracked text\n' > "$tmp/probe.txt"; }

fails=0
expect() {  # expect <want-exit> <name> [VAR=value ...]
  local want="$1" name="$2" got=0
  shift 2
  (cd "$tmp" && env -u MEMWATCH_PUBLIC_CLONE ${1+"$@"} bash "$fw") >/dev/null 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then
    echo "ok    $name"
  else
    echo "FAIL  $name got=$got want=$want"
    fails=$((fails + 1))
  fi
}

# Terms present: the tree is scanned with them.
printf '# synthetic list\n\n%s\n' "$term" > "$terms"
expect 0 "terms present: a clean tree passes"
printf 'carries %s here\n' "$term" > "$tmp/probe.txt"
expect 1 "terms present: a planted term fails (positive control)"
printf '%s' "$term" > "$terms"
expect 1 "terms present: a final line without a newline still loads"
clean

# Terms absent, public clone: the structural patterns alone, still a scan.
rm -f "$terms"
expect 0 "terms absent, public clone: a clean tree passes" MEMWATCH_PUBLIC_CLONE=1
printf 'see %s\n' "$key" > "$tmp/probe.txt"
expect 1 "terms absent, public clone: a structural hit fails (positive control)" MEMWATCH_PUBLIC_CLONE=1
clean

# Terms absent, no opt-in: refuse to scan blind.
expect 2 "terms absent, no opt-in: refused"

# Terms present but with no effective pattern: refuse to scan blind.
: > "$terms"
expect 2 "terms empty: refused"
printf '# only a comment\n\n   \n' > "$terms"
expect 2 "terms with only comments and blanks: refused"
expect 0 "terms with only comments, public clone: a clean tree passes" MEMWATCH_PUBLIC_CLONE=1
printf 'see %s\n' "$key" > "$tmp/probe.txt"
expect 1 "terms with only comments, public clone: a structural hit fails (positive control)" MEMWATCH_PUBLIC_CLONE=1
clean

echo
if [ "$fails" -eq 0 ]; then
  echo "ALL PASS"
else
  echo "$fails FAILED"
  exit 1
fi
