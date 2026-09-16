# Agent instructions

Instructions for LLM agents working on this repository. Read this before
changing anything; the constraints below are load-bearing and several of them
look like defects until you know why they exist.

## What this repository is

Packaging only. It builds a ready-to-run Docker image of
[SteVe](https://github.com/steve-community/steve) (an OCPP Central System) and
publishes it to `ghcr.io/juherr/steve`.

**There is no application source here.** SteVe is cloned at build time from an
unmodified upstream release tag. Never vendor, patch or fork upstream code in
this repository — if something must change in SteVe, it changes upstream.

| Path | Role |
| --- | --- |
| `Dockerfile` | 3 stages: build the `.war`, extract the Flyway CLI, assemble the runtime image |
| `entrypoint.sh` | Runs Flyway migrations against the runtime database, then starts the `.war` |
| `flyway-callbacks/afterConnect.sql` | Forces `default_storage_engine=InnoDB`; replaces `-initSql`, removed in Flyway 13 |
| `.github/workflows/build-image.yml` | One native build and probe per architecture, merged into an index on `release` — see its `on:` block for the triggers |
| `.github/workflows/lint.yml` | hadolint / shellcheck / actionlint, and the two suites under `hack/test/` |
| `.github/workflows/scan-published.yml` | Weekly Trivy scan of the tags already on GHCR, each platform separately |
| `.github/workflows/release.yml` | The release, from the Actions tab: preflight, fast-forward `release`, start the build |
| `.github/workflows/release-drift.yml` | Schedules `hack/release-drift.sh` — see that script for what it compares |
| `hack/release-drift.sh` | Published image vs the `release` branch; runnable by hand |
| `hack/release-preflight.sh` | Would releasing HEAD publish anything, or only move a digest; runnable by hand |
| `hack/migration-test.sh` | Fresh-database migration, restart and upgrade scenarios against the built image; what CI runs after the build, runnable by hand |
| `hack/image-config.sh` | Image config of a published tag, single manifest or index; what `release-drift.sh`, `release-preflight.sh`, the two scripts below, both workflows that ask for one platform and the `CLAUDE.md` recipe read through |
| `hack/check-pushed-digest.sh` | Is the digest a build job pushed the image it probed; run by each build job on `release` |
| `hack/publish-index.sh` | Checks the two platform digests and the index they would form, then makes the tag and prints the digest to pin; run by the `publish` job on `release` |
| `hack/test/` | Offline tests of the five scripts above that read the registry, against a fixture registry served by a `curl` shim and a `docker` that records instead of acting |
| `README.md` | User-facing documentation |
| `.github/assets/` | Images referenced by `README.md`; outside the build context |
| `NOTICE` | License aggregation of the produced image — must stay accurate |
| `renovate.json` | Dependency pinning automation |

## Invariants

**Never bake a secret into the image.** SteVe is a Spring Boot application:
`DB_PASSWORD`, `AUTH_PASSWORD`, `DB_IP`… are resolved from the environment at
runtime and override the compiled-in `application-docker.properties` defaults.
Those defaults (`changeme`, `admin`, `1234`) are upstream *public placeholders*,
not secrets — do not treat their presence as a vulnerability, and do not try to
"fix" them by adding build args or files.

**The build needs a live MariaDB.** jOOQ code generation and Flyway both read a
real schema during `mvn package`. CI starts a throwaway MariaDB publishing 3306
on **each** runner and builds through a `docker-container` builder created with
`--driver-opt network=host`, pointing `--build-arg DB_IP=127.0.0.1`: buildkitd
itself sits on the runner's network, so the `RUN` steps reach the database with
no `--network` flag and no entitlement. The alternative that looks equivalent
is not: the `network.host` entitlement plus `--network=host` puts the `RUN`
steps in the buildkitd *container's* namespace, and Maven got "connection
refused" on 127.0.0.1 on both runners (measured, #27). A dedicated Docker
network was never an option with the default driver (BuildKit accepts only
`host`, `none` or `default` for `--network`) and has not been measured with
the container driver — do not claim it either way. Use `127.0.0.1`, never
`localhost`: on the host network `localhost` may resolve to `::1` first while
MariaDB listens on IPv4.

**OCI labels must keep reaching the final image.** The
`org.opencontainers.image.*` labels live in the `Dockerfile` runtime stage, and
`created` / `revision` come from `--build-arg BUILD_DATE` / `VCS_REF` supplied
by the workflow. Drop those build args and the labels silently become empty;
drop the `LABEL` lines and the image inherits the *base image's* labels, which
describe Temurin, not this build. `org.opencontainers.image.source` must stay
exactly `https://github.com/juherr/steve-ocpp-csms-image` — GHCR uses it to
attach the package to this repository.

**The runtime stage runs as UID/GID `10001`.** Anything needing root must happen
before the `USER` instruction.

**Keep versions pinned, and keep every pin *managed*.** Base images are pinned
by tag, GitHub Actions by commit SHA, and `# renovate:` comments drive the
updates. A comment adjacent to the pin is not enough — check that
`renovate.json` actually covers the file, otherwise the pin looks maintained and
silently freezes. `customManagers[1]` deliberately matches every workflow and
`customManagers[2]` every Markdown file, so a linter, scanner or document added
later is managed on arrival.

The SteVe release is pinned in exactly one place in code: `ARG STEVE_REF` in the
`Dockerfile`. Both the pull-request build and the release read it from there, so
the version a branch would ship and the version its build tests cannot disagree.
`README.md` is the one document that names the release literally, because its
commands are meant to be pasted by someone who does not yet know which version
to ask for. Those examples are managed too and land in the same PR — prose has
no `# renovate:` comment to hang off, so `customManagers[2]` matches on the
literal `ghcr.io/juherr/steve:`, `STEVE_REF=` and `manifests/` forms. Keep those
shapes when editing a README example, or it leaves Renovate's reach; the third
form matches nothing today and is kept for the next document that uses it.

This file and `CLAUDE.md` read the tag out of the pin instead —
`$(sed -n 's/^ARG STEVE_REF=//p' Dockerfile)`. Their reader has the repository
in hand, so a literal here would only be a fourth copy of the one pin, right up
until it described a tag the tree no longer ships. Illustrations naming no real
tag say `steve-X.Y.Z` and are matched by nothing, deliberately.

The JRE major is the one version mention Renovate does not own: `README.md`
names it under **Tags**, so an `eclipse-temurin` bump has to update that
sentence by hand.

**Update `NOTICE` when the image composition changes.** The repository files are
Apache-2.0, but the produced image aggregates SteVe (GPL-3.0-or-later), the
Flyway CLI (Apache-2.0) and Temurin JREs (GPL-2.0 + Classpath Exception). Adding
or swapping a component changes the obligations.

## Deliberate choices — do not "improve" them

- **Manual `docker buildx build` / `imagetools create`**, no
  `docker/metadata-action`, no `docker/build-push-action`, no
  `docker/setup-buildx-action`. Labels are in the `Dockerfile`, which keeps
  them identical for local and CI builds. Verified present on the published
  image — `metadata-action` would add a second source of truth for no gain.
  The builder is one `docker buildx create` line, the same one the README
  runs locally; `setup-buildx-action` would create it with a different
  network, and its documented way to host networking is the entitlement that
  was measured to be the wrong namespace.

  A `docker-container` builder *is* used — one created on the host network,
  see the invariant above — because the default `docker` driver refuses
  push-by-digest, and pushing each architecture by digest is what lets one tag
  be assembled from two runners. Of the features that driver unlocks,
  multi-arch is now taken; attestations remain ruled out: the export passes
  `--provenance=false`, without which each pushed platform digest is itself a
  small index and the merged tag shows two `unknown/unknown` entries next to
  the platforms (measured).
- **Two architectures, built natively, merged into one index.** `linux/amd64`
  on `ubuntu-latest`, `linux/arm64` on `ubuntu-24.04-arm`, each job with its
  own throwaway MariaDB, build and probes; on `release` each pushes its image
  by digest and a `publish` job merges the two with `docker buildx imagetools
  create`. Route B of #27, measured against route A (a container-driver build
  with QEMU emulating only the runtime stage): A is one job instead of two,
  but Maven, jOOQ and the migration scenarios never run on arm64 under it, and
  an arm64 breakage would not fail a pull request. B costs two MariaDBs, two
  builds of ~3–4 min running in parallel — the wall-clock of the old single
  job — and a merge job of seconds. Each job builds once with `--load`,
  probes that image, then exports the *same* build by digest — a cache hit of
  seconds, and checked: the layers of the pushed manifest must be the probed
  image's, read back through `hack/image-config.sh`. The buildkit image the
  builder pulls is not pinned, like the runner's Engine and buildx: a build
  tool, not a component of the image.
