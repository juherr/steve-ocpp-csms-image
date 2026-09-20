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
| `.github/workflows/lint.yml` | hadolint / `docker build --check` / shellcheck / actionlint / zizmor / kubeconform, the seven suites under `hack/test/`, `renovate-config-validator` and `hack/renovate-extract-check.sh` |
| `.github/workflows/scan-published.yml` | Weekly Trivy scan of the tags already on GHCR, one job per image `hack/scan-targets.sh` lists |
| `.github/workflows/release.yml` | The release, from the Actions tab: preflight, fast-forward `release`, start the build |
| `.github/workflows/release-drift.yml` | Schedules `hack/release-drift.sh` — see that script for what it compares |
| `.github/workflows/check-links.yml` | Schedules `hack/check-links.sh` weekly, report-only: a broken link is a warning and a step summary, never a red run |
| `hack/release-drift.sh` | Published image vs the `release` branch; runnable by hand |
| `hack/release-preflight.sh` | Would releasing HEAD publish anything, or only move a digest; runnable by hand |
| `hack/migration-test.sh` | Fresh-database migration, restart and upgrade scenarios against the built image; what CI runs after the build, runnable by hand |
| `hack/k8s-example-test.sh` | Applies `examples/kubernetes/` to a throwaway kind cluster, reads back what the Deployment declares (replicas, `Recreate`, security context, probe paths) and checks a pod comes up under it with the Secret reaching it; run by the amd64 build job on the image it built, runnable by hand against the published tag |
| `hack/image-config.sh` | Image config of a published tag, single manifest or index; what `release-drift.sh`, `release-preflight.sh`, the three scripts below, the build workflow and the `CLAUDE.md` recipe read through |
| `hack/scan-targets.sh` | The images `scan-published.yml` scans: one (tag, arch) per supported platform each of the newest tags carries; runnable by hand |
| `hack/check-pushed-digest.sh` | Is the digest a build job pushed the image it probed; run by each build job on `release` |
| `hack/publish-index.sh` | Checks the two platform digests and the index they would form, then makes the tag — the index annotated with the manifests' `description`, which is where GHCR reads a multi-arch package's description — and prints the digest to pin; run by the `publish` job on `release` |
| `hack/mirror-tag.sh` | Copies a published tag from GHCR to Docker Hub as it is — `crane copy`, same index digest on both — and reads it back; run by the `mirror` job on `release`, runnable by hand with a Docker Hub token |
| `hack/renovate-extract-check.sh` | Is every pin one Renovate extracts — the `# renovate:` comments, the Markdown examples and the example manifests; run by `lint.yml`, runnable by hand |
| `hack/lint.sh` | The steps of `lint.yml`, run locally — read out of the workflow, pins and commands, not copied from it |
| `hack/check-links.sh` | lychee over every tracked Markdown file and `NOTICE`; what `check-links.yml` runs, runnable by hand |
| `hack/test/` | Offline tests of the six scripts above that read the registry, against a fixture registry served by a `curl` shim and a `docker` that records instead of acting, of the mirror against a `docker` shim that answers crane's four commands from that registry, of the Renovate check against a saved extraction, of the README's `MaxRAMPercentage` against `entrypoint.sh`, of `hack/lint.sh` against a fixture workflow, and of `hack/check-links.sh` against a `docker` shim that replays lychee's exit codes — plus the step of `check-links.yml` that maps them to a verdict, run as written through `hack/lint.sh` |
| `README.md` | User-facing documentation |
| `examples/kubernetes/` | Reference `Deployment` + `Service` and their README — an example, not a chart; schema-checked by kubeconform in `lint.yml`, brought up in kind by `hack/k8s-example-test.sh` on every build |
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
`customManagers[2]` every Markdown file and every YAML under `examples/`, so a
linter, scanner, document or manifest added later is managed on arrival.
One pin is deliberately a major only: `RENOVATE_IMAGE` in `lint.yml`, the
image that validates `renovate.json` and runs the extraction check. It is a
tool of the pull request, not a component of the image, and a full pin meant
a PR per Renovate patch, several a week. `44` is still managed — Renovate
proposes `45` when it exists, and nothing below — and is not `latest`, which
tracks no release line. The tag moves, and `docker run` does not re-pull a
tag it already has: a runner pulls it fresh, a laptop needs
`docker pull renovate/renovate:44` to catch up.

