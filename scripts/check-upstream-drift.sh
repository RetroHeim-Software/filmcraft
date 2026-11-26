#!/bin/sh
# Check how far retroheim/main is behind public upstream, whether upstream still merges into it
# cleanly, and whether the eight carried crates pass their tests on the merged result.
# Read-only for the repository: fetches into a private ref, merges in memory (`git merge-tree`)
# and tests in a scratch worktree, never pushes, never moves a branch. Run from a clone that has
# retroheim/main (locally, or as origin/retroheim/main in CI).
#
# Environment:
#   UPSTREAM_URL     public upstream (default https://github.com/storytold/filmcraft.git)
#   DRIFT_REPORT     file that receives the markdown report (default: stdout only)
#   DRIFT_SKIP_TESTS set to 1 to skip the test run
#   DRIFT_MAIN       commit or branch to check instead of retroheim/main (e.g. a merge branch)
# Exit: 0 retroheim/main already contains upstream; 1 drift (behind, a merge conflict, or red
# tests on the merged result; the report says which); 2 the check itself could not run.
set -u

UPSTREAM_URL=${UPSTREAM_URL:-https://github.com/storytold/filmcraft.git}
REPORT=${DRIFT_REPORT:-}
CRATES="filmcraft-cfb filmcraft-color filmcraft-frame filmcraft-geom filmcraft-interchange filmcraft-media filmcraft-project filmcraft-time"

say() { printf '%s\n' "$*"; if [ -n "$REPORT" ]; then printf '%s\n' "$*" >>"$REPORT"; fi; }
die() {
  printf 'check-upstream-drift: %s\n' "$*" >&2
  if [ -n "$REPORT" ]; then printf -- '- **the check could not run:** %s\n' "$*" >>"$REPORT"; fi
  exit 2
}

[ -n "$REPORT" ] && : >"$REPORT"
top=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
cd "$top" || die "cannot enter $top"
# `git merge-tree --write-tree` needs Git 2.38 or later.
git merge-tree --write-tree HEAD HEAD >/dev/null 2>&1 || die "git is too old for 'merge-tree --write-tree' (needs 2.38+)"

resolve() { # branch name -> commit, local branch first, then origin
  git rev-parse --verify --quiet "refs/heads/$1^{commit}" ||
    git rev-parse --verify --quiet "refs/remotes/origin/$1^{commit}"
}
if [ -n "${DRIFT_MAIN:-}" ]; then
  main=$(git rev-parse --verify --quiet "$DRIFT_MAIN^{commit}") || die "$DRIFT_MAIN not found"
else
  main=$(resolve retroheim/main) || die "retroheim/main not found"
fi

# Fetch upstream's default branch into a private ref (through the 'upstream' remote when
# it exists, otherwise by URL, so running this locally leaves no remote behind).
if git remote get-url upstream >/dev/null 2>&1; then src=upstream; else src=$UPSTREAM_URL; fi
head_branch=$(git ls-remote --symref "$src" HEAD 2>/dev/null | sed -n 's|^ref: refs/heads/\([^[:space:]]*\)[[:space:]]*HEAD$|\1|p')
[ -n "$head_branch" ] || die "cannot read upstream's default branch from $src"
git fetch --quiet "$src" "+refs/heads/$head_branch:refs/drift/upstream" || die "fetch from $src failed"
up=$(git rev-parse "refs/drift/upstream^{commit}")

behind=$(git rev-list --count "$main..$up")
ours=$(git rev-list --count --no-merges "$up..$main")
merged=$(git merge-base "$main" "$up") || die "retroheim/main and upstream share no history"
say "## Upstream drift"
say ""
say "- upstream: $UPSTREAM_URL ($head_branch at $up)"
say "- retroheim/main: $main (last upstream merged: $merged)"
say "- retroheim/main is **$behind** upstream commit(s) behind; it carries $ours commit(s) of ours"

if [ "$behind" -eq 0 ]; then
  say "- nothing to merge; no drift"
  exit 0
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/filmcraft-drift.XXXXXX") || die "cannot make a scratch directory"
cleanup() { git worktree remove --force "$scratch/wt" >/dev/null 2>&1; rm -rf "$scratch"; }
trap cleanup EXIT INT TERM

# Merge in memory: exit 0 is a clean merge (stdout is the tree), 1 is a conflict (the tree,
# then the conflicting paths), anything else is an error.
git merge-tree --write-tree --name-only "$main" "$up" >"$scratch/merge.out" 2>"$scratch/merge.err"
status=$?
if [ "$status" -eq 1 ]; then
  files=$(sed -n '2,/^$/p' "$scratch/merge.out" | sed '/^$/d; s/^/  - /')
  say "- merge: **CONFLICT** in $(printf '%s\n' "$files" | grep -c .) file(s):"
  say "$files"
  say "- action: merge upstream into a branch off retroheim/main, resolve, rerun the proofs, open a pull request"
  exit 1
elif [ "$status" -ne 0 ]; then
  die "git merge-tree failed: $(head -n 3 "$scratch/merge.err")"
fi
tree=$(head -n 1 "$scratch/merge.out")
say "- merge: clean"

if [ "${DRIFT_SKIP_TESTS:-0}" = 1 ]; then
  say "- tests: skipped"
  say "- action: merge upstream $up into a branch off retroheim/main, rerun the proofs, open a pull request"
  exit 1
fi
ident="-c user.name=drift-check -c user.email=drift-check@invalid"
# shellcheck disable=SC2086
commit=$(git $ident commit-tree "$tree" -p "$main" -p "$up" -m "drift check: merge upstream") || die "cannot record the merged tree"
git worktree add --quiet --detach "$scratch/wt" "$commit" || die "cannot create the scratch worktree"
args=""
for c in $CRATES; do args="$args -p $c"; done
# shellcheck disable=SC2086
if (cd "$scratch/wt" && cargo test --locked $args >"$scratch/test.log" 2>&1) ||
   (cd "$scratch/wt" && cargo test $args >"$scratch/test.log" 2>&1); then
  passed=$(grep -E '^test result: ok' "$scratch/test.log" | sed -E 's/.* ([0-9]+) passed.*/\1/' | awk '{n+=$1} END {print n+0}')
  say "- tests: **pass** ($passed tests across the eight crates)"
  say "- action: merge upstream $up into a branch off retroheim/main, rerun the proofs, open a pull request"
  exit 1
fi
say "- tests: **FAIL** on the merged result; last lines:"
say ""
say '```'
tail -n 25 "$scratch/test.log" | while IFS= read -r l; do say "$l"; done
say '```'
exit 1
