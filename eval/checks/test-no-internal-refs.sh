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

# A term that does not compile would fail every grep, which reads as no
# match: refuse instead.
printf '%s\n' 'acme[prod' > "$terms"
expect 2 "a term that does not compile: refused"
printf '%s\n' "$term" > "$terms"

# A large match set must still be caught (a pipe into head under pipefail
# once turned it into SIGPIPE and a clean exit).
awk -v t="$term" 'BEGIN { for (i = 0; i < 2000; i++) print "line " i " " t }' > "$tmp/probe.txt"
expect 1 "a large match set fails (positive control for the SIGPIPE blind)"
clean

# A tracked runtime artifact is caught by its path, whatever it holds.
printf '{"seq":1}\n' > "$tmp/memwatch-observe.jsonl"
git -C "$tmp" add -f memwatch-observe.jsonl
expect 1 "a tracked observation ledger fails"
git -C "$tmp" rm -q --cached memwatch-observe.jsonl
rm -f "$tmp/memwatch-observe.jsonl"

# Named files: a missing one is refused; a relative path is scanned from
# the caller's directory, not the repository root.
expect_named() {  # expect_named <want-exit> <name> <dir> <file>
  local want="$1" name="$2" dir="$3" file="$4" got=0
  (cd "$dir" && env -u MEMWATCH_PUBLIC_CLONE bash "$fw" "$file") >/dev/null 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then
    echo "ok    $name"
  else
    echo "FAIL  $name got=$got want=$want"
    fails=$((fails + 1))
  fi
}
mkdir -p "$tmp/outside"
printf 'carries %s here\n' "$term" > "$tmp/outside/draft.md"
expect_named 2 "named: a missing file is refused" "$tmp/outside" "no-such-file.md"
expect_named 1 "named: a relative path is scanned where the caller stands" "$tmp/outside" "draft.md"
printf 'plain draft\n' > "$tmp/outside/draft.md"
expect_named 0 "named: a clean named file passes" "$tmp/outside" "draft.md"

# Not a git tree: a tree scan that finds no files is blind, not clean.
notgit="$(mktemp -d)"
mkdir -p "$notgit/eval/checks"
cp "$fw" "$notgit/eval/checks/no-internal-refs.sh"
printf 'see %s\n' "$key" > "$notgit/probe.txt"
got=0
(cd "$notgit" && MEMWATCH_PUBLIC_CLONE=1 bash eval/checks/no-internal-refs.sh) >/dev/null 2>&1 || got=$?
rm -rf "$notgit"
if [ "$got" -eq 2 ]; then echo "ok    not a git tree: refused"; else echo "FAIL  not a git tree: refused got=$got want=2"; fails=$((fails + 1)); fi

echo
if [ "$fails" -eq 0 ]; then
  echo "ALL PASS"
else
  echo "$fails FAILED"
  exit 1
fi
