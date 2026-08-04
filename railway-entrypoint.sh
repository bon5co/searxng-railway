#!/bin/sh
# Railway entrypoint for SearXNG.
#
# Runs before the upstream entrypoint, which still does the volume ownership
# repair, the first-boot settings copy and the secret substitution. This shim
# only adds the two things the stock image cannot know: how big the container
# is, and which port Railway routed to it.
set -e

VENV_PY=/usr/local/searxng/.venv/bin/python3
SETTINGS="${__SEARXNG_SETTINGS_PATH:-/etc/searxng/settings.yml}"

# ---------------------------------------------------------------------------
# Concurrent search capacity
# ---------------------------------------------------------------------------
# Granian's --workers defaults to 1 and the upstream image bakes
# GRANIAN_BLOCKING_THREADS=4, so a stock instance serves exactly FOUR
# concurrent searches no matter how large the plan is; the fifth caller waits
# for a slot. A SearXNG request spends nearly all of its time blocked on
# upstream engines, so the fix is threads, not workers: measured on a
# 4-vCPU container against a deterministic 2s search, 64 concurrent requests
# took 32082ms at the stock setting and 2392ms at 64 blocking threads, for
# +11 MiB RSS. Reaching the same capacity with 4 worker PROCESSES instead
# cost 3.2x the memory (95.6 MiB -> 307.9 MiB) and was no faster.
#
# Sized from the container's CPU quota as a proxy for plan size, clamped so a
# small plan still clears the stock ceiling and a large one does not spawn
# threads it can never fill. Threads measured at roughly 0.2 MiB each.
# The upstream image bakes GRANIAN_BLOCKING_THREADS=4 as an image ENV, so that
# variable is always set and cannot tell "the deployer chose 4" apart from "the
# image default". SEARXNG_BLOCKING_THREADS is this image's own override and is
# unset unless a deployer sets it deliberately.
if [ -n "${SEARXNG_BLOCKING_THREADS:-}" ]; then
    threads="$SEARXNG_BLOCKING_THREADS"
    echo "railway-entrypoint: blocking_threads=$threads (SEARXNG_BLOCKING_THREADS)"
else
    cpu_quota=""
    if [ -r /sys/fs/cgroup/cpu.max ]; then
        cpu_quota=$(awk '{ if ($1 != "max") printf "%d", ($1 + $2 - 1) / $2 }' /sys/fs/cgroup/cpu.max)
    fi
    # nproc inside a container reports the HOST's core count, not the cgroup
    # quota, so it is a last resort and the clamp below is what bounds it.
    [ -z "$cpu_quota" ] && cpu_quota=$(nproc 2>/dev/null || echo 2)
    [ "$cpu_quota" -lt 1 ] 2>/dev/null && cpu_quota=1

    threads=$((cpu_quota * 8))
    [ "$threads" -lt 16 ] && threads=16
    [ "$threads" -gt 64 ] && threads=64
    echo "railway-entrypoint: cpu=$cpu_quota blocking_threads=$threads (stock default is 4)"
fi
GRANIAN_BLOCKING_THREADS="$threads"
export GRANIAN_BLOCKING_THREADS

# ---------------------------------------------------------------------------
# Port
# ---------------------------------------------------------------------------
# Railway injects PORT into every service and its HTTP healthcheck dials the
# INJECTED port, not the domain's target port -- so a public service must
# honour $PORT rather than pinning its own. The upstream entrypoint maps only
# SEARXNG_PORT onto GRANIAN_PORT and ignores PORT entirely, so hand it over.
if [ -n "${PORT:-}" ]; then
    SEARXNG_PORT="$PORT"
    export SEARXNG_PORT
fi

# ---------------------------------------------------------------------------
# Repair a settings file left by an earlier deploy
# ---------------------------------------------------------------------------
# The upstream entrypoint writes settings.yml from the template ONLY when the
# file is absent, so on a mounted volume the first boot wins forever. A volume
# carried over from a stock image therefore keeps formats: [html] and every
# API call keeps answering 403 even though this image ships the fix. Patch the
# formats list in place and leave the rest of the deployer's edits alone.
if [ -f "$SETTINGS" ]; then
    "$VENV_PY" - "$SETTINGS" <<'PY' || echo "railway-entrypoint: settings check skipped (unreadable YAML)"
import sys
import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    cfg = yaml.safe_load(fh)

if not isinstance(cfg, dict):
    raise SystemExit(0)

search = cfg.get("search")
if not isinstance(search, dict):
    search = {}
    cfg["search"] = search

formats = search.get("formats")
if not isinstance(formats, list):
    formats = []

missing = [f for f in ("html", "json", "csv", "rss") if f not in formats]
if not missing:
    raise SystemExit(0)

search["formats"] = formats + missing
with open(path, "w", encoding="utf-8") as fh:
    yaml.safe_dump(cfg, fh, default_flow_style=False, sort_keys=False)
print(f"railway-entrypoint: added {missing} to search.formats in {path}")
PY
fi

exec /usr/local/searxng/entrypoint.sh "$@"