The SteVe release is pinned in exactly one place in code: `ARG STEVE_REF` in the
`Dockerfile`. Both the pull-request build and the release read it from there, so
the version a branch would ship and the version its build tests cannot disagree.
`README.md` is the one document that names the release literally, because its
commands are meant to be pasted by someone who does not yet know which version
to ask for. Those examples are managed too and land in the same PR — prose has
no `# renovate:` comment to hang off, so `customManagers[2]` matches on the
literal `juherr/steve:` — bare, the Docker Hub form, or under `ghcr.io/` or
`docker.io/` — `STEVE_REF=` and `manifests/` forms. Keep those
shapes when editing a README example, or it leaves Renovate's reach; the third
form matches nothing today and is kept for the next document that uses it. The
`image:` line of `examples/kubernetes/deployment.yaml` is the same literal in
the first form, read by the same manager for the same reason: a manifest is
meant to be applied by someone who does not yet know which tag to ask for.
That directory is one `config:recommended` ignores — its `:ignoreModulesAndTests`
preset lists `**/examples/**` — so `renovate.json` restates `ignorePaths`
without it. Measured, not read: the manager matched the file and Renovate
still extracted nothing until the override, which is the case
`hack/renovate-extract-check.sh` exists to catch.

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
  The one exception is read, not written twice: GHCR takes a multi-arch
  package's description from the *index's* annotations, not from the
  platform manifests' labels, and the first multi-arch `steve-3.14.1` showed
  "No description provided" with the label present on both manifests
  (measured). `hack/publish-index.sh` therefore copies
  `org.opencontainers.image.description` from the manifests onto the index
  as an annotation — the `Dockerfile` stays the source, the index repeats it,
  and the two platforms have to agree on it or the release is refused.
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
- **Docker Hub is a mirror, GHCR the registry.** `docker.io/juherr/steve`
  carries every `steve-X.Y.Z` the multi-arch build publishes, as a copy of
  the GHCR index made after the tag exists there: `hack/mirror-tag.sh`, in a
  `mirror` job of `build-image.yml` that needs `publish` and runs only on
  `release`. Nothing is built for it and nothing reads it back into the
  release checks — `release-preflight.sh`, `release-drift.sh`,
  `scan-targets.sh` ask GHCR and nothing else. The copy is `crane copy`, not
  `docker buildx imagetools create`: the latter's sources "must already exist
  in the registry where the new manifest is created" (its reference), so it
  cannot cross registries; crane pushes the index and its manifests byte for
  byte, and the digest to pin is the same string on both registries
  (measured against two local `registry:2`, annotation included; a second
  copy is a no-op crane reports as "existing manifest"). The Docker Hub
  token lives in two repository secrets, `DOCKERHUB_USERNAME` and
  `DOCKERHUB_TOKEN`, reaches only that job — no image, no build, no GHCR
  write — and goes to `crane auth login --password-stdin` in a config
  directory the script makes and removes, never to `docker login`: the
  daemon never holds it, and on macOS Docker Desktop writes `credsStore`
  into whatever `DOCKER_CONFIG` it is given, which crane cannot read
  (measured). A failed mirror is a red release run, re-run alone with
  *Re-run failed jobs* — the outputs of `publish` survive, nothing rebuilds.
  No `latest` there either, and no Hub-side description: Docker Hub takes a
  repository's description from its settings, not from the image.
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
  Each supported platform a tag carries is scanned under its own category,
  `trivy-<tag>-<arch>`: Trivy on an index takes the runner's platform and
  never looks at the other. `hack/scan-targets.sh` asks the registry which of
  the two platforms the build produces a tag carries, rather than assuming
  both — on the single-manifest tags from before multi-arch, Trivy given
  `--platform linux/arm64` scans the amd64 image without a word (measured),
  and a fixed pair would file those findings under an `-arm64` category. A
  third architecture added to the build has to be added there too.
