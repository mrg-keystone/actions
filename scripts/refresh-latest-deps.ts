// Repin named JSR dependencies to their newest published version across a Deno config and its
// workspace members, so a package always publishes against the latest of the deps it opts to track.
//
// jsr-publish.yml runs this (its `refresh-latest` input) BEFORE the version is computed and the
// package is published — so the repin lands in the SAME published tarball and the SAME auto-bump
// commit, needing no second workflow run (and no token that couldn't re-trigger one anyway: a push
// made with the default GITHUB_TOKEN does not fire `on: push` workflows). A no-op when every named
// dep is already at its latest floor.
//
//   deno run --allow-net --allow-read --allow-write --allow-env \
//     scripts/refresh-latest-deps.ts <deno.json> <pkg...>
//
// Rewrites RAW TEXT (never JSON.parse→stringify) so comments and formatting survive, and matches
// every import whose VALUE targets the package regardless of its map KEY — a bare `@scope/pkg`, an
// aliased subpath like `#assert` → `.../pkg@X/assert`, and so on. api.jsr.io is authoritative for
// "latest" (jsr.io/@scope/pkg/meta.json is CDN-cached and lags minutes behind a fresh publish).
//
// Outputs (appended to $GITHUB_OUTPUT when set, else printed):
//   changed=true|false
//   files=<newline-separated list of rewritten config files>

import { dirname, join } from "jsr:@std/path@^1";

const [configPath, ...pkgs] = Deno.args;
if (!configPath || pkgs.length === 0) {
  console.error("usage: refresh-latest-deps.ts <deno.json> <pkg...>");
  Deno.exit(2);
}

// api.jsr.io asks tools to identify themselves (jsr.io/docs/api).
const UA = "mrg-keystone-actions/1.0; https://github.com/mrg-keystone/actions";

async function latest(pkg: string): Promise<string> {
  const [scope, name] = pkg.slice(1).split("/");
  const res = await fetch(`https://api.jsr.io/scopes/${scope}/packages/${name}`, {
    headers: { "user-agent": UA },
  });
  if (!res.ok) throw new Error(`api.jsr.io ${res.status} resolving latest for ${pkg}`);
  const { latestVersion } = await res.json() as { latestVersion?: string };
  if (!latestVersion) throw new Error(`${pkg} has no published latestVersion — is it on JSR?`);
  return latestVersion;
}

// The config files whose import maps we rewrite: the given config + every workspace member's config.
function configFiles(root: string): string[] {
  const files = [root];
  try {
    const cfg = JSON.parse(Deno.readTextFileSync(root)) as { workspace?: string[] };
    const base = dirname(root);
    for (const member of cfg.workspace ?? []) {
      for (const cand of ["deno.json", "deno.jsonc"]) {
        const p = join(base, member, cand);
        try {
          Deno.statSync(p);
          files.push(p);
          break;
        } catch { /* try the next candidate filename */ }
      }
    }
  } catch { /* root isn't plain JSON (jsonc?) or declares no workspace — just rewrite the root */ }
  return files;
}

const esc = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// Resolve every target's latest up front, so a bad package name fails before any file is touched.
const floors = new Map<string, string>();
for (const pkg of pkgs) {
  const v = await latest(pkg);
  floors.set(pkg, v);
  console.log(`${pkg} → ^${v} (latest on JSR)`);
}

const changedFiles: string[] = [];
for (const file of configFiles(configPath)) {
  let text: string;
  try {
    text = Deno.readTextFileSync(file);
  } catch {
    continue;
  }
  let next = text;
  for (const [pkg, v] of floors) {
    // jsr:<pkg>@<range>, stopping before a closing quote or a subpath `/` so a `/subpath` survives.
    const pin = new RegExp(`jsr:${esc(pkg)}@[^"'/]+`, "g");
    next = next.replace(pin, `jsr:${pkg}@^${v}`);
  }
  if (next !== text) {
    Deno.writeTextFileSync(file, next);
    changedFiles.push(file);
    console.log(`  ✎ ${file}`);
  }
}

const changed = changedFiles.length > 0;
console.log(changed ? `Repinned ${changedFiles.length} file(s).` : "No change — every named dep already at its latest floor.");

const OUT = Deno.env.get("GITHUB_OUTPUT");
if (OUT) {
  Deno.writeTextFileSync(OUT, `changed=${changed}\nfiles<<REFRESH_EOF\n${changedFiles.join("\n")}\nREFRESH_EOF\n`, { append: true });
}
