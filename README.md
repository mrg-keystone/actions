# mrg-keystone/actions

Reusable GitHub Actions workflows for the org.

| workflow | for | used by |
|---|---|---|
| `jsr-publish` | Deno packages → JSR | keep |
| `gh-release` | binaries / skills / installers → GitHub Releases | rune, keep (skill) |

## gh-release

Resolve the release for the pushed ref, ensure rolling releases exist
(**never** delete them — delete-then-recreate leaves a window where
installers 404), gather build artifacts + skill tarballs + extra assets, and
publish everything in **one** upload (parallel uploads of the same asset
name from matrix legs race).

Deploy model: push to `main` → rolling `latest` (make_latest, the canonical
install target); push to `develop` → rolling `develop` (never latest); push
a `v*` tag → pinned snapshot (never latest); anything else errors unless
`tag` is passed.

```yaml
jobs:
  build:
    strategy:
      matrix: { include: [...] }
    steps:
      - # compile, sign, tar, shasum ...
      - uses: actions/upload-artifact@v4
        with:
          name: release-${{ matrix.target }}
          path: "*.tar.gz*"
  release:
    needs: [build]
    uses: mrg-keystone/actions/.github/workflows/gh-release.yml@main
    permissions:
      contents: write
    with:
      artifact-pattern: release-*
      extra-assets: |
        scripts/install.sh
```

Inputs: `artifact-pattern` (download-artifact pattern; empty = none),
`extra-assets` (newline globs from the caller checkout), `pack-skills`
(default true: each `skills/<name>/` → `<name>-skill.tar.gz`), `tag`
(explicit override), `main-branch`/`develop-branch`, `dry-run`.
Outputs: `tag`, `make-latest`.

## jsr-publish

Push to main → validate → settle in-flight publishes → compute the next
version → bump if needed → publish to JSR, **watched against the registry
instead of trusting `deno publish` to terminate**.

### Usage

```yaml
# .github/workflows/publish.yml in your package repo
name: Publish to JSR
on:
  push:
    branches: [main]
permissions:
  contents: write          # the auto-bump commits back to main
jobs:
  publish:
    uses: mrg-keystone/actions/.github/workflows/jsr-publish.yml@main
    secrets:
      JSR_TOKEN: ${{ secrets.JSR_TOKEN }}
```

Scope and package come from `deno.json`'s `name`. Set the version yourself in
`deno.json` for a deliberate cut — it publishes as-is when it isn't on JSR
yet. Otherwise the next version derives from the latest **published** version
plus the pushed commit messages: `feat:` → minor, `type!:` / `BREAKING
CHANGE` → major, else patch; the bump is committed back so the repo never
drifts from JSR.

### Inputs

| input | default | notes |
|---|---|---|
| `working-directory` | `.` | directory containing deno.json (monorepos) |
| `dry-run` | `false` | validate + compute the version, publish nothing |
| `timeout-minutes` | `50` | hard cap for the job |
| `publish-timeout-seconds` | `2400` | registry-watch window (see below) |
| `deno-version` | `v2.x` | denoland/setup-deno spec |
| `allow-slow-types` | `true` | pass `--allow-slow-types` |
| `bump-commit` | `true` | commit the auto-bump back to the branch |
| `refresh-latest` | `""` | JSR packages to repin to latest before publishing (see below) |

Outputs: `version`, `bumped`.

### Tracking a dependency's latest (`refresh-latest`)

Pass a whitespace/newline-separated list of JSR packages and each cut repins
them to their newest published version — across `deno.json` **and** every
workspace member — *before* the version is computed and the package is
published:

```yaml
jobs:
  publish:
    uses: mrg-keystone/actions/.github/workflows/jsr-publish.yml@main
    secrets:
      JSR_TOKEN: ${{ secrets.JSR_TOKEN }}
    with:
      refresh-latest: "@mrg-keystone/rune"
```

The repin happens in the same checkout, so it ships in the same tarball and
rides the same `release: vX (auto-bump)` commit — no second run, and no
reliance on a CI push re-triggering `on: push` (a `GITHUB_TOKEN` push does
not). It rewrites raw text (comments/formatting survive) and matches every
import whose value targets the package, whatever the map key — a bare
`@scope/pkg` or an aliased subpath like `#assert` → `.../pkg@X/assert`. A
no-op when everything is already at its latest floor, so nothing is committed
or published unless a tracked dep actually moved. `latestVersion` comes from
authoritative `api.jsr.io`, and preflight then validates the new pins before
publish. It only reaches a package that a real cut publishes — a dep that
moves while nobody pushes lands on the next release, which is when "the
published package's deps" is what actually matters.

### Why the registry-watching dance (the hang taxonomy)

Every defense in this workflow corresponds to a real failure we hit or a
verified upstream bug:

1. **`deno publish` never times out.** The CLI polls the publish status every
   2 s in an unbounded loop — no timeout, no flag (verified in
   `cli/tools/publish/mod.rs`; unchanged as of Deno v2.8.3). If the
   server-side task strands, the CLI waits until the 6-hour job limit.
2. **Server-side tasks DO strand.** jsr-io/jsr#1448 (June 2026): finalize
   tasks stuck in `processing`/`processed` while the version quietly goes
   live; jsr-io/jsr#642 (July 2024, GCP incident): 15-hour hangs. Since
   2026-06-10 a reaper requeues tasks stuck >30 min (jsr-io/jsr#1449), making
   the realistic worst case ~30-40 min — hence the 2400 s default window.
3. **The CLI hides the server's error.** A task that reaches `failure` is
   reported by the API with a real `error.code`/`error.message`; the watcher
   surfaces it verbatim and fails fast. The task is found via the status URL
   the CLI prints (`jsr.io/status/<uuid>`) and polled on the **public**
   `GET /publishing_tasks/<id>` endpoint — no token needed for the watch.
4. **`--no-provenance` always.** Sigstore provenance generation is a reported
   hang point on shared runners (jsr-io/jsr#1448) and carries an unfixed
   OIDC-JWT base64 decode bug (denoland/deno#29671 — triggered by non-ASCII
   workflow names). Token publishes don't produce provenance anyway.
5. **Version math uses `api.jsr.io`, never `meta.json`.** The CDN-cached
   meta.json lags behind a publish and derives wrong bumps.
6. **In-flight publishes settle first.** A previous run's task that is still
   `pending`/`processing` would make "latest" stale and the computed bump
   collide ("already processing" locks the exact version). The version step
   waits for in-flight tasks before deriving.
7. **Runs are serialized per repo** (`concurrency`, no cancel-in-progress):
   cancelling a publish mid-flight is a documented way to strand a server
   task, and racing pushes would double-bump.
8. **Preflight beats the server to the punch.** `scripts/check-jsr-deps.ts`
   validates every `jsr:` dependency subpath against the export maps of ALL
   versions matching the range — the class of failure that `deno publish
   --dry-run` cannot catch and that otherwise costs a ~10-minute server
   round-trip to discover (`invalidJsrDependencySubPath`).
9. **One retry for transient upload failures** (CLI died before any task was
   created), and only then — re-uploading over a live task is never safe.

### Pinning

Internal callers may use `@main`. Anything security-sensitive should pin a
full commit SHA — a branch ref can be repointed, and whatever sits behind the
ref receives the secrets you pass.

### Keep the workflow name ASCII

The caller's workflow `name:` ends up in the OIDC JWT; a non-ASCII name (an
emoji) triggers a deterministic provenance failure in the Deno CLI
(denoland/deno#29671). We skip provenance, but don't tempt fate.