- **One tag per upstream release, `steve-X.Y.Z`.** No `latest`, no per-commit
  tag, no per-architecture tag, and no JRE-suffixed variant: the JRE is a
  build detail, a bump is not a new SteVe release, and consumers pin by
  digest — the index's, which the `publish` job prints.
- **The image self-migrates at startup.** The build database is thrown away, so
  the runtime database starts empty and `entrypoint.sh` replays Flyway. This is
  idempotent — it is not redundant work. CI proves it on every build, on each
  architecture natively, with `hack/migration-test.sh`: an empty MariaDB, then
  a second container on the same schema, then the schema written by the
  previous published release. The build database would prove nothing there —
  Maven has already migrated it. The upgrade scenario asks
  `hack/image-config.sh` for the runner's own architecture first, and is
  skipped with a notice on a runner the previous tag was never built for —
  the arm64 job of the first multi-arch release, and nothing after it.
- **`curl` is installed in the runtime stage** on purpose: the documented
  Compose healthcheck shells out to it, and CI asserts it is present.
- **Merging does not publish; moving `release` does.** Either `git push origin
  main:release`, or the `Release` workflow from the Actions tab, which performs
  that same push. The publish steps are guarded on `github.ref_name ==
  'release'`, so no other branch and no dispatch from elsewhere can ship.
  Restoring a `push:` trigger on `main` would republish `steve-X.Y.Z` under a
  new digest for a comment fixed in the `Dockerfile` — that is what it used to
  do.
