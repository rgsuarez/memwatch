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

# (round 3) Comments and padding are judged after trimming: an indented
# comment is no term, and a padded term is the term.
printf '  # indented comment\n\t# tab-indented comment\n' > "$terms"
expect 2 "terms with only indented comments: refused"
printf '  %s  \n' "$term" > "$terms"
printf 'carries %s here\n' "$term" > "$tmp/probe.txt"
expect 1 "a padded term still matches (positive control)"
printf '%s\n' "$term" > "$terms"
clean

# (round 3) A binary file outside the exempt classes is scanned as text: a
# NUL byte must not hide a term.
printf 'bin\0carries %s\n' "$term" > "$tmp/blob.dat"
git -C "$tmp" add -f blob.dat
expect 1 "a tracked binary carrying a term fails"
git -C "$tmp" rm -q --cached blob.dat
rm -f "$tmp/blob.dat"

# (round 3) A named runtime ledger is refused by its path, whatever it holds.
printf '{"seq":1}\n' > "$tmp/outside/memwatch-observe.jsonl"
expect_named 1 "named: a runtime ledger is refused even when its content is clean" "$tmp/outside" "memwatch-observe.jsonl"
rm -f "$tmp/outside/memwatch-observe.jsonl"

# (round 3) Run from its own directory, the script still finds its term list.
got=0
(cd "$tmp/eval/checks" && env -u MEMWATCH_PUBLIC_CLONE bash ./no-internal-refs.sh) >/dev/null 2>&1 || got=$?
if [ "$got" -eq 0 ]; then echo "ok    from eval/checks: the term list is found"; else echo "FAIL  from eval/checks: the term list is found got=$got want=0"; fails=$((fails + 1)); fi
printf 'carries %s here\n' "$term" > "$tmp/probe.txt"
got=0
(cd "$tmp/eval/checks" && env -u MEMWATCH_PUBLIC_CLONE bash ./no-internal-refs.sh) >/dev/null 2>&1 || got=$?
if [ "$got" -eq 1 ]; then echo "ok    from eval/checks: a planted term fails (positive control)"; else echo "FAIL  from eval/checks: a planted term fails got=$got want=1"; fails=$((fails + 1)); fi
clean

# (round 3) A refusal for a pattern that does not compile names it.
printf '%s\n' 'acme[prod' > "$terms"
said="$( (cd "$tmp" && env -u MEMWATCH_PUBLIC_CLONE bash "$fw") 2>&1 >/dev/null || true)"
case "$said" in
  *"acme[prod"*) echo "ok    a pattern that does not compile is named" ;;
  *) echo "FAIL  a pattern that does not compile is named"; fails=$((fails + 1)) ;;
esac
printf '%s\n' "$term" > "$terms"

# (round 4) An exemption is an exact path in this repository: the same
# file name anywhere else is scanned like any other file.
mkdir -p "$tmp/lua" "$tmp/outside/lua"
printf 'emits %s here\n' "$(printf '%s:%s' league full)" > "$tmp/lua/memwatch_report.lua"
git -C "$tmp" add lua/memwatch_report.lua
expect 0 "the repository's own report module is exempt (control)"
printf 'carries %s here\n' "$term" > "$tmp/outside/lua/memwatch_report.lua"
printf 'emits %s here, and %s\n' "$(printf '%s:%s' league full)" "$term" > "$tmp/lua/memwatch_report.lua"
expect 1 "the report module is exempt from its sentinel only: a local term in it fails"
printf 'emits %s here\n' "$(printf '%s:%s' league full)" > "$tmp/lua/memwatch_report.lua"
# (round 7) The exemption is the sentinel's slot, not its text: a local term
# that equals the sentinel is still scanned in the exempt file.
printf '%s\n%s\n' "$term" "$(printf '%s:%s' league full)" > "$terms"
expect 1 "a local term equal to the sentinel is not exempted with it"
printf '%s\n' "$term" > "$terms"
expect 0 "and without that term the exempt file passes again (control)"
expect_named 1 "named: an exempt file name outside the repository is scanned" "$tmp/outside" "lua/memwatch_report.lua"
expect_named 1 "named: and so by its absolute path" "/" "$tmp/outside/lua/memwatch_report.lua"
git -C "$tmp" rm -q --cached lua/memwatch_report.lua
rm -rf "$tmp/lua" "$tmp/outside/lua"

