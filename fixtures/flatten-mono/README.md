# flatten-mono fixture

A workspace ROOT that publishes as one package whose `exports` reach into its
own workspace members' directories — impossible without `flatten-workspace:
true` (Deno hard-excludes members from a root tarball: `error[excluded-module]`,
and `publish.include` cannot override it). The self-test dry-runs the reusable
workflow against this tree; if the flatten step regresses, preflight fails.
Member deno.json files stay (tasks etc. are allowed); member-local `imports`
maps must NOT be relied on by exported code (they don't apply to the published
graph — proven 2026-09-02).
