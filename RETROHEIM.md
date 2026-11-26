# RetroHeim fork of FilmCraft

Fork of https://github.com/storytold/filmcraft carrying a small set of patches.

- Ours: branch `retroheim/main` (the default branch) = upstream `main`, merged in regularly, plus
  the patches below, this file, `scripts/check-upstream-drift.sh` and
  `.github/workflows/upstream-drift.yml`.
- `retroheim/base` is the original fork point (upstream `98ba9acbcedcbb630ba2a07b782176b66835edd2`).
  It is history only and is no longer moved; the drift check does not use it.
- Licence: MIT OR Apache-2.0 as upstream. `LICENSE-MIT`, `LICENSE-APACHE` and `NOTICE` are untouched.
  Our changes are under the same terms.

## Upstream is read-only

We never write to any upstream repository (storytold/filmcraft, storytold/craft-libs or any other
storytold repository): no pull requests, issues, comments, reviews or pushes. We only fetch from
them. Every change lands here, through a pull request into `retroheim/main`. A fix that belongs in
upstream code is either carried in this fork or recorded under [Known gaps](#known-gaps).

## Patches

Carried in crates cfb (tests only), interchange, media and project. Drop each when upstream has
an equivalent fix.

1. Bound arithmetic and allocations driven by untrusted interchange input: AAF weak-collection key
   tables, sequential EDL overwrites in linear time, and no clip keeps a non-finite speed from a
   shared timeline reader (an FCPXML `timeMap` with two values at one time). The legacy in-repo
   FCPXML reader keeps its own time and time-map checks, but upstream now imports FCPXML through
   craft-timeline, so that reader only runs in comparison tests.
2. Make the thread-local draft and catch-up decode hints unwind-safe; refuse WAV bit depths the
   sample decoder cannot read (media).
3. Bound more hostile-input work: XML element nesting is checked before parsing (interchange);
   caption plain-text extraction and Find ordering stay linear in their input (project).
4. `OfflineSource` gets a real `audio_stream`: listed secondary audio streams of offline media are silence.

Upstream already has equivalents of, and so we no longer carry: the CFB sector-chain bounds (and
craft-cfb now also refuses non-standard sector sizes and a FAT sector listed twice) and the OMF
composition visit budget (craft-cfb and craft-aaf), cancellation-flag unwind safety
(craft-media-source), and the FCPXML nesting and layout depth limits (craft-timeline). Our
regression tests for these stay, run against upstream's code.

## Known gaps

Upstream moved the CFB, AAF, OMF and PCM-essence code into storytold/craft-libs. These fork fixes
were in that code and craft-libs does not have them. They are not carried (see above: upstream is
read-only, and we do not fork craft-libs). Recheck them whenever upstream bumps its craft-libs `rev`.

- craft-aaf `units_to_ticks`: the `length × rate denominator × ticks per second` product is
  unchecked `i128`. A hostile AAF `Length` near `i64::MAX` overflows it: a panic in debug builds,
  a wrong (still clamped) time in release.
- craft-aaf AAF writer: a CompositionMob id comes from a running counter, not from the edit, so two
  different edits of the same media can be written with the same MobID.
- craft-aaf Bento values are capped at 16 MiB, not at the length of the file that holds them.
- craft-audio `pcm_wav_header`: for absurd channel counts the byte rate is computed from the
  saturated 16-bit block size (no crash, an inexact header).

## Merging a newer upstream

```sh
git fetch https://github.com/storytold/filmcraft.git +refs/heads/main:refs/drift/upstream
git switch -c retroheim/merge-upstream-<short-sha> origin/retroheim/main
git merge refs/drift/upstream      # resolve conflicts, keeping the patches above
```

Then rerun the proofs against the result:

```sh
cargo test -p filmcraft-cfb -p filmcraft-color -p filmcraft-frame -p filmcraft-geom \
  -p filmcraft-interchange -p filmcraft-media -p filmcraft-project -p filmcraft-time
```

Push the branch and open a pull request into `retroheim/main`. Update the Patches and Known gaps
sections in the same pull request.

## Keeping it current

Upstream moves fast, so drift is checked weekly.

- `.github/workflows/upstream-drift.yml` runs Mondays 06:17 UTC and on manual dispatch. It adds
  public upstream as remote `upstream`, fetches its default branch, counts how far
  `retroheim/main` is behind, merges in memory (`git merge-tree`), runs the eight crates' tests on
  a clean merge in a scratch worktree, and writes the report to the run's job summary. Issues are
  disabled here, so the run fails while there is drift (GitHub emails the owner about a failed
  scheduled run) and passes once `retroheim/main` contains upstream. It never pushes. The only
  permission is `contents: read`; `actions/checkout` is pinned by commit SHA. Scheduled workflows
  only run from the default branch, so `retroheim/main` is the default branch.
- `scripts/check-upstream-drift.sh` does the same locally and leaves no remote behind
  (`DRIFT_SKIP_TESTS=1` skips tests, `DRIFT_REPORT=<file>` writes the markdown, `DRIFT_MAIN=<ref>`
  checks a branch other than `retroheim/main`). Exit 0 level, 1 drift, 2 could not run.
- Upstream's own workflows come along with the fork. They are not deleted on our branch, which
  would conflict on every merge; disable the ones that should not run here with
  `gh workflow disable <name>`.
