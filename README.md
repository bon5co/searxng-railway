# searxng-railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/searxng-v202683-or-ai-agent-search-api-1?referralCode=Z1xivh&utm_medium=integration&utm_source=template&utm_campaign=generic)

**Deploy on Railway:** [SearXNG template](https://railway.com/deploy/searxng-v202683-or-ai-agent-search-api-1?referralCode=Z1xivh&utm_medium=integration&utm_source=template&utm_campaign=generic)

Railway-tuned [SearXNG](https://github.com/searxng/searxng) image: the JSON API
actually on, and the concurrent-search ceiling raised off its stock value of four.

Image: `ghcr.io/bon5co/searxng-railway:latest`
Base: `docker.io/searxng/searxng:2026.8.3-aa059419f` (pinned)

## What this changes, and why

### 1. The JSON API answers instead of 403ing

SearXNG's own default settings ship `search.formats: [html]`, so a stock
instance replies `403 Forbidden` to `/search?q=…&format=json` — the exact call
every agent framework, Open WebUI web-search backend and `curl` client makes.
There is no environment variable for it: `searx/settings_loader.py` reads only
`SEARXNG_SETTINGS_PATH`, so the list can only be widened in `settings.yml`.

This image bakes `formats: [html, json, csv, rss]` into the settings template
the upstream entrypoint copies on first boot.

Reproduced against the stock image, then verified fixed:

```
stock      GET /search?q=railway&format=json  ->  403 Forbidden
this image GET /search?q=railway&format=json  ->  200, JSON results
```

### 2. Four concurrent searches is the stock ceiling, whatever the plan

Granian's `--workers` defaults to `1` and the upstream image bakes
`GRANIAN_BLOCKING_THREADS=4`, so a stock instance serves exactly **four**
concurrent searches regardless of how much CPU the container has. The fifth
caller waits for a slot. For a browser that is invisible; for an agent fleet it
is a hard throughput wall.

A SearXNG request spends almost all of its time blocked on upstream engines, so
the fix is threads, not worker processes. Measured on a 4-vCPU container against
a deterministic 2-second search (an engine pointed at a black-holed address, so
every request takes exactly the request timeout and nothing is cached):

| configuration | 64 concurrent searches | RSS |
|---|---:|---:|
| stock — 1 worker × 4 blocking threads | 32082 ms | 98.1 MiB |
| 1 worker × 64 blocking threads | 2392 ms | 109.6 MiB |
| 4 workers × 8 blocking threads | 2068 ms* | 307.9 MiB |

\* at 16 concurrent; the worker variant costs 3.2× the memory for no gain over
threads, because the wait is on the network rather than on the GIL.

The entrypoint sizes `GRANIAN_BLOCKING_THREADS` from the container's own
`/sys/fs/cgroup/cpu.max` (8 per vCPU, clamped to 16–64) rather than from
`nproc`, which inside a container reports the host's core count. On a 4-vCPU
container that is 32 threads, measured at 4244 ms for the same 64 concurrent
searches against the stock image's 32091 ms.

Set `SEARXNG_BLOCKING_THREADS` to override. The upstream image bakes
`GRANIAN_BLOCKING_THREADS` as an image ENV, so that variable cannot distinguish
a deployer's choice from the image default — hence the separate name.

### 3. `$PORT` is honoured

The upstream entrypoint maps only `SEARXNG_PORT` onto `GRANIAN_PORT` and ignores
`PORT` entirely. Railway injects `PORT` into every service and its HTTP
healthcheck dials that **injected** port rather than the domain's target port, so
a public service has to follow it. The shim hands `PORT` to `SEARXNG_PORT` before
the upstream entrypoint runs.

### 4. A settings file left by an earlier deploy gets repaired

The upstream entrypoint writes `settings.yml` from its template **only when the
file is absent**. On a mounted volume the first boot therefore wins forever: a
volume carried over from a stock image keeps `formats: [html]` and every API call
keeps 403ing even after switching to this image. The shim adds the missing
formats in place, leaving the rest of the deployer's edits — including an
existing `secret_key` — untouched, and does nothing on subsequent boots.

## What is deliberately NOT changed

- **No Redis/Valkey service.** Valkey is consumed only by the limiter and the
  bot-detection layer (`searx/limiter.py`, `searx/botdetection/`), and
  `limiter.initialize()` returns before installing anything when
  `server.limiter` and `server.public_instance` are both false. Attaching one to
  a private instance bills the deployer for a service the application never
  consults.
- **No worker-process increase.** Measured above: 3.2× the memory, no gain.
- **`server.method` left at its default of `POST`.** `GET /search?…&format=json`
  was verified to return 200 regardless, so changing it buys nothing.
- **No engine curation.** Which upstream engines CAPTCHA a datacenter IP was not
  measured for this build, so no claim is made about it.