- **`release.yml` moves the branch; it does not become a second way to ship.**
  It exists so that releasing needs no terminal. It carries **no version input**
  — the version is read from `ARG STEVE_REF` at dispatch time, and an input
  would duplicate the pin the `Dockerfile` owns, which is the thing that was
  ruled out, rather than buttons as such. It dispatches `build-image.yml`
  explicitly instead of relying on its `push:` trigger because a push made with
  `GITHUB_TOKEN` does not start a workflow run — `workflow_dispatch` is one of
  the two documented exceptions, which is also why no PAT is needed here. Do not
  "simplify" this into a `workflow_call` of `build-image.yml`: that would mean
  replacing the `ref_name == 'release'` guard with an input, and that guard is
  the invariant.
- **`release-drift.yml` answers the one question git cannot.** The branch
  records what was *meant* to ship; the registry label records what actually
  did. A build that fails after `release` moved leaves the branch claiming a
  release that never landed, and `git log release..main` would then say
  "nothing pending" — a silent wrong answer. Do not delete this workflow on the
  grounds that the branch already tells you.
- **Trivy runs weekly on the published tags, not during the build.** An image is
  clean the day it is built and says nothing about the day after; the question
  worth answering is whether a *published* tag has drifted. It is report-only
  (`--exit-code 0`) — upstream CVEs are not this repository's to fix, and
  failing would only block a release no worse than what is already out there.
  Each platform of a tag is scanned under its own category,
  `trivy-<tag>-<arch>`: Trivy on an index takes the runner's platform and
  never looks at the other. Which platforms a tag carries is asked to the
  registry through `hack/image-config.sh`, not fixed to the two the build
  produces — on the single-manifest tags from before multi-arch, Trivy given
  `--platform linux/arm64` scans the amd64 image without a word (measured),
  and a fixed pair would file those findings under an `-arm64` category.
- **No SBOM.** A `syft` SBOM was tried and removed: as a workflow artifact it
  expires and no consumer can discover it, and attaching it to the image needs
  buildx attestations — the `--provenance=false` on the export is the same
  decision. `NOTICE` covers the licence-aggregation need in the form a human
  actually reads.
- **No `dive` step.** It cannot fail (its efficiency thresholds are not a
  contract worth holding this image to), so in CI it decides nothing. It is a
  local investigation tool — the command is under "Verifying a change".

## Verifying a change

**Check with the credentials the target will have, not the ones you happen to
hold.** `scan-published.yml` discovers its tags from the GHCR registry rather
than from `/users/juherr/packages/container/steve/versions`, because that REST
endpoint is scoped to the user account. It was once "verified" locally with a
personal token that happened to carry `read:packages` — which said nothing about
the workflow, whose `GITHUB_TOKEN` is issued for the repository. The registry
answers the same question with no credentials at all, the package being public,
so the question stops arising; it has no pagination trap either.

Keep that narrow. `GITHUB_TOKEN` reaches GHCR perfectly well — `build-image.yml`
logs in with it and pushes — and the runner has Docker. The gap was one REST
endpoint's scope, not a general tier difference, which is the point: check the
specific permission instead of assuming a tier in either direction. The `gh` and
`curl` recipes in `CLAUDE.md` inspect what is already published, and there your
own credentials are the right ones.

The same asymmetry catches the **shell**. CI runs `bash`; an interactive macOS
terminal is usually `zsh`, which does not word-split unquoted variables. A check
retyped from `release-drift.yml` into a zsh prompt once passed while filtering
on a single path that does not exist, reporting "in sync" when the trees
differed. Two habits close it: run scripts through their shebang rather than
pasting their contents (`./hack/release-drift.sh`, not a copy of its body), and
prefer arrays to space-separated strings when a command takes a path list.

