#!/usr/bin/env bash
# Publish to JSR without trusting `deno publish` to terminate.
#
#   jsr-publish-watch.sh <scope> <pkg> <version> [extra deno publish flags...]
#
# Why this exists (all verified against deno/jsr source + issue history):
#   - the CLI polls the publish status every 2s in an UNBOUNDED loop — no
#     timeout, no flag to add one (denoland/deno cli/tools/publish/mod.rs);
#     when the server-side task strands, the CLI waits forever (the classic
#     hang; jsr-io/jsr#1448, #1383, #642);
#   - JSR's finalize pipeline can legitimately take tens of minutes; since
#     2026-06-10 a server-side reaper requeues tasks stuck >30 min
#     (jsr-io/jsr#1449), so the realistic worst case is ~30-40 min, not never.
#
# Strategy: run the CLI in the background and watch the REGISTRY —
#   success  := GET /versions/<v> returns 200, or the publishing task reports
#               status "success" (both public endpoints);
#   failure  := the task reports status "failure" → surface its error
#               code+message verbatim (the CLI never does);
#   progress := task status transitions (pending→processing→processed→…)
#               streamed to the log;
#   timeout  := JSR_PUBLISH_TIMEOUT_SECS (default 2400) elapsed.
#
# The task is identified from the status URL the CLI prints
# (https://jsr.io/status/<uuid>) and polled via the PUBLIC documented
# endpoint GET /publishing_tasks/<id> — no token needed. When the id can't
# be captured, falls back to the per-package task list (needs JSR_TOKEN).
# One retry for transient upload failures (CLI died before a task existed).
#
# Requires: curl, jq, deno. JSR_TOKEN env: used for `deno publish --token`
# and the list fallback. JSR_PUBLISH_DRY_RUN=1 validates without uploading.
set -uo pipefail

SCOPE="${1:?usage: jsr-publish-watch.sh <scope> <pkg> <version> [flags...]}"
PKG="${2:?}"
VER="${3:?}"
shift 3
API="https://api.jsr.io"
PKG_API="$API/scopes/$SCOPE/packages/$PKG"
VURL="$PKG_API/versions/$VER"
TIMEOUT="${JSR_PUBLISH_TIMEOUT_SECS:-2400}"
START_ISO="$(date -u +%Y-%m-%dT%H:%M:%S)"
UA="mrg-keystone-actions/1.0; https://github.com/mrg-keystone/actions"
CLI_LOG="$(mktemp)"

if [ "${JSR_PUBLISH_DRY_RUN:-0}" = "1" ]; then
  echo "[dry-run] would publish @$SCOPE/$PKG@$VER (deno publish $*)"
  exit 0
fi

api_get() { curl -fsS -A "$UA" "$@"; }

# Task JSON via the public by-id endpoint (preferred) or the authed list.
TASK_ID=""
task_json() {
  if [ -z "$TASK_ID" ]; then
    # The CLI prints "https://jsr.io/status/<uuid>" once the task exists.
    TASK_ID="$(grep -oE 'jsr.io/status/[0-9a-f-]{36}' "$CLI_LOG" 2>/dev/null | head -1 | sed 's|.*/||')" || true
  fi
  if [ -n "$TASK_ID" ]; then
    api_get "$API/publishing_tasks/$TASK_ID" 2>/dev/null || true
  elif [ -n "${JSR_TOKEN:-}" ]; then
    api_get -H "Authorization: Bearer $JSR_TOKEN" "$PKG_API/publishing_tasks" 2>/dev/null |
      jq -c --arg v "$VER" --arg t "$START_ISO" \
        '(.items // .) | [.[]? | select(.packageVersion == $v and .createdAt >= $t)] | first // empty' \
        2>/dev/null || true
  fi
}

# One watch tick. Echoes nothing; returns 0=success, 1=failure, 2=keep waiting.
LAST_STATUS=""
tick() {
  local elapsed="$1" task status
  if api_get "$VURL" >/dev/null 2>&1; then
    echo "✓ @$SCOPE/$PKG@$VER is live on JSR (${elapsed}s)"
    return 0
  fi
  task="$(task_json)"
  if [ -n "$task" ]; then
    status="$(jq -r '.status // empty' <<<"$task" 2>/dev/null)" || status=""
    if [ -n "$status" ] && [ "$status" != "$LAST_STATUS" ]; then
      echo "… publishing task ${TASK_ID:-?}: ${LAST_STATUS:-created} → $status (${elapsed}s)"
      LAST_STATUS="$status"
    fi
    case "$status" in
      success)
        echo "✓ publishing task succeeded for @$SCOPE/$PKG@$VER (${elapsed}s)"
        return 0 ;;
      failure)
        echo "✗ JSR publishing task FAILED for @$SCOPE/$PKG@$VER: $(jq -r '"\(.error.code // "unknown"): \(.error.message // "no message")"' <<<"$task")" >&2
        return 1 ;;
    esac
  fi
  return 2
}

attempt() {
  local n="$1"; shift
  echo "Publishing @$SCOPE/$PKG@$VER (attempt $n) ..."
  : > "$CLI_LOG"
  TASK_ID=""; LAST_STATUS=""
  deno publish ${JSR_TOKEN:+--token "$JSR_TOKEN"} "$@" >"$CLI_LOG" 2>&1 &
  local pub_pid=$!
  local elapsed=0 cli_exit="" rc

  # Mirror the CLI's own output so the run log stays informative.
  tail -f "$CLI_LOG" 2>/dev/null | sed 's/^/  [deno] /' &
  local tail_pid=$!

  while [ "$elapsed" -lt "$TIMEOUT" ]; do
    tick "$elapsed"; rc=$?
    if [ "$rc" != "2" ]; then
      kill "$pub_pid" "$tail_pid" 2>/dev/null || true
      wait "$pub_pid" 2>/dev/null || true
      return "$rc"
    fi

    if [ -z "$cli_exit" ] && ! kill -0 "$pub_pid" 2>/dev/null; then
      wait "$pub_pid"; cli_exit=$?
      # Fast path: version can take seconds to appear after a quick CLI exit.
      if [ "$cli_exit" = "0" ]; then
        echo "… deno publish exited 0; confirming against the registry"
      elif [ -z "$(task_json)" ]; then
        kill "$tail_pid" 2>/dev/null || true
        echo "::warning::deno publish exited $cli_exit before a publishing task was created (transient upload failure)"
        sed 's/^/  [deno] /' "$CLI_LOG" | tail -20
        return 75 # EX_TEMPFAIL → retry once
      else
        echo "… deno publish exited $cli_exit but a publishing task exists; watching the server"
      fi
    fi

    sleep 5; elapsed=$((elapsed + 5))
    [ $((elapsed % 60)) -eq 0 ] && echo "… still waiting (${elapsed}s, task: ${LAST_STATUS:-not yet visible})"
  done

  echo "✗ timed out after ${TIMEOUT}s waiting for @$SCOPE/$PKG@$VER (last task status: ${LAST_STATUS:-none}${TASK_ID:+, status page: https://jsr.io/status/$TASK_ID})" >&2
  echo "  NOTE: a stranded task self-heals server-side (~30-40 min reaper); the version may still go live — do not blind-retry with the same version." >&2
  kill "$pub_pid" "$tail_pid" 2>/dev/null || true
  return 1
}

attempt 1 "$@"
rc=$?
if [ "$rc" = "75" ]; then
  echo "Retrying the upload once ..."
  attempt 2 "$@"
  rc=$?
  [ "$rc" = "75" ] && rc=1
fi
exit "$rc"
