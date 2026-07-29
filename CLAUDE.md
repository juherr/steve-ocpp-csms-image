# CLAUDE.md

@AGENTS.md

The file above holds the project rules and applies in full. What follows is
specific to Claude Code.

## Language

Discussion, explanations and reviews in French. Everything written to the
repository — code, comments, documentation, commit messages, PR titles and
descriptions — in English.

## Verification has a real cost here

There is no test suite. The only meaningful check is a full `docker build`,
which clones SteVe and runs Maven against a live MariaDB: ~2 min on CI, longer
locally. So:

- Never claim a change to the `Dockerfile` or the workflow is "verified" without
  having actually built. Say what you ran and what you did not.
- A build that fails with a connection error to `127.0.0.1:3306` means the
  throwaway MariaDB is missing or not ready — start it first, it is not a
  regression in the change under review.
- For label-only changes, inspecting `.Config.Labels` on the built image is the
  proof; reading the `Dockerfile` is not.

The rule extends to claims *about the tools themselves*. Comments and
documentation here assert how hadolint, Trivy, Renovate, BuildKit or GHCR
behave, and those assertions get believed and built on. Run the thing before
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
TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:juherr/steve:pull&service=ghcr.io" | jq -r .token)
CFG=$(curl -s -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
  https://ghcr.io/v2/juherr/steve/manifests/steve-3.13.0 | jq -r .config.digest)
curl -sL -H "Authorization: Bearer $TOKEN" "https://ghcr.io/v2/juherr/steve/blobs/$CFG" | jq '.config.Labels'
```

## Tooling

No code-intelligence server on this repository. There is no application source
to index — the tracked files are a `Dockerfile`, one shell script, one SQL
callback and the workflows — so symbol-level tools have nothing to say here.
Use the native file and search tools.

## Scope

Pushing to `main` publishes to GHCR: the `push` trigger fires on the packaging
files and overwrites the release tags. Treat any commit touching `Dockerfile`,
`entrypoint.sh`, `flyway-callbacks/` or the workflow as a release, and confirm
before pushing.