The linters are the cheap gate. Run the three steps of
`.github/workflows/lint.yml` — that file pins the images, so copying the
commands here would only create a second version to keep in sync — and the
two suites under `hack/test/`, which are the whole test suite, no network:
`registry-readers.sh` for `image-config.sh` and the two release readers, and
`release-publish.sh` for the two scripts that run only on `release` —
`check-pushed-digest.sh` in each build job and `publish-index.sh` in the
`publish` job. The second suite is the only recurring coverage of the
publish path, which no pull request exercises: a `docker` shim records every
`imagetools create -t`, and the suite proves that a candidate failing a check
never reaches one. A change to any of those five scripts is not verified
until both suites pass; a new manifest shape goes in as a fixture under
`hack/test/registry/` first. What has no offline test is the push-by-digest
export itself — it needs buildx and a registry, and rests on the #27 spike
and a local `registry:2` run.

A change to a pin — or to a file holding one — is proven by making Renovate say
so, not by reading `renovate.json`. `--platform=local` runs on the working
directory, and `--dry-run=extract` stops after the extraction phase: no
datasource queried, no branch, no PR, nothing written.

```bash
LOG_LEVEL=debug npx --yes renovate --platform=local --dry-run=extract \
  | grep -E '"(packageFile|replaceString)"'
```

Every pin must appear as a `replaceString` under its `packageFile`; a pin that
is missing there is unmanaged, whatever the comment next to it says. Drop
`--dry-run=extract` and `--platform=local` falls back to its `dryRun=lookup`
default, which also queries the datasources and says which version each pin
would move to — that one hits github.com, so prefix it with
`RENOVATE_GITHUB_COM_TOKEN="$(gh auth token)"` to stay out of the rate limit.

Build locally with the block under **Building locally** in `README.md`. It is
one copy of those commands on purpose: the README claims they are exactly what
CI runs, and a third copy here could only make that claim less true.

Then check what actually matters:

```bash
docker inspect steve:local --format '{{ json .Config.Labels }}' | jq .   # OCI labels, none empty
docker run --rm --entrypoint curl steve:local --version                  # healthcheck dependency
docker inspect steve:local --format '{{ .Config.User }}'                 # 10001:10001
```

Those three read the image `--load` put in the daemon, which is the one the
probes ran against; `docker buildx rm steve-builder` afterwards, or the next
run of the README block fails on the name.

Against the published image — an index of exactly two entries, `linux/amd64`
and `linux/arm64`, and the labels of each platform manifest:

```bash
REF="ghcr.io/juherr/steve:$(sed -n 's/^ARG STEVE_REF=//p' Dockerfile)"
docker buildx imagetools inspect "$REF"
docker buildx imagetools inspect "$REF" --format '{{ json .Image }}' | jq 'map_values(.config.Labels)'
```

When the image grows unexpectedly, the layer-by-layer breakdown — what each
instruction added, and how much of it is wasted because a later layer deleted
it — is a local question, not a CI one:

```bash
dive steve:local   # https://github.com/wagoodman/dive
```

Then the runtime scenarios, exactly as CI runs them after its build: an empty
MariaDB is migrated, a second container reuses the migrated schema, and the
upgrade scenario starts a second empty MariaDB for the previous release to
write first. A container is healthy when the README's own healthcheck command
says so:

```bash
./hack/migration-test.sh steve:local
```

A second argument runs the upgrade scenario too. CI resolves it as the highest
published tag strictly below `ARG STEVE_REF`; by hand, pass any published tag
(`gh api /users/juherr/packages/container/steve/versions` lists them). A change
to the script is proven by running it — against `steve:local`, or against a
published tag when the change does not need a fresh build. On an emulated
architecture each boot takes ~100 s, so a full run is several minutes.

## Known state — do not re-diagnose

The GHCR package is linked to this repository and appears under its *Packages*
section. That link was established manually once, in the package settings; GHCR
only resolves `org.opencontainers.image.source` automatically when it **creates**
a package, and no REST endpoint re-links an existing one. So if the link ever
disappears, the fix is the *Connect repository* button — not a change to the
labels, the workflow or the `Dockerfile`. Check with:

```bash
gh api /users/juherr/packages/container/steve --jq .repository.full_name
```

## Conventions

- English for code, comments, documentation, commit messages and PR text.
- Conventional Commits.
- Comments explain **why**, not what. The existing files set the bar: match
  their density and tone rather than adding narration.
- Keep `README.md` and this file in sync with the workflow — the README claims
  its commands are exactly what CI runs.
