# CLAUDE.md

@AGENTS.md

The file above holds the project rules and applies in full. What follows is
specific to Claude Code.

## Language

Discussion, explanations and reviews in French. Everything written to the
repository — code, comments, documentation, commit messages, PR titles and
descriptions — in English.

## Verification has a real cost here

The unit tests are the four suites under `hack/test/`, and they cover the
scripts that read the registry — including the two that run only on
`release` — the Renovate check, and the README's `MaxRAMPercentage` against
`entrypoint.sh`, alone, offline — against fixtures for the first three. For
the image itself the meaningful checks are a full build, which clones SteVe
and runs Maven against a live MariaDB (~2 min on CI, once per architecture,
longer locally), and
`hack/migration-test.sh` on the result, which boots the image against an empty
MariaDB, boots it again on the schema that left behind, and — given a previous
release as second argument — on a schema that release wrote. So:

- Never claim a change to the `Dockerfile` or the workflow is "verified" without
  having actually built. Say what you ran and what you did not — and on which
  architecture: a pull request builds both, a laptop builds one.
- A build that fails with a connection error to `127.0.0.1:3306` means the
  throwaway MariaDB is missing or not ready — start it first, it is not a
  regression in the change under review. `push-by-digest is currently not
  implemented for docker driver` means the `--builder` was dropped and the
  build went to the daemon's default builder — same category.
- The push-by-digest export and the index publication run only on `release`.
  A pull request proves the builds and the probes on both runners, and
  `hack/test/release-publish.sh` proves the checks around the export and the
  tag; the export itself is proven by nothing but the spike and the next
  release. Say which of the three a change touched rather than calling the
  workflow verified.
- For label-only changes, inspecting `.Config.Labels` on the built image is the
  proof; reading the `Dockerfile` is not.
- For a change to `hack/migration-test.sh`, running it is the proof — against a
  published tag when the change does not need a fresh build, which skips the
  Maven cost entirely.

The rule extends to claims *about the tools themselves*. Comments and
documentation here assert how hadolint, zizmor, Trivy, Renovate, BuildKit or
GHCR behave, and those assertions get believed and built on. Run the thing before
writing the sentence. Two comments in this repository were written from
plausible reasoning and turned out false when measured — one claiming Trivy's
secret scanner reads deleted layers, one describing the build as avoiding
BuildKit. Where a claim was measured, the comment says so; keep that habit.

## Inspecting the published image and package

`gh` is authenticated, and the GHCR package is public, so the registry can be
queried directly rather than reasoned about:

```bash
gh api /users/juherr/packages/container/steve --jq '{repo: .repository.full_name, versions: .version_count}'
gh api /users/juherr/packages/container/steve/versions --jq '.[] | [.created_at, (.metadata.container.tags | join(","))] | @tsv'
gh run list --limit 10
```

Reading the labels of a published tag without pulling it:

```bash
TAG=$(sed -n 's/^ARG STEVE_REF=//p' Dockerfile)   # or any tag already published
./hack/image-config.sh "$TAG" | jq '.config.Labels'
```

The helper walks an image index down to its `linux/amd64` manifest, so this
reads the labels whether the tag is a single manifest or an index;
`REGISTRY_REPO=` points it at another package. It is the same code path
`release-preflight.sh` and `release-drift.sh` read through — do not retype its
`curl` calls into a recipe of their own.

## Tooling

No code-intelligence server on this repository. There is no application source
to index — the tracked files are a `Dockerfile`, one shell script, one SQL
callback and the workflows — so symbol-level tools have nothing to say here.
Use the native file and search tools.

## Scope

Merging no longer publishes. Pushing a branch and opening a PR is safe;
**moving `release` is the release** and overwrites
`ghcr.io/juherr/steve:steve-X.Y.Z` for every consumer. Two ways in, same act and
same caution: `git push origin main:release`, or `gh workflow run release.yml
--ref main`, which is the terminal-free path the Actions tab offers. Never do
either unless asked for a release in so many words — "merge this" is not that.

`hack/release-preflight.sh` refuses the case that used to be silent — the tag is
already published and the packaging has not moved, so shipping would only swap
the digest under consumers. It gates rather than reports, so it fails closed:
run it by hand before answering "is there anything to ship?" rather than
reasoning from `git log`, which cannot see that the image would be identical.

After merging anything under `Dockerfile`, `.dockerignore`, `entrypoint.sh` or
`flyway-callbacks/`, say plainly that the change is merged but not shipped, and
what would ship it. Do not let it pass silently: `release-drift.yml` reports it
too, but only as a step-summary note.
