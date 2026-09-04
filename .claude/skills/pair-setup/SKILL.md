---
name: pair-setup
description: Install NVIDIA Personal AI Router (PAIR) on a machine, pair machines into a cluster (LAN or Tailscale), expose engines (Ollama, LM Studio, vLLM), and diagnose "Pairing failed" or a node that shows no engines. Use for any setup, pairing, cluster, port, or remote-node question about PAIR.
---
<!--
SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# PAIR setup and pairing

Distilled from NVIDIA's playbook (https://build.nvidia.com/playbooks/pair/app-setup)
plus what this fork adds and what was verified on 2026-09-04 against two Linux
boxes on a Tailscale tailnet. Where the playbook and this fork differ, this file
says so.

## The one rule that explains most failures

**Every machine that should take part must run PAIR itself.** A machine that
only runs an engine (a bare `vllm serve`, `ollama serve`, LM Studio) can be a
routing target, but it can never be *paired*: pairing talks to the peer's PAIR
cluster service on TCP 14321, and an engine-only box has nothing listening there.
"Pairing failed. Please try again." on an invite to such a box is the expected
outcome, not a transient error.

## Install PAIR

| Platform | Upstream release | This fork (vLLM + Tailscale support) |
| --- | --- | --- |
| Windows | run the `.exe`, approve firewall prompts | not packaged; build from source |
| Debian/Ubuntu | `sudo apt install "./NVPAIR-Setup-VERSION-ARCH.deb"` | build from source, run headless (below) |
| macOS | open `.dmg`, drag to Applications | `cd desktop && npm start` (see the `pair-run` skill) |

The upstream package lacks vLLM and cross-tailnet support. For a peer reached
over Tailscale, or a vLLM host, the peer must run **this fork's** binaries.

### Build from source on a Linux box (DGX, DGX Spark, any Ubuntu)

Needs Go 1.25+ and `jq`. DGX Spark is arm64; both `linux/amd64` and `linux/arm64`
are covered.

```bash
git clone <fork url> Personal-AI-Router && cd Personal-AI-Router
git checkout feat/vllm-tailscale          # or main once merged
cd services && ./build.sh                 # stages 13 binaries in build/bin/
./build/bin/nvpair-tui                    # headless UI; starts broker + workers
```

`nvpair-tui` supervises its own broker. Do not also start `nvpair-ui-broker` by
hand. Tabs: Engines (`i` install, `s` start, `x` stop), Cluster (`i` invite,
`a` accept an inbound invite), Manual (`a` add a node by address), Logs.

## First run

1. Welcome step lists installable engines for the platform: Ollama and LM Studio
   everywhere, vLLM on Linux only (never pre-selected; it downloads a CUDA stack
   and then a model).
2. An engine already running on its default port is **adopted**, not restarted:
   Ollama on 11434, LM Studio on 1234, vLLM on 8000. Adoption works even when the
   engine is bound to 127.0.0.1, because peers reach it through this machine's
   own proxy over mTLS. This is the normal way to bring an existing vLLM in.
3. vLLM serves one model per process. Set **Model to serve** (a Hugging Face id)
   in Engine settings before starting it through PAIR. An adopted vLLM already
   has its model and needs nothing.

## Pair two machines

1. Both run PAIR. On a LAN they discover each other over mDNS; on Tailscale or
   any multicast-free network use **Add node** with the address.
2. On the inviting machine: **Add node** (or Settings → Cluster) → pick the
   discovered node or type the address → invite. It shows a six-digit PIN.
3. On the invited machine: accept the invitation and type the PIN (desktop
   dialog, or TUI Cluster tab `a`).
4. Verify under Settings → Cluster → **Connected nodes**, or on Overview.

Trust is transitive: pairing A↔B and A↔C also lets B and C talk.

### Over Tailscale

- Prefer the MagicDNS name (`box.tailnet-name.ts.net`) over the 100.x.y.z
  address. PAIR re-resolves a name every probe; an IP literal is dead after a
  renumber. Never type `host:port` in the address; use **Service ports** for
  non-default ports.
- Tailscale ACL must allow, between the PAIR nodes, TCP 1234, 11434, 14318,
  14319, 14320, 14321, 14322, 14323 (see `docs/remote-networks.mdx` for a
  snippet). mDNS 5353/udp does not cross a tailnet and is not needed.
- A node added by address before it runs PAIR appears with `pair_node: false`
  and, if an engine is exposed on the tailnet address, gets routed to as a bare
  host in plaintext inside the tunnel. Once PAIR runs there it flips to a full
  peer automatically within a few probe cycles.

## Multi-node vLLM (tensor parallel across machines)

A vLLM instance started with `--tensor-parallel-size 2 --nnodes 2` spans two
machines: the head (`--node-rank 0`) owns the API on 8000, the worker
(`--node-rank 1 --headless`) opens no port. Run PAIR on both and pair both, but
only the head shows vLLM on; the worker shows no engine and that is correct.
Never restart the worker's container alone: it is half of the head's model.
Check with `docker inspect <name> --format '{{join .Config.Cmd " "}}'` and look
for `--node-rank`/`--headless` before calling a silent vLLM "hung".
Details: `docs/engine-lifecycle.mdx`, "One instance can span several machines".

