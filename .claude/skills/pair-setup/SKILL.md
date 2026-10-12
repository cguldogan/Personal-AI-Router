---
name: pair-setup
description: Install NVIDIA Personal AI Router (PAIR) on a machine, pair machines into a cluster (LAN or Tailscale), expose engines (Ollama, LM Studio, llama.cpp), and diagnose "Pairing failed" or a node that shows no engines. Use for any setup, pairing, cluster, port, or remote-node question about PAIR.
---
<!--
SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# PAIR setup and pairing

Distilled from NVIDIA's playbook (https://build.nvidia.com/playbooks/pair/app-setup)
plus what this fork adds and what was verified on 2026-09-04 against two Linux
boxes on a Tailscale tailnet; updated 2026-10-12 for the fork's rebase onto
upstream 1.0.0. Where the playbook and this fork differ, this file says so.

## The one rule that explains most failures

**Every machine that should take part must run PAIR itself.** A machine that
only runs an engine (a bare `ollama serve`, LM Studio) can be a routing target, but it can never be *paired*: pairing talks to the peer's PAIR
cluster service on TCP 14321, and an engine-only box has nothing listening there.
"Pairing failed. Please try again." on an invite to such a box is the expected
outcome, not a transient error.

## Install PAIR

| Platform | Upstream release | This fork (Tailscale peers, scripted pairing, job stats) |
| --- | --- | --- |
| Windows | run the `.exe`, approve firewall prompts | the fork release's `.exe`, or build from source |
| Debian/Ubuntu | `sudo apt install "./NVPAIR-Setup-VERSION-ARCH.deb"` | `install-headless.sh` (see `INSTALL-FORK.md`), or the fork release's `.deb` |
| macOS | open `.dmg`, drag to Applications | the fork release's `.dmg`, or `cd desktop && npm start` (see the `pair-run` skill) |

The upstream package lacks cross-tailnet peers and scripted pairing. For a peer
reached over Tailscale, both ends must run **this fork's** build. The fork no
longer carries vLLM or SGLang; upstream's vLLM work is its PR #125.

### Build from source on a Linux box (DGX, DGX Spark, any Ubuntu)

Needs Go 1.25+ and `jq`. DGX Spark is arm64; both `linux/amd64` and `linux/arm64`
are covered.

```bash
git clone <fork url> Personal-AI-Router && cd Personal-AI-Router
git checkout fork/main                     # the fork's combined branch
cd services && ./build.sh                 # stages 13 binaries in build/bin/
./build/bin/nvpair-tui                    # headless UI; starts broker + workers
```

`nvpair-tui` supervises its own broker. Do not also start `nvpair-ui-broker` by
hand. Tabs: Nodes, Jobs, Service, Errors, Logs. On **Nodes**: `p` pair the
selected machine, `n` pair by address, `a` accept an inbound request, `f` find a
machine by address without pairing, `r` remove, `enter` open a machine. On a
machine's screen, Engines: `i` install, `s` start, `x` stop.

## First run

1. Welcome step lists installable engines for the platform: Ollama, LM Studio
   and llama.cpp.
2. An Ollama or LM Studio already running on its default port (11434, 1234) is
   **adopted**, not restarted. Adoption works even when the engine is bound to
   127.0.0.1, because peers reach it through this machine's own proxy over mTLS.
3. llama.cpp is installed and run by PAIR. Its proxy takes 8080 and the engine
   moves to 8081.

## Pair two machines

1. Both run PAIR. On a LAN they discover each other over mDNS; on Tailscale or
   any multicast-free network use **Add node** with the address.
2. On the inviting machine: **Add node** (or Settings → Cluster) → pick the
   discovered node or type the address → invite. It shows a six-digit PIN.
3. On the invited machine: accept the invitation and type the PIN. Desktop:
   the invitation dialog. Headless box: either the TUI Nodes tab (`a`, PIN,
   Enter) or, from any SSH shell while `nvpair-tui` runs, the scripted form:

   ```bash
   NVPAIR_PIN=123456 nvpair-tui accept            # exit 0 paired, 1 refused, 2 other
   nvpair-tui accept --wait 2m                    # wait for the invite to arrive first
   nvpair-tui pending | nvpair-tui members        # inspect
   nvpair-tui invite <address> [--wait]           # invite from the box; prints the PIN
   ```

   These talk to the running TUI over its control socket
   (`$XDG_RUNTIME_DIR/nvpair/tui.sock`, else `run/tui.sock` under the per-user
   data dir). Two headless boxes pair each other with `invite` on one and
   `accept` on the other. Docs: `docs/terminal-interface.mdx`, "Pair from a
   Script or Over SSH".
4. Verify under Settings → Cluster → **Connected nodes**, or on Overview.

Trust is transitive: pairing A↔B and A↔C also lets B and C talk.

### Over Tailscale

- Prefer the MagicDNS name (`box.tailnet-name.ts.net`) over the 100.x.y.z
  address. PAIR re-resolves a name every probe; an IP literal is dead after a
  renumber. Never type `host:port` in the address; use **Service ports** for
  non-default ports.
- Tailscale ACL must allow, between the PAIR nodes, TCP 1234, 8080, 11434,
  14318, 14319, 14320, 14321, 14322, 14323 (see `docs/remote-networks.mdx` for a
  snippet). mDNS 5353/udp does not cross a tailnet and is not needed.
- A node added by address before it runs PAIR appears with `pair_node: false`
  and, if an engine is exposed on the tailnet address, gets routed to as a bare
  host in plaintext inside the tunnel. Once PAIR runs there it flips to a full
  peer automatically within a few probe cycles.

## Ports

