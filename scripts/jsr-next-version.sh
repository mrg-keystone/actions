#!/usr/bin/env bash
# Compute the version to publish, race-proof against in-flight publishes.
#
#   jsr-next-version.sh <deno.json path> <commit-range or "">
#
# Behavior:
#   1. Wait for any in-flight publishing task (pending/processing) on this
#      package to settle — a previous run may have uploaded a version whose
#      server-side processing is still running; deriving "latest" before it
#      lands computes a colliding bump.
#   2. If deno.json's version is NOT on JSR → publish it as-is (manual bumps
#      are respected; set the version yourself for a specific cut).
#   3. Otherwise derive the next version from the AUTHORITATIVE api.jsr.io
#      version list (jsr.io/meta.json is CDN-cached and lags minutes behind):
#      patch by default, minor for a `feat:` commit in the range, major for a
#      breaking marker (`type!:` or "BREAKING CHANGE"), and write it back to
#      deno.json (in the work tree — the caller decides whether to commit).
#
# Requires: curl, jq, git. JSR_TOKEN env enables in-flight detection (the
# publishing_tasks endpoint needs auth; without a token that wait is skipped).
#
# Outputs (appended to $GITHUB_OUTPUT when set, else printed):
#   scope=, pkg=, version=, bumped=true|false
set -euo pipefail

CONFIG="${1:?usage: jsr-next-version.sh <deno.json> [<before>..<after>]}"
RANGE="${2:-}"
OUT="${GITHUB_OUTPUT:-/dev/stdout}"

NAME="$(jq -r .name "$CONFIG")"
SCOPE="${NAME#@}"; SCOPE="${SCOPE%%/*}"
PKG="${NAME##*/}"
VER="$(jq -r .version "$CONFIG")"
API="https://api.jsr.io/scopes/$SCOPE/packages/$PKG"
# api.jsr.io asks tools to identify themselves (jsr.io/docs/api).
UA="mrg-keystone-actions/1.0; https://github.com/mrg-keystone/actions"

echo "scope=$SCOPE" >> "$OUT"
echo "pkg=$PKG" >> "$OUT"

# --- 1. settle in-flight publishing tasks (auth required; best-effort) -------
if [ -n "${JSR_TOKEN:-}" ]; then
  for i in $(seq 1 90); do # up to 15 min
    INFLIGHT="$(curl -fsS -A "$UA" -H "Authorization: Bearer $JSR_TOKEN" "$API/publishing_tasks" 2>/dev/null |
      jq -r '(.items // .) | [.[]? | select(.status != "success" and .status != "failure")] | length' 2>/dev/null || echo 0)"
    [ "${INFLIGHT:-0}" = "0" ] && break
    [ "$i" = "1" ] && echo "::notice::$INFLIGHT in-flight publishing task(s) on @$SCOPE/$PKG — waiting for them to settle before deriving the next version"
    sleep 10
  done
fi

# --- 2. manual version respected when it isn't on JSR yet --------------------
if ! curl -fsS -A "$UA" "$API/versions/$VER" >/dev/null 2>&1; then
  echo "deno.json version $VER is not on JSR yet — publishing as-is"
  echo "version=$VER" >> "$OUT"
  echo "bumped=false" >> "$OUT"
  exit 0
fi

# --- 3. derive the bump from the pushed commit range --------------------------
# The versions LIST is CDN-cached (s-maxage=86400) for anonymous requests and
# can be MINUTES stale right after a publish; an authenticated request bypasses
# the cache. Belt and suspenders: send the token when we have one, add a
# cache-buster, and never trust the list below VER — the single-version GET
# above just PROVED that VER is published, so the base is max(list, VER).
LIST_LATEST="$(curl -fsS -A "$UA" ${JSR_TOKEN:+-H "Authorization: Bearer $JSR_TOKEN"} \
  "$API/versions?limit=1000&cb=$(date +%s)" |
  jq -r '(.items // .) | .[]? | select(.yanked != true) | .version' | sort -V | tail -1)"
LATEST="$(printf '%s\n%s\n' "$LIST_LATEST" "$VER" | sort -V | tail -1)"
[ "$LATEST" != "$LIST_LATEST" ] && echo "::notice::versions list is CDN-stale (says $LIST_LATEST; $VER is proven published) — basing the bump on $VER"
BUMP=patch
if [ -n "$RANGE" ] && git rev-parse -q --verify "${RANGE%%..*}^{commit}" >/dev/null 2>&1; then
  LOG="$(git log --format=%B "$RANGE")"
  if echo "$LOG" | grep -qE '^[a-z]+(\([^)]*\))?!:|BREAKING CHANGE'; then
    BUMP=major
  elif echo "$LOG" | grep -qE '^feat(\([^)]*\))?:'; then
    BUMP=minor
  fi
fi
IFS=. read -r MA MI PA <<< "$LATEST"
case "$BUMP" in
  major) NEW="$((MA + 1)).0.0" ;;
  minor) NEW="$MA.$((MI + 1)).0" ;;
  patch) NEW="$MA.$MI.$((PA + 1))" ;;
esac
echo "$VER is already on JSR (latest: $LATEST) — auto-bumping $BUMP to $NEW"
jq --arg v "$NEW" '.version = $v' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
echo "version=$NEW" >> "$OUT"
echo "bumped=true" >> "$OUT"