# (round 4) A symlinked working directory cannot hide a file's place in the
# repository: the path classes still refuse it.
mkdir -p "$tmp/reports" "$tmp/eval/results"
printf 'plain page\n' > "$tmp/reports/value.html"
printf 'plain run\n' > "$tmp/eval/results/run1.txt"
link="$(mktemp -u)"
ln -s "$tmp" "$link"
expect_named 1 "named: a report page is refused from the repository (control)" "$tmp" "reports/value.html"
expect_named 1 "named: and from a symlinked path to it" "$link" "reports/value.html"
expect_named 1 "named: an eval result from a symlinked path" "$link" "eval/results/run1.txt"
rm -f "$link"
rm -rf "$tmp/reports" "$tmp/eval/results"

# (round 4) A named symlink is refused: its name says nothing of its target.
ln -s "$tmp/outside/draft.md" "$tmp/outside/innocent.txt"
expect_named 2 "named: a symlink is refused" "$tmp/outside" "innocent.txt"
rm -f "$tmp/outside/innocent.txt"

# (round 4) A hit in a file with no newline reports where, not what: the
# report stays small however large the line, and never prints the term.
awk -v k="$key" 'BEGIN { for (i = 0; i < 200000; i++) printf "aaaaaaaaaaaaaaa"; printf " %s", k }' > "$tmp/blob.txt"
git -C "$tmp" add -f blob.txt
said="$( (cd "$tmp" && env -u MEMWATCH_PUBLIC_CLONE bash "$fw") 2>&1 >/dev/null || true)"
got=0
(cd "$tmp" && env -u MEMWATCH_PUBLIC_CLONE bash "$fw") >/dev/null 2>&1 || got=$?
if [ "$got" -eq 1 ]; then echo "ok    a newline-free blob with a hit fails"; else echo "FAIL  a newline-free blob with a hit fails got=$got want=1"; fails=$((fails + 1)); fi
if [ "${#said}" -lt 1000 ]; then echo "ok    and its report is bounded (${#said} bytes)"; else echo "FAIL  and its report is bounded (${#said} bytes)"; fails=$((fails + 1)); fi
case "$said" in
  *"$key"*) echo "FAIL  the report does not print the hit"; fails=$((fails + 1)) ;;
  *"blob.txt, line 1"*) echo "ok    the report names the file and line, not the hit" ;;
  *) echo "FAIL  the report names the file and line"; fails=$((fails + 1)) ;;
esac
git -C "$tmp" rm -q --cached blob.txt
rm -f "$tmp/blob.txt"
printf 'carries %s here\n' "$term" > "$tmp/probe.txt"
said="$( (cd "$tmp" && env -u MEMWATCH_PUBLIC_CLONE bash "$fw") 2>&1 >/dev/null || true)"
case "$said" in
  *"$term"*) echo "FAIL  a local term is reported by number, not text"; fails=$((fails + 1)) ;;
  *"local term 1"*) echo "ok    a local term is reported by number, not text" ;;
  *) echo "FAIL  a local term is reported by number"; fails=$((fails + 1)) ;;
esac
clean

# (round 5) A term list that is there but cannot be read is as blind as a
# missing one: refused (2), not reported like a found reference (1).
# (Root reads a mode-000 file anyway, so the case cannot be staged as root.)
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$terms"
  expect 2 "an unreadable term list is refused"
  chmod 644 "$terms"
  expect 0 "a readable term list scans again (control)"
else
  echo "skip  an unreadable term list (running as root, which reads it anyway)"
fi

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