- **The documentation links are checked weekly, not on the pull request.**
  Same reasoning: a link works the day it is added and breaks months later,
  when the page it points at moves. `check-links.yml` runs
  `hack/check-links.sh` — lychee over every tracked Markdown file and
  `NOTICE`, so a document added later is checked on arrival — report-only: a
  broken link is a `::warning::` and the report in the step summary, never a
  red run. Not in `lint.yml`: it needs the network, and a pull-request gate
  that goes red for another site's outage is a gate people learn to scroll
  past. A lychee that could not check at all does fail the run — that is no
  answer, not a clean tree. The one redirect it reports today,
  `steve-community/steve.git` in `NOTICE`, is a clone URL and stays.
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

The linters are the cheap gate. `./hack/lint.sh` runs the steps of
`.github/workflows/lint.yml` — every job, or the ones named as arguments,
`-n` to list them — by reading them out of the workflow: that file pins the
images and holds the commands, so a copy here or in the script would only be
a second version to keep in sync, and the script has none. A step written in
a shape it does not read (`run: >`, a bare `run:`) is refused by line, not
skipped, and its suite parses the real file. zizmor is
the one that reads the workflows for what actionlint does not — pins,
permissions, template injection, checkouts that keep the token — and it
gates, offline: a finding fails the pull request, and a waiver is a comment
on the line that earned it, with its reason, as the `# hadolint ignore=`
ones are. Every checkout sets `persist-credentials: false` except the one in
`release.yml`, which says why it keeps them. Then the
seven suites under `hack/test/`, which are the whole test suite, no network:
`registry-readers.sh` for `image-config.sh`, the two release readers and
`scan-targets.sh`, `release-publish.sh` for the two scripts that run only on
`release` — `check-pushed-digest.sh` in each build job and `publish-index.sh`
in the `publish` job — `mirror-tag.sh` for the third, `hack/mirror-tag.sh` in
the `mirror` job, against a `docker` shim that answers crane's `manifest`,
`digest`, `copy` and `auth login` from the fixture registry and records
every invocation — the pinned image, the config mount, the token on stdin
and never on a command line — `renovate-extract.sh` for the Renovate check below,
against a saved extraction, `readme-entrypoint.sh`, which holds the
README's `-XX:MaxRAMPercentage` to the value `entrypoint.sh` sets — the one
runtime number the documentation quotes — and `lint-script.sh` for
`hack/lint.sh`, against a fixture workflow whose steps only echo, and
`check-links.sh` for `hack/check-links.sh`, against a `docker` shim that
records what lychee is handed and replays its exit codes — which files, which
image, mounted where, where the report goes, and that a lychee that could not
run is neither a clean tree nor a broken link — and, through `hack/lint.sh`
pointed at the real `check-links.yml`, the workflow step that turns those
codes into a verdict. The second
suite is the only recurring
coverage of the publish path, which no pull request exercises: a `docker`
shim records every `imagetools create -t`, and the suite proves that a
candidate failing a check never reaches one. A change to any of those eight
scripts is not verified until the suites pass; a new manifest shape goes in
as a fixture under `hack/test/registry/` first. What has no offline test is the push-by-digest
export itself — it needs buildx and a registry, and rests on the #27 spike
and a local `registry:2` run.

