<!--
SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Installing this fork

This fork of [NVIDIA Personal AI Router](https://github.com/NVIDIA/Personal-AI-Router)
adds three things that are proposed upstream but not yet merged:

- **vLLM** as a third inference engine (upstream PR #9).
- **Nodes across an overlay network** such as a Tailscale tailnet, added by
  address or MagicDNS name and treated as full peers (upstream PR #10).
- **Scripted pairing** for headless machines: `nvpair-tui accept --pin …`
  (upstream PR #11).

Everything below is for the branch `feat/vllm-tailscale`, which carries all
three. Builds from this fork are **unsigned**; they are not NVIDIA releases.

## Pick the path for each machine

| Machine | Path |
| --- | --- |
| Linux GPU box with no desktop (DGX, DGX Spark, a server) | [Headless](#headless-linux-or-macos) |
| Linux or macOS with a desktop | the `.deb` or `.dmg` from [Releases](../../releases), or [build from source](#desktop-application-from-source) |
| Windows | the `.exe` from [Releases](../../releases), or build from source |

Every machine that should take part in routing runs PAIR. A machine that only
runs an engine can be a routing target but cannot be paired.

## Headless (Linux or macOS)

One command. It downloads the prebuilt bundle for the machine's OS and CPU from
this fork's latest release, installs to `~/pair`, and starts PAIR's terminal
interface in a tmux session named `pair`. No Go or Node required.

```bash
curl -fsSL https://raw.githubusercontent.com/cguldogan/Personal-AI-Router/feat/vllm-tailscale/scripts/install-headless.sh | bash
```

Useful variants:

```bash
NVPAIR_FROM_SOURCE=1 bash install-headless.sh   # build with Go instead (installs Go under ~/.local if missing; needs git and jq)
NVPAIR_NO_START=1    bash install-headless.sh   # install only
NVPAIR_HOME=/opt/pair bash install-headless.sh  # different directory
```

Re-running the same command upgrades in place. Pairings and identity live in the
per-user data directory and survive upgrades.

After it starts:

```bash
tmux attach -t pair              # the terminal interface; detach with Ctrl-b d
~/pair/bin/nvpair-tui members    # cluster membership, from any shell
```

An engine already running on the box is adopted automatically: vLLM on port
8000, Ollama on 11434, LM Studio on 1234. A vLLM that spans several machines
(`--nnodes N`) is adopted on its head node only; the headless ranks correctly
show no engine.

## Desktop application from a release package

[Releases](../../releases) carries `NVPAIR-Setup-<version>-<arch>.dmg` (macOS,
Apple Silicon), `.deb` (Debian/Ubuntu, x64 and arm64), and `.exe` (Windows x64).
Install them the way the upstream README describes. They are **unsigned**:
macOS blocks the first launch until you right-click the app and choose Open (or
run `xattr -d com.apple.quarantine "/Applications/NVIDIA Personal AI Router.app"`),
and Windows shows a SmartScreen prompt. A package from here never checks an
update feed; upgrade by installing the next release over it. Settings, cluster
identity, and pairings are kept.

## Desktop application from source

Needs Go 1.25+, Node 25.5+ (Node 23 works in practice), and `jq`.

```bash
git clone https://github.com/cguldogan/Personal-AI-Router.git   # default branch: feat/vllm-tailscale
cd Personal-AI-Router/desktop
npm install
npm start                        # builds the services, then opens the app
```

To produce an installable package instead, run the matching script from
`desktop/package.json`, for example `npm run build:electron:mac:arm64` or
`npm run build:electron:linux:x64`. Output lands under `desktop/release/`.

## Pair the machines

Trust between machines is a six-digit PIN exchange over TCP 14321. On a LAN the
machines find each other; across Tailscale or any network without multicast, add
by address.

From the desktop app: **Add node** → type the other machine's address or
MagicDNS name (`box.tailnet-name.ts.net`) → invite. The app shows a PIN. On the
headless box:

```bash
NVPAIR_PIN=123456 ~/pair/bin/nvpair-tui accept
```

Or the other way round, from the headless box:

```bash
~/pair/bin/nvpair-tui invite <desktop-address> --wait    # prints the PIN to type in the app
```

Two headless boxes pair each other with `invite` on one and `accept` on the
other. Trust is transitive: pairing A with B and A with C also connects B and C.

Ports each PAIR machine must accept from the others: TCP 1234, 11434, 14318,
14319, 14320, 14321, 14322, 14323. On a Tailscale tailnet with the default
"allow all" policy nothing needs opening; a locked-down ACL snippet is in
[docs/remote-networks.mdx](docs/remote-networks.mdx).

## Use it

Point any OpenAI-compatible client at `http://127.0.0.1:1234/v1` on a machine
running PAIR, or any Ollama client at `http://127.0.0.1:11434`. `GET /v1/models`
lists every model the cluster serves; a request naming one is routed to a node
that holds it, over mutual TLS. **Endpoints** in the desktop app shows the same.

## If something does not work

- **"Pairing failed"** — the other machine is not running PAIR, or port 14321 is
  blocked. `curl http://<addr>:14318/v1/node-info` answers when PAIR is up.
- **Node shows but no models** — pair it first; a node serves its inventory only
  to paired peers.
- **Node shows no engine** — nothing is listening on the engine's default port on
  that machine, or it is a headless rank of a multi-node vLLM.

More: [docs/remote-networks.mdx](docs/remote-networks.mdx),
[docs/terminal-interface.mdx](docs/terminal-interface.mdx),
[docs/engine-lifecycle.mdx](docs/engine-lifecycle.mdx), and the upstream
[README](README.md).
