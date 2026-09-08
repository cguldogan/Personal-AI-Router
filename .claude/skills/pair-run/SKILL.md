---
name: pair-run
description: Launch and drive the PAIR desktop app locally from source on this Mac (npm start), verify the broker and proxies, and send a real request through the OpenAI-compatible proxy. Use when asked to run, start, restart, or smoke-test the app.
---
<!--
SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Run PAIR locally

Verified on 2026-09-04, macOS arm64, branch `feat/vllm-tailscale`.

## Toolchain (do this first, every shell)

```bash
export PATH=/opt/homebrew/bin:$PATH   # Go 1.27 from Homebrew; required >= 1.25
go version                             # must NOT print go1.20.x (/usr/local/go is stale)
```

Node here is v23 while `desktop/package.json` asks for >= 25.5. Everything still
runs; ignore the engines warning. `desktop/node_modules` exists; if it is
missing, `cd desktop && npm install --no-audit --no-fund`.

## Launch

**Only one PAIR per machine.** The fork's released app is installed at
`/Applications/PAIR.app` (from the fork's GitHub release; unsigned, quarantine
already cleared). It holds the same fixed ports and the same data directory as
the dev build, so quit it before `npm start` and relaunch it afterwards
(`open -a /Applications/PAIR.app`). Pairings and identity are shared between
the two; nothing is lost by switching.


```bash
cd desktop
npm start > /tmp/pair-start.log 2>&1 &     # builds 13 Go binaries + tools, then electron-vite dev
```

Run it in the background (Claude Code: `run_in_background`). It takes about a
minute. The window titled **Personal AI Router** appears on screen; no xvfb
needed on macOS. `npm start` also rebuilds the service binaries, so a change
under `services/` is picked up by restarting it.

Ready signal in the log:

```bash
until grep -q 'engine:state-changed' /tmp/pair-start.log; do sleep 1; done
```

## Verify it is really up

```bash
pgrep -fl 'nvpair-|ollama-proxy|lmstudio-proxy' | awk '{print $2}' | xargs -n1 basename | sort
# expect nvpair-ui-broker + 10 workers + ollama-proxy + lmstudio-proxy
curl -s http://127.0.0.1:1234/v1/models | jq -c '[.data[].id]'      # OpenAI-compatible proxy
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:11434/api/tags  # 503 when no Ollama anywhere is normal
screencapture -x /tmp/pair.png && sips -Z 1400 /tmp/pair.png >/dev/null   # then look at it
```

On this Mac PAIR adopts LM Studio if `lms server start` is running (engine on
1235, proxy on 1234). If `/v1/models` is empty, check `~/.lmstudio/bin/lms server status`.

## Drive it

A real inference through the proxy, which shows up under **Jobs** in the window:

```bash
curl -s http://127.0.0.1:1234/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"<id from /v1/models>","max_tokens":30,"messages":[{"role":"user","content":"Reply with the single word: pong"}]}' \
  | jq -c '{model, content: .choices[0].message.content}'
```

Which node served it is in the log: grep `"scheduledOn"` on the last workload line.

Add a remote node: **Add node** in the toolbar, type a Tailscale address or
MagicDNS name. A bare vLLM or SGLang host is routable within ~10 s without
pairing; a PAIR peer additionally needs the invite/PIN step (see the
`pair-setup` skill).

Talk to the broker without the app (from `services/build/bin` after `./build.sh`):

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"ping"}' | ./nvpair-ui-broker
```

Expect an `app:ready` notification plus the `pong`. The desktop waits 15 s for
`app:ready` (`MODULAR_STARTUP_READY_TIMEOUT_MS`) before showing the failure in
Settings → Service.

## Logs and app data

Everything lives under
`~/Library/Application Support/Nvidia Corporation/Personal AI Router/`:

| Path | What |
| --- | --- |
| `logs/nvpair.jsonl` (+ `nvpair.1.jsonl`) | one JSON object per line; `jq`/`grep` friendly; never contains prompts |
| `cluster/` | node identity, `node.key`/`node.crt`, `trusted/<uuid>.json` pins |
| `settings.json` | node-settings store (cluster id/name, force_ports) |
| `engines/`, `engine-bin/` | manifest overrides (port, served model) and PAIR-installed engines |
| `workloads-history.json` | the Jobs history the broker persists |
| `proxy-port.json`, `lmstudio-proxy-port.json` | persisted proxy ports (see quirks) |

Turn on debug for the whole process tree before launch with
`NVPAIR_LOG_LEVEL=debug npm start`, or live from Settings → Service. Sanitize a
log before sharing it: `./scripts/collect-logs.sh -out ./out` (needs `go`).
Reset to first-run: `scripts/wipe-app-data.sh --dry-run` then `--confirm`.

Reading a failure from the proxy:

| Symptom | Meaning |
| --- | --- |
| connection refused | nothing on that port; check `proxy:get-status` / Endpoints |
| `502 no active node` | proxy up, no routable engine node |
| `502 ... advertises the requested model` | no owner of that model in the current inventory |
| `404` on inference | every advertised owner rejected the model; inventory stale |
| `403` | plaintext from a non-loopback address, or an unpaired peer |
| reply but Jobs empty | something else (Ollama desktop app) owns 11434 |

## Develop and verify

`services/` is the source of truth; `desktop/` only relays and renders. Never
reimplement routing, scheduling, discovery, or crypto in TypeScript.

```bash
export PATH=/opt/homebrew/bin:$PATH
make check                      # headers, build-script verify, lint, typecheck, contracts, desktop tests
cd desktop && npm run dead-code:check   # not part of make check
cd services/<component> && go test ./...           # fast, per component
cd services/tests && go test ./...                 # cross-process, builds its own binaries, minutes
```

Rules the tooling enforces: no `as` casts / `any` / `unknown` in signatures,
`@/` imports across directories, static imports only, two-line SPDX header on
every file (`node scripts/spdx-headers.mjs --fix`), say "engine" not
"backend" in new copy, never log prompts/PINs/keys.

Changing a JSON-RPC method or payload means updating the Go producer, the
broker relay, every consumer, `desktop/src/electron/service-bridge/`, tests,
and docs together, then `npm run service-contracts:write` and `:check`
(`desktop/docs/services-api.md` is generated; never hand-edit). Bump each
changed binary in `services/versions.json` per `services/VERSIONING.md`.
Tests that bind 11434/14319/14321 skip when the app is running; a skip is not
a pass. Live engine tests need `NVPAIR_LIVE_OLLAMA=1` / `NVPAIR_LIVE_LMSTUDIO=1`.

## Stop

Close the window, or kill the `npm start` process group. The broker shuts its
workers down with it. Stale `nvpair-*` processes after a crash:
`pkill -f nvpair-ui-broker`.

## Known local quirks

- The Jobs list may show `test-model` entries. They are leaked by
  `services/tests`; clear with `scripts/wipe-app-data.sh --confirm` (wipes all app
  data) or delete `workloads-history.json` in
  `~/Library/Application Support/Nvidia Corporation/Personal AI Router`.
- After running Go tests, delete `lmstudio-proxy-port.json` in that directory or
  the OpenAI proxy comes up on 1240 instead of 1234.
- vLLM and SGLang show an Install button on macOS but both manifests are
  Linux-only; the install is expected to refuse.
