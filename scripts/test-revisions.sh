#!/usr/bin/env bash
# scripts/test-revisions.sh — revision history outlives the process that made it.
# Copies the working tree into a throwaway repo and runs separate SBCL processes against it:
# A commits a revision, B must see it, number past it and leave its file alone; starting and
# verifying add no commits; revisions land on the orphan branch evo-state, never on master.
set -uo pipefail
src=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cd "$src"
git ls-files -co --exclude-standard | while read -r f; do [ -e "$f" ] && cp --parents "$f" "$tmp"; done
cd "$tmp"
git init -q -b master && git add -A && git -c user.name=t -c user.email=t@t commit -qm base

lisp() { sbcl --noinform --non-interactive --load load.lisp --eval "$1" 2>&1; }
commits() { git rev-list --all --count; }
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

out_a=$(lisp '(progn
  (evo.kernel::evaluate (quote (defun world::reverse-string (s) (coerce (reverse (coerce s (quote list))) (quote string)))))
  (format t "~&REV ~a~%" (file-namestring (evo.kernel::revision-file (evo.kernel:commit-revision "reverse-string")))))')
a=$(sed -n 's/^REV rev-0*\([0-9]*\)\.lisp$/\1/p' <<<"$out_a")
check "process A committed a revision" '[ -n "$a" ]'
sum_a=$(sha256sum "revisions/rev-$(printf %04d "${a:-0}").lisp" 2>/dev/null)

before=$(commits)
out_b=$(lisp "(progn
  (format t \"~&FOUND ~a~%\" (ignore-errors (evo.kernel::revision-goal (evo.kernel::find-revision ${a:-0}))))
  (evo.kernel::evaluate (quote (defun world::twice (x) (* 2 x))))
  (format t \"~&REV ~a~%\" (file-namestring (evo.kernel::revision-file (evo.kernel:commit-revision \"twice\")))))")
b=$(sed -n 's/^REV rev-0*\([0-9]*\)\.lisp$/\1/p' <<<"$out_b")
check "process B finds A's revision by number" 'grep -q "^FOUND reverse-string$" <<<"$out_b"'
check "process B numbers its revision past A's" '[ -n "$b" ] && [ "$b" -gt "${a:-0}" ]'
check "process B leaves A's file byte-identical" '[ -n "$sum_a" ] && sha256sum -c --quiet <<<"$sum_a" 2>/dev/null'
check "a changed revision is still committed" '[ "$(commits)" -gt "$before" ]'

out_r=$(lisp "(progn (evo.kernel:rollback ${a:-0}) (format t \"~&GOT ~a~%\" (world::reverse-string \"ab\")))")
check "a later session rolls back to A's revision" 'grep -q "^GOT ba$" <<<"$out_r"'

lisp '(progn
  (sb-ext:run-program "sbcl" (list "--noinform" "--non-interactive" "--load" "load.lisp"
                                   "--eval" (format nil "(evo.kernel:commit-revision ~s)" "other"))
                      :search t)
  (evo.kernel:commit-revision "overlap"))' >/dev/null
check "overlapping sessions both keep their revision" 'grep -q "goal other " revisions/*.lisp && grep -q "goal overlap " revisions/*.lisp'

sleep 1   # revision headers carry a timestamp in whole seconds; a same-second start would hide a re-commit
before=$(commits)
lisp '(sb-ext:exit)' >/dev/null
check "a bare start adds no commit" '[ "$(commits)" -eq "$before" ]'

./run.sh verify "${a:-0}" reverse-string >/dev/null 2>&1; rc=$?
check "verify from the shell passes A's revision" '[ $rc -eq 0 ]'
check "verify adds no commit" '[ "$(commits)" -eq "$before" ]'
./run.sh verify 1 reverse-string >/dev/null 2>&1; rc=$?
check "verify fails the seed, which lacks reverse-string" '[ $rc -eq 1 ]'
out_v=$(./run.sh verify 99 reverse-string 2>&1); rc=$?
check "verify of a missing revision fails without a backtrace" '[ $rc -ne 0 ] && ! grep -q Backtrace <<<"$out_v"'

check "master holds no revision commit" '[ "$(git rev-list --count master)" -eq 1 ]'
check "revisions/ is a checkout of evo-state" '[ "$(git -C revisions rev-parse --abbrev-ref HEAD 2>/dev/null)" = evo-state ]'
check "evo-state shares no history with master" '! git merge-base master evo-state >/dev/null 2>&1 && git rev-parse -q --verify evo-state >/dev/null'

echo "$fails failed"
[ "$fails" -eq 0 ]
