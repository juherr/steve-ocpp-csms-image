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
| `.github/workflows/build-image.yml` | Build & push to GHCR — see its `on:` block for the triggers |
| `.github/workflows/lint.yml` | hadolint / shellcheck / actionlint |
| `.github/workflows/scan-published.yml` | Weekly Trivy scan of the tags already on GHCR |
| `.github/workflows/release-drift.yml` | Schedules `hack/release-drift.sh` — see that script for what it compares |
| `hack/release-drift.sh` | Published image vs the `release` branch; runnable by hand |
| `README.md` | User-facing documentation |
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
and builds with `--network=host`, pointing `--build-arg DB_IP=127.0.0.1`.
BuildKit only accepts `host`, `none` or `default` for `--network`, so a
dedicated Docker network is **not** an option (the legacy builder that allowed
one is deprecated since Engine 23). Use `127.0.0.1`, never `localhost`: in the
host namespace `localhost` may resolve to `::1` first while MariaDB listens on
IPv4.

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
silently freezes. `customManagers[1]` deliberately matches every workflow, so a
linter or scanner added later is managed on arrival.

The SteVe release is pinned in exactly one place in code: `ARG STEVE_REF` in the
`Dockerfile`. Both the pull-request build and the release read it from there, so
the version a branch would ship and the version its build tests cannot disagree.
The examples in `README.md` are prose and must be edited by hand, as is the JRE
major, which `README.md` names under **Tags** — an `eclipse-temurin` bump has to
update that sentence too.

**Update `NOTICE` when the image composition changes.** The repository files are
Apache-2.0, but the produced image aggregates SteVe (GPL-3.0-or-later), the
Flyway CLI (Apache-2.0) and Temurin JREs (GPL-2.0 + Classpath Exception). Adding
or swapping a component changes the obligations.

## Deliberate choices — do not "improve" them

- **Manual `docker build` / `docker push`**, no `docker/metadata-action`, no
  `docker/build-push-action`, no `docker/setup-buildx-action`. Labels are in the
  `Dockerfile`, which keeps them identical for local and CI builds. Verified
  present on the published image — `metadata-action` would add a second source
  of truth for no gain.

  Note this is *not* "we avoid BuildKit": `docker build` on Engine 23+ already
  builds with BuildKit through the default `docker` driver. What is avoided is
  the `docker-container` driver that `setup-buildx-action` sets up, because the
  build needs `--network=host` to reach the throwaway MariaDB, and under that
  driver host networking means the buildkitd container's namespace and needs the
  `network.host` entitlement. The features it would unlock — multi-arch, and
  SBOM/provenance attestations attached to the image — are the ones already
  ruled out below.
- **Single architecture (`linux/amd64`).** Multi-arch would require QEMU plus a
  MariaDB reachable from each emulated build; not worth it today.
- **One tag per upstream release, `steve-X.Y.Z`.** No `latest`, no per-commit
  tag, and no JRE-suffixed variant: the JRE is a build detail, a bump is not a
  new SteVe release, and consumers pin by digest.
- **The image self-migrates at startup.** The build database is thrown away, so
  the runtime database starts empty and `entrypoint.sh` replays Flyway. This is
  idempotent — it is not redundant work.
- **`curl` is installed in the runtime stage** on purpose: the documented
  Compose healthcheck shells out to it, and CI asserts it is present.
- **Merging does not publish; pushing `release` does.** `git push origin
  main:release` is the release. The publish steps are guarded on
  `github.ref_name == 'release'`, so no other branch and no dispatch from
  elsewhere can ship. Restoring a `push:` trigger on `main` would republish
  `steve-X.Y.Z` under a new digest for a comment fixed in the `Dockerfile` —
  that is what it used to do.
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
- **No SBOM.** A `syft` SBOM was tried and removed: as a workflow artifact it
  expires and no consumer can discover it, and attaching it to the image needs
  buildx attestations. `NOTICE` covers the licence-aggregation need in the form
  a human actually reads.
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
commands here would only create a second version to keep in sync.

Build locally with the block under **Building locally** in `README.md`. It is
one copy of those commands on purpose: the README claims they are exactly what
CI runs, and a third copy here could only make that claim less true.

Then check what actually matters:

```bash
docker inspect steve:local --format '{{ json .Config.Labels }}' | jq .   # OCI labels, none empty
docker run --rm --entrypoint curl steve:local --version                  # healthcheck dependency
docker inspect steve:local --format '{{ .Config.User }}'                 # 10001:10001
```

Against the published image:

```bash
docker buildx imagetools inspect ghcr.io/juherr/steve:steve-3.13.0
```

When the image grows unexpectedly, the layer-by-layer breakdown — what each
instruction added, and how much of it is wasted because a later layer deleted
it — is a local question, not a CI one:

```bash
dive steve:local   # https://github.com/wagoodman/dive
```

A full run also means starting the container against a MariaDB and reaching
`http://127.0.0.1:8180/steve/manager/signin` — first boot runs the migrations
and takes up to ~150 s.

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
