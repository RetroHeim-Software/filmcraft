#!/bin/sh
# Check how far retroheim/base is behind public upstream, whether retroheim/main still
# rebases onto it, and whether the eight carried crates still pass their tests there.
# Read-only for the repository: fetches into a private ref, rebases in a scratch worktree,
# never pushes, never touches a branch. Run from a clone that has retroheim/base and
# retroheim/main (locally, or as origin/... in CI).
#
# Environment:
#   UPSTREAM_URL     public upstream (default https://github.com/storytold/filmcraft.git)
#   DRIFT_REPORT     file that receives the markdown report (default: stdout only)
#   DRIFT_SKIP_TESTS set to 1 to skip the test run
# Exit: 0 retroheim/base is level with upstream; 1 drift (behind, a rebase conflict, or red
# tests on the rebased result; the report says which); 2 the check itself could not run.
set -u

UPSTREAM_URL=${UPSTREAM_URL:-https://github.com/storytold/filmcraft.git}
REPORT=${DRIFT_REPORT:-}
CRATES="filmcraft-cfb filmcraft-color filmcraft-frame filmcraft-geom filmcraft-interchange filmcraft-media filmcraft-project filmcraft-time"

say() { printf '%s\n' "$*"; if [ -n "$REPORT" ]; then printf '%s\n' "$*" >>"$REPORT"; fi; }
die() { printf 'check-upstream-drift: %s\n' "$*" >&2; exit 2; }

[ -n "$REPORT" ] && : >"$REPORT"
top=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
cd "$top" || die "cannot enter $top"

resolve() { # branch name -> commit, local branch first, then origin
  git rev-parse --verify --quiet "refs/heads/$1^{commit}" ||
    git rev-parse --verify --quiet "refs/remotes/origin/$1^{commit}"
}
base=$(resolve retroheim/base) || die "retroheim/base not found"
main=$(resolve retroheim/main) || die "retroheim/main not found"

# Fetch upstream's default branch into a private ref (through the 'upstream' remote when
# it exists, otherwise by URL, so running this locally leaves no remote behind).
if git remote get-url upstream >/dev/null 2>&1; then src=upstream; else src=$UPSTREAM_URL; fi
head_branch=$(git ls-remote --symref "$src" HEAD 2>/dev/null | sed -n 's|^ref: refs/heads/\([^[:space:]]*\)[[:space:]]*HEAD$|\1|p')
[ -n "$head_branch" ] || die "cannot read upstream's default branch from $src"
git fetch --quiet "$src" "+refs/heads/$head_branch:refs/drift/upstream" || die "fetch from $src failed"
up=$(git rev-parse "refs/drift/upstream^{commit}")

behind=$(git rev-list --count "$base..$up")
ours=$(git rev-list --count "$base..$main")
say "## Upstream drift"
say ""
say "- upstream: $UPSTREAM_URL ($head_branch at $up)"
say "- retroheim/base: $base"
say "- retroheim/base is **$behind** commit(s) behind upstream; retroheim/main carries $ours of ours"

if [ "$behind" -eq 0 ]; then
  say "- nothing to rebase onto; no drift"
  exit 0
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/filmcraft-drift.XXXXXX") || die "cannot make a scratch directory"
cleanup() { git worktree remove --force "$scratch/wt" >/dev/null 2>&1; rm -rf "$scratch"; }
trap cleanup EXIT INT TERM
git worktree add --quiet --detach "$scratch/wt" "$main" || die "cannot create the scratch worktree"

ident="-c user.name=drift-check -c user.email=drift-check@invalid"
# shellcheck disable=SC2086
if ! git -C "$scratch/wt" $ident rebase --quiet --onto "$up" "$base" >"$scratch/rebase.log" 2>&1; then
  stopped=$(git -C "$scratch/wt" rev-parse --verify --quiet REBASE_HEAD)
  subject=$(git log -1 --format='%h %s' "${stopped:-HEAD}")
  files=$(git -C "$scratch/wt" diff --name-only --diff-filter=U | sed 's/^/  - /')
  say "- rebase: **CONFLICT** while applying: $subject"
  say "- conflicting files:"
  say "$files"
  git -C "$scratch/wt" rebase --abort >/dev/null 2>&1
  exit 1
fi
say "- rebase: clean ($ours commit(s) replayed onto upstream)"

if [ "${DRIFT_SKIP_TESTS:-0}" = 1 ]; then
  say "- tests: skipped"
  say "- action: rebase retroheim/main onto $up, rerun the proofs, publish"
  exit 1
fi
args=""
for c in $CRATES; do args="$args -p $c"; done
# shellcheck disable=SC2086
if (cd "$scratch/wt" && cargo test --locked $args >"$scratch/test.log" 2>&1) ||
   (cd "$scratch/wt" && cargo test $args >"$scratch/test.log" 2>&1); then
  passed=$(grep -E '^test result: ok' "$scratch/test.log" | sed -E 's/.* ([0-9]+) passed.*/\1/' | awk '{n+=$1} END {print n+0}')
  say "- tests: **pass** ($passed tests across the eight crates)"
  say "- action: rebase retroheim/main onto $up, rerun the proofs, publish (this clears the report)"
  exit 1
fi
say "- tests: **FAIL** on the rebased result; last lines:"
say ""
say '```'
tail -n 25 "$scratch/test.log" | while IFS= read -r l; do say "$l"; done
say '```'
exit 1
