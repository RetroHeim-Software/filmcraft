# RetroHeim fork of FilmCraft

Fork of https://github.com/storytold/filmcraft carrying a small set of patches, so downstream
projects can depend on the patched crates by commit SHA.

- Base: upstream `98ba9acbcedcbb630ba2a07b782176b66835edd2` (branch `retroheim/base`, no changes).
- Ours: branch `retroheim/main` = base + four patch commits, then this file, `scripts/check-upstream-drift.sh` and `.github/workflows/upstream-drift.yml`.
- Licence: MIT OR Apache-2.0 as upstream. `LICENSE-MIT`, `LICENSE-APACHE` and `NOTICE` are untouched.
  Our changes are under the same terms.

## Patches (one commit each, only crates cfb, color, frame, geom, interchange, media, project, time)

1. Bound arithmetic and allocations driven by untrusted interchange input (aaf, common, fcpxml, omf, wav).
2. Make thread-local decode hints unwind-safe; reject a zero WAV sample rate (media).
3. Bound more hostile-input work in the interchange readers; make the time math total.
4. `OfflineSource` gets a real `audio_stream`: listed secondary audio streams of offline media are silence.

Drop each when upstream has an equivalent fix.

## Rebasing onto a newer upstream

```sh
git remote add upstream https://github.com/storytold/filmcraft.git
git fetch upstream
git checkout retroheim/main
git rebase <new-upstream-sha>      # resolve patch conflicts commit by commit
```

Then rerun the proofs against the result:

```sh
cargo test -p filmcraft-cfb -p filmcraft-color -p filmcraft-frame -p filmcraft-geom \
  -p filmcraft-interchange -p filmcraft-media -p filmcraft-project -p filmcraft-time
```

Move `retroheim/base` to the new upstream SHA and push both branches. Downstream projects
pin `retroheim/main` by SHA and bump it themselves.

## Keeping it current

Upstream moves fast, so drift is checked weekly.

- `.github/workflows/upstream-drift.yml` runs Mondays 06:17 UTC and on manual dispatch. It adds public upstream as remote
  `upstream`, fetches its default branch, counts how far `retroheim/base` is behind, tries to rebase `retroheim/main`
  in a scratch worktree, runs the eight crates' tests on the result, and opens or updates one issue titled
  "Upstream drift" (conflicting patch, commit count, test result). It closes the issue once the base is level.
  It never pushes. Permissions are `contents: read` and `issues: write` on the default `GITHUB_TOKEN`;
  `actions/checkout` is pinned by commit SHA. Scheduled workflows only run from the default branch, so
  `retroheim/main` is the default branch.
- `scripts/check-upstream-drift.sh` does the same locally and leaves no remote behind (`DRIFT_SKIP_TESTS=1` skips tests,
  `DRIFT_REPORT=<file>` writes the markdown). Exit 0 level, 1 drift, 2 could not run.
- Upstream's own workflows (nightly FreeBSD, weekly Windows ARM64, release packaging) come along with the fork
  and stay disabled here (`gh workflow disable <name>`); they are not deleted on our branch, which would
  conflict on every rebase.