A change to a pin — or to a file holding one — is proven by making Renovate say
so, not by reading `renovate.json`. The file itself goes through
`renovate-config-validator --strict` first, from the same pinned image: a
regex that does not compile or a deprecated option fails there (the
`--strict` is what turns the latter from a warning into a failure, measured),
while a misspelled preset does not — presets are resolved online, at run
time. Then `hack/renovate-extract-check.sh` runs
Renovate's own image on the working directory — `--platform=local
--dry-run=extract` stops after the extraction phase: no datasource queried,
no branch, no PR, nothing written — and fails when a `# renovate:` comment is
not inside a `replaceString` of its file, or a Markdown file or example
manifest holds more SteVe tag literals in the shapes `renovate.json` declares
than Renovate extracted from it. `lint.yml` runs it on every pull request, so a
README edit that leaves a shape is red before it lands — and so was the
preset that ignored `examples/`, on the first run against the manifest; the
Renovate image is ~450 MB
(measured), the one pull in that workflow that is not seconds. A pin that
the check does not name is unmanaged, whatever the comment next to it says —
the Dockerfile `FROM` lines and the action SHAs are the built-in managers'
and are not counted. For which version each pin would move to, run Renovate
itself without `--dry-run=extract`: `--platform=local` then falls back to
its `dryRun=lookup` default, which queries the datasources — that one hits
github.com, so prefix it with `RENOVATE_GITHUB_COM_TOKEN="$(gh auth token)"`
to stay out of the rate limit.

```bash
./hack/renovate-extract-check.sh
```

The Kubernetes example is proven in two steps, neither of which is reading the
YAML. kubeconform, the exact command `lint.yml` runs, says the manifests are
valid against the API schemas; `hack/k8s-example-test.sh` says a pod actually
comes up under them — as `10001:10001`, root filesystem read-only and `/tmp`
writable, the Service reaching the pod, the Secret's three keys in the
container's environment with a database password that is *not* the compiled-in
default, so a Secret that stopped reaching the container fails Flyway rather
than falling through to `changeme` — in a throwaway
[kind](https://kind.sigs.k8s.io) cluster with an empty MariaDB started in it,
so the first-boot migration runs too. What a fresh deployment cannot exercise
is read back from the applied Deployment and compared with the example's
promises: one replica and `Recreate`, the security context, and the three
probe paths — any other path under `/steve/manager/` answers a 302 to the
sign-in page, which a Kubernetes HTTP probe counts as success (measured), so a
misspelt probe would come up green and prove nothing. The amd64 build job runs
it on the image it has just built, loaded into the cluster rather than pulled:
for a tag not yet published that image is the only one there is. By hand,
without an argument, it applies the manifest as published and the cluster
pulls the tag it names; the cluster gets its own kubeconfig, and your current
context is neither read nor changed:

```bash
./hack/k8s-example-test.sh                 # the published tag the manifest names
./hack/k8s-example-test.sh steve:local     # an image from the daemon, as CI does
```

A change under `examples/kubernetes/` or to the script therefore triggers the
image build on a pull request — the test needs an image, and the one the pull
request builds is the one it should run against. The upgrade scenario is not in
the script: `Recreate` was measured by hand — the previous published tag
applied first, `kubectl set image deployment/steve steve=ghcr.io/juherr/steve:<tag>`
after, the `Migrating schema` lines in the new pod's log — and stays a hand
check until it proves necessary in CI. On Apple Silicon a tag from before the
multi-arch build runs emulated in kind — ~130 s to ready, measured — which is
what the `startupProbe` budget is sized for.

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

And the Docker Hub mirror of that tag, which must print the same index
digest — one `Digest:` line on each side, equal, is the whole proof:

```bash
docker buildx imagetools inspect "$REF" --format '{{ .Manifest.Digest }}'
docker buildx imagetools inspect "docker.io/${REF#ghcr.io/}" --format '{{ .Manifest.Digest }}'
```

A change to `hack/mirror-tag.sh` is proven by its suite, then by running it
against a published tag with a Docker Hub token of your own — it copies
nothing new when the mirror already holds the index, and still reads it
back. The `mirror` job itself is proven by nothing but the next release.

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