## Ports

| Port | Purpose |
| --- | --- |
| 11434 | Ollama-compatible proxy (clients talk here). Ollama engine itself moves to 11435+ |
| 1234 | OpenAI-compatible proxy for LM Studio **and vLLM** (clients talk here). LM Studio engine on 1235+ |
| 8000 | vLLM engine (adopted in place; never moved) |
| 5353/udp | mDNS discovery (LAN only) |
| 14318 | node-info: hardware, telemetry, service map |
| 14319 | service-error sync |
| 14320 | workload propagation |
| 14321 | pairing and membership |
| 14322 | model inventory (`em`, mTLS from peers) |
| 14323 | remote engine control (`ec`, mTLS) |

Proxies accept plaintext only from the machine's own loopback. A peer arrives
over cluster mTLS. A `403` on a proxy port from another machine is correct
behaviour, not a bug.

## Use it

- **Endpoints** in the top toolbar lists the local URLs. OpenAI-style clients use
  `http://127.0.0.1:1234/v1/chat/completions`; Ollama-style use
  `http://127.0.0.1:11434/api/chat`. Name the model exactly as `/v1/models` or
  `/api/tags` lists it. The proxy routes to whichever node holds it.
- vLLM and LM Studio models appear together in one `/v1/models`.

## Diagnose a failed invite or an engine-less node

Run from the inviting machine, replacing the address:

```bash
tailscale ping -c 2 <addr>                      # tunnel up?
for p in 14318 14321 14322 11434 1234 8000; do
  printf "%s: " $p; nc -z -w 3 <addr> $p && echo open || echo closed; done
curl -s http://<addr>:14318/v1/node-info | head -c 300   # PAIR running there?
curl -s http://<addr>:8000/version                        # vLLM reachable?
```

| Symptom | Meaning | Fix |
| --- | --- | --- |
| 14321 closed, 14318 closed | PAIR is not running on the peer | build and run `nvpair-tui` there, invite again |
| only 8000 open | bare vLLM host; routable, not pairable | fine as is, or install PAIR there for telemetry, scheduling and mTLS |
| only 22 open, peer "runs vLLM" | vLLM bound to 127.0.0.1 | install PAIR there (it adopts loopback engines), or restart vLLM with `--host 0.0.0.0` |
| `probe-failed` error after 30 s | nothing answered on any port | as above; if added by IP and the box was renumbered, re-add by hostname |
| 14318 answers but no models | not paired yet; inventory is served only to pinned peers | complete pairing |

Desktop logs: run the app from `desktop/` with `npm start` and read stdout, or
collect logs with `scripts/collect-logs.sh`. Manual-node probe results appear as
`node/discovered` / `node/updated` lines with `ollama_up`, `lmstudio_up`,
`vllm_up`, `node_info_up`, `pair_node`.

## How PAIR decides (what to expect, and why)

- **Routing precedence** inside the set of nodes advertising the model: manual
  pin (TUI Proxies tab only) → scheduler order (`pending + gpuPressure`, 0–3
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
  move it: Ollama and vLLM are process-managed (port change refused), LM Studio
  can be stopped with `lms server stop` and restarted on the new port. An
  unknown process on a port is never killed; the proxy moves and warns instead.
- **Engine CLIs** are not on PATH. Ollama lives in
  `<app data>/engine-bin/ollama/`; point `OLLAMA_HOST` at the *engine* port
  (11435) to see the local machine, at 11434 to see the cluster. LM Studio uses
  `~/.lmstudio/bin/lms`. vLLM weights sit in `~/.cache/huggingface`.
- **Pairing PIN** is one attempt, 5 min TTL, six digits, low entropy. A wrong
  PIN or a restart mid-pairing ends the invite; issue a fresh one rather than
  retrying. Pair only on networks you trust.
- **Leaving.** Settings → Cluster → Leave (TUI `L`) on the node, or remove it
  from any member; removal takes effect on the peer's next request. Uninstall
  keeps app data; `scripts/wipe-app-data.sh --confirm` or Settings → Service →
  Reset app data clears it. Model weights are never touched.
- **Never run `nvpair-tui` and the desktop app on the same machine at once**;
  each starts its own broker and worker tree and they fight over ports, engines,
  and settings.
- **Mixed PAIR versions in one cluster are unsupported**: the mTLS channel must
  match on both sides. Update every node.

## Not in the playbook, true of this fork

- Test suites write into the real application data directory
  (`~/Library/Application Support/Nvidia Corporation/Personal AI Router` on
  macOS). After running `go test` in `services/tests` or `lmstudio-proxy`, delete
  `lmstudio-proxy-port.json` there, or the OpenAI proxy starts on the wrong port.
- Automatic tailnet peer discovery is not implemented; add peers by name.
