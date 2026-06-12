// Emulates the JSR server-side dependency validation that `deno publish
// --dry-run` does NOT run: every `jsr:` dependency that uses a subpath
// (e.g. jsr:@danet/swagger@^2.1.1/decorators) must have that subpath in the
// export map of the versions matching the range. JSR validates this against
// the live registry — not your lockfile — so it can fail at publish time even
// though everything works locally (1.13.6 died exactly here: the lockfile
// resolved @2 to 2.3.2, JSR validated 2.1.0, the one version without the
// ./decorators export).
//
// We check ALL matching versions (stricter than JSR's resolution), so a pass
// here guarantees a pass server-side for this failure class.
//
// Usage: deno run --allow-net --allow-read scripts/check-jsr-deps.ts [deno.json]

import { parse, parseRange, satisfies } from "jsr:@std/semver@^1";

const configPath = Deno.args[0] ?? "deno.json";
const config = JSON.parse(Deno.readTextFileSync(configPath));
const imports: Record<string, string> = config.imports ?? {};

// jsr:@scope/name[@range][/subpath]
const JSR_SPECIFIER = /^jsr:(@[^/@]+\/[^/@]+)(?:@([^/]+))?(\/.+)?$/;

// The version LIST can be stale on jsr.io's CDN; api.jsr.io is authoritative.
// Per-version <v>_meta.json files are immutable, so caching is harmless there.
async function listVersions(pkg: string): Promise<string[]> {
  const [scope, name] = pkg.slice(1).split("/");
  const api = await fetch(
    `https://api.jsr.io/scopes/${scope}/packages/${name}/versions?limit=1000`,
  );
  if (api.ok) {
    const body = await api.json();
    const items = Array.isArray(body) ? body : body.items ?? [];
    return items
      .filter((v: { yanked?: boolean }) => !v.yanked)
      .map((v: { version: string }) => v.version);
  }
  await api.body?.cancel();
  const meta = await (await fetch(`https://jsr.io/${pkg}/meta.json`)).json();
  return Object.entries(meta.versions ?? {})
    .filter(([, v]) => !(v as { yanked?: boolean }).yanked)
    .map(([version]) => version);
}

let failures = 0;
for (const [alias, target] of Object.entries(imports)) {
  const match = target.match(JSR_SPECIFIER);
  if (!match) continue;
  const [, pkg, range, subpath] = match;
  if (!subpath) continue; // the root export exists in every published version

  const versions = await listVersions(pkg);
  const matching = range
    ? versions.filter((v) => satisfies(parse(v), parseRange(range)))
    : versions;
  if (matching.length === 0) {
    console.error(`✗ ${alias}: no published version of ${pkg} matches "${range}"`);
    failures++;
    continue;
  }

  const exportKey = "." + subpath;
  const missing: string[] = [];
  for (const version of matching) {
    const meta = await (await fetch(`https://jsr.io/${pkg}/${version}_meta.json`)).json();
    if (!(meta.exports && exportKey in meta.exports)) missing.push(version);
  }
  if (missing.length > 0) {
    console.error(
      `✗ ${alias} → ${target}\n` +
        `  export "${exportKey}" is missing in matching version(s): ${missing.join(", ")}\n` +
        `  JSR will reject the publish (invalidJsrDependencySubPath). ` +
        `Constrain the range to exclude them.`,
    );
    failures++;
  } else {
    console.log(
      `✓ ${alias} → ${target} (all ${matching.length} matching versions export "${exportKey}")`,
    );
  }
}

if (failures > 0) {
  console.error(`\n${failures} JSR dependency problem(s) found.`);
  Deno.exit(1);
}
console.log("All jsr: dependency subpaths are valid.");