| Port | Purpose |
| --- | --- |
| 11434 | Ollama facade (clients talk here). Ollama engine itself moves to 11435+ |
| 1234 | LM Studio facade, OpenAI-compatible. LM Studio engine on 1235+ |
| 8080 | llama.cpp facade, OpenAI-compatible. PAIR's llama.cpp router on 8081 |
| 5353/udp | mDNS discovery (LAN only) |
| 14318 | node-info: hardware, telemetry, service map |
| 14319 | service-error sync |
| 14320 | workload propagation |
| 14321 | pairing and membership |
| 14322 | model inventory (`em`, mTLS from peers) |
| 14323 | remote engine control (`ec`, mTLS) |

All three facades are one `nvpair-proxy` process. They accept plaintext only
from the machine's own loopback. A peer arrives
over cluster mTLS. A `403` on a proxy port from another machine is correct
behaviour, not a bug.

## Use it

- **Endpoints** in the top toolbar lists the local URLs. OpenAI-style clients use
  `http://127.0.0.1:1234/v1/chat/completions` (LM Studio models) or
  `http://127.0.0.1:8080/v1/chat/completions` (llama.cpp models); Ollama-style
  use `http://127.0.0.1:11434/api/chat`. Name the model exactly as `/v1/models` or
  `/api/tags` lists it. The proxy routes to whichever node holds it.
- Each facade lists its own engine's models across the cluster. Copy the id
  from that facade's `/v1/models` rather than typing it.
- A request that sends nothing back for 30 minutes fails. Raise
  `NVPAIR_PROXY_RESPONSE_HEADER_TIMEOUT` (`1h`, or `0` for none) in the
  environment PAIR starts with, on every node the request crosses.

## Diagnose a failed invite or an engine-less node

Run from the inviting machine, replacing the address:

```bash
tailscale ping -c 2 <addr>                      # tunnel up?
for p in 14318 14321 14322 11434 1234 8080; do
  printf "%s: " $p; nc -z -w 3 <addr> $p && echo open || echo closed; done
curl -s http://<addr>:14318/v1/node-info | head -c 300   # PAIR running there?
```

| Symptom | Meaning | Fix |
| --- | --- | --- |
| 14321 closed, 14318 closed | PAIR is not running on the peer | build and run `nvpair-tui` there, invite again |
| only an engine port open | bare engine host; routable, not pairable | fine as is, or install PAIR there for telemetry, scheduling and mTLS |
| `probe-failed` error after 30 s | nothing answered on any port | as above; if added by IP and the box was renumbered, re-add by hostname |
| 14318 answers but no models | not paired yet; inventory is served only to pinned peers | complete pairing |

Desktop logs: run the app from `desktop/` with `npm start` and read stdout, or
collect logs with `scripts/collect-logs.sh`. Manual-node probe results appear as
`node/discovered` / `node/updated` lines with `ollama_up`, `lmstudio_up`,
`node_info_up`, `pair_node`.

## How PAIR decides (what to expect, and why)

- **Routing precedence** inside the set of nodes advertising the model: manual
  pin → scheduler order (`pending + gpuPressure`, 0–3
  pressure from the busiest GPU, neutral 1 when telemetry is stale) → stable
  UUID. A model on one node only means no balancing for it. Put the same model
  on several nodes to make them interchangeable. Model load state, VRAM, and GPU
  model are not inputs.
- **Model lists are not routed.** `/v1/models` and `/api/tags` fan out to every
  candidate and merge, so the answer is the cluster's inventory.
- **A peer never re-routes.** The mTLS ingress forwards to that node's own
  loopback engine only. Make the machine you work on a node; it needs no GPU.
- **Eviction is slow on purpose.** A discovered node is dropped only after ~1
  minute of missed mDNS scans *and* failed probes; streamed inference bytes or a
  node-info answer in the last 10–60 s cancel it. Manual nodes are probed every
  10 s and reported failed after 3 misses (~30 s) but stay in the routing pool.
  Eviction is what fails in-flight jobs pinned to that node.
- **Inventory is served only to pinned peers.** A node card with hardware but
  no models means "not paired yet", not "no engines".
- **Adoption.** PAIR adopts an engine already on its port and will not stop or
  move it: Ollama is process-managed (port change refused), LM Studio can be
  stopped with `lms server stop` and restarted on the new port. An
  unknown process on a port is never killed; the proxy moves and warns instead.
- **Engine CLIs** are not on PATH. Ollama lives in
  `<app data>/engine-bin/ollama/`; point `OLLAMA_HOST` at the *engine* port
  (11435) to see the local machine, at 11434 to see the cluster. LM Studio uses
  `~/.lmstudio/bin/lms`.
- **Pairing PIN** is one attempt, 5 min TTL, six digits, low entropy. A wrong
  PIN or a restart mid-pairing ends the invite; issue a fresh one rather than
  retrying. Pair only on networks you trust.
- **Leaving.** Settings → Cluster → Leave (TUI: `l` on the Nodes tab) on the node, or remove it
  from any member; removal takes effect on the peer's next request. Uninstall
  keeps app data; `scripts/wipe-app-data.sh --confirm` or Settings → Service →
  Reset app data clears it. Model weights are never touched.
- **Never run `nvpair-tui` and the desktop app on the same machine at once**;
  each starts its own broker and worker tree and they fight over ports, engines,
  and settings.
- **Mixed PAIR versions in one cluster are unsupported**: the mTLS channel must
  match on both sides. Update every node.

## Not in the playbook, true of this fork

- After running `go test` in `services/tests`, check the `*-proxy-port.json`
  files in the application data directory
  (`~/Library/Application Support/Nvidia Corporation/Personal AI Router` on
  macOS); a leftover one can start a facade on the wrong port.
- Automatic tailnet peer discovery is not implemented; add peers by name.
