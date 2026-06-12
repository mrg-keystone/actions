# mrg-keystone/actions

Reusable GitHub Actions workflows for the org.

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

Outputs: `version`, `bumped`.

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
