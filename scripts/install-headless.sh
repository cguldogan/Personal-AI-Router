#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# install-headless.sh — put PAIR's services on a Linux or macOS machine that has
# no desktop, and run them under tmux with the terminal interface.
#
#   curl -fsSL https://raw.githubusercontent.com/cguldogan/Personal-AI-Router/feat/vllm-tailscale/scripts/install-headless.sh | bash
#
# What it does, in order:
#   1. Detects OS and CPU architecture.
#   2. Downloads the matching prebuilt bundle from the fork's latest GitHub
#      release (no Go needed). With NVPAIR_FROM_SOURCE=1, or when no release
#      asset exists, it clones the branch and builds with Go instead.
#   3. Installs into $NVPAIR_HOME (default ~/pair): bin/ plus pair-start.sh.
#   4. Starts nvpair-tui inside a tmux session named "pair" (installs tmux if
#      it can), or leaves it stopped with NVPAIR_NO_START=1.
#
# Re-running upgrades in place: it stops the tmux session, swaps bin/, and
# starts again. Cluster identity and pairings live in the per-user data
# directory, not under $NVPAIR_HOME, so they survive an upgrade.
#
# Environment overrides:
#   NVPAIR_REPO=owner/name     GitHub repository to install from
#   NVPAIR_BRANCH=name         branch for a source build
#   NVPAIR_VERSION=tag         release tag instead of the latest release
#   NVPAIR_HOME=dir            install directory
#   NVPAIR_FROM_SOURCE=1       build with Go instead of downloading
#   NVPAIR_NO_START=1          install only
set -euo pipefail

REPO="${NVPAIR_REPO:-cguldogan/Personal-AI-Router}"
BRANCH="${NVPAIR_BRANCH:-feat/vllm-tailscale}"
HOME_DIR="${NVPAIR_HOME:-$HOME/pair}"
MIN_GO="1.25"

log()  { printf '\033[1m[pair]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[pair] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

case "$(uname -s)" in
    Linux)  OS=linux ;;
    Darwin) OS=darwin ;;
    *) die "unsupported OS $(uname -s); use the desktop installer or build.bat on Windows" ;;
esac
case "$(uname -m)" in
    x86_64|amd64)  ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) die "unsupported architecture $(uname -m)" ;;
esac
log "target $OS/$ARCH, install dir $HOME_DIR"

need() { command -v "$1" >/dev/null 2>&1; }
need curl || die "curl is required"
need tar  || die "tar is required"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- obtain bin/
fetch_release() {
    local api tag url
    if [[ -n "${NVPAIR_VERSION:-}" ]]; then
        api="https://api.github.com/repos/$REPO/releases/tags/$NVPAIR_VERSION"
    else
        api="https://api.github.com/repos/$REPO/releases/latest"
    fi
    local json
    json="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$api" 2>/dev/null || true)"
    [[ -n "$json" ]] || return 1
    tag="$(printf '%s' "$json" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
    url="$(printf '%s' "$json" | grep -o '"browser_download_url": *"[^"]*pair-services-[^"]*-'"$OS-$ARCH"'\.tar\.gz"' | sed 's/.*"\(https[^"]*\)"/\1/' | head -1)"
    [[ -n "$url" ]] || return 1
    log "downloading $tag bundle for $OS/$ARCH"
    curl -fL --progress-bar -o "$WORK/bundle.tgz" "$url"
    mkdir -p "$WORK/bundle" && tar xzf "$WORK/bundle.tgz" -C "$WORK/bundle"
    BIN_SRC="$(find "$WORK/bundle" -type d -name bin | head -1)"
    [[ -n "$BIN_SRC" && -x "$BIN_SRC/nvpair-tui" ]] || return 1
}

ensure_go() {
    if need go && [[ "$(go version | sed -E 's/.*go([0-9]+\.[0-9]+).*/\1/')" == "$(printf '%s\n%s\n' "$MIN_GO" "$(go version | sed -E 's/.*go([0-9]+\.[0-9]+).*/\1/')" | sort -V | tail -1)" ]]; then
        return
    fi
    local gover
    gover="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -1)"
    log "installing $gover into $HOME/.local/go (no root needed)"
    curl -fL --progress-bar -o "$WORK/go.tgz" "https://go.dev/dl/${gover}.${OS}-${ARCH}.tar.gz"
    rm -rf "$HOME/.local/go" && mkdir -p "$HOME/.local" && tar xzf "$WORK/go.tgz" -C "$HOME/.local"
    export PATH="$HOME/.local/go/bin:$PATH"
}

build_from_source() {
    need git || die "git is required for a source build"
    need jq  || die "jq is required for a source build (apt install jq / brew install jq)"
    ensure_go
    log "cloning $REPO@$BRANCH"
    git clone -q --depth 1 --branch "$BRANCH" "https://github.com/$REPO.git" "$WORK/src"
    (cd "$WORK/src/services" && ./build.sh >/dev/null)
    BIN_SRC="$WORK/src/services/build/bin"
}

BIN_SRC=""
if [[ "${NVPAIR_FROM_SOURCE:-0}" == "1" ]]; then
    build_from_source
elif ! fetch_release; then
    log "no prebuilt bundle for $OS/$ARCH in $REPO releases; building from source"
    build_from_source
fi

# ---------------------------------------------------------------- install
if need tmux && tmux has-session -t pair 2>/dev/null; then
    log "stopping the running PAIR (tmux session 'pair')"
    tmux kill-session -t pair
    sleep 2
fi
mkdir -p "$HOME_DIR"
rm -rf "$HOME_DIR/bin.new" && cp -R "$BIN_SRC" "$HOME_DIR/bin.new"
chmod +x "$HOME_DIR/bin.new/"*
rm -rf "$HOME_DIR/bin.old"
[[ -d "$HOME_DIR/bin" ]] && mv "$HOME_DIR/bin" "$HOME_DIR/bin.old"
mv "$HOME_DIR/bin.new" "$HOME_DIR/bin"

cat > "$HOME_DIR/pair-start.sh" <<'EOF'
#!/usr/bin/env bash
# Start PAIR's terminal interface (and the services it supervises) in a tmux
# session named "pair" so it survives SSH disconnects.
#   attach: tmux attach -t pair      stop: tmux kill-session -t pair
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
command -v tmux >/dev/null || { echo "tmux is required (apt install tmux / brew install tmux)" >&2; exit 1; }
if tmux has-session -t pair 2>/dev/null; then echo "PAIR is already running: tmux attach -t pair"; exit 0; fi
tmux new -d -s pair "cd '$DIR/bin' && ./nvpair-tui --log-level info 2>>'$DIR/pair.log'"
echo "PAIR started in tmux session 'pair'. Attach: tmux attach -t pair   Log: $DIR/pair.log"
EOF
chmod +x "$HOME_DIR/pair-start.sh"
log "installed $("$HOME_DIR/bin/nvpair-tui" --version) to $HOME_DIR/bin"

# ---------------------------------------------------------------- start
if [[ "${NVPAIR_NO_START:-0}" == "1" ]]; then
    log "not started (NVPAIR_NO_START=1). Start with: $HOME_DIR/pair-start.sh"
    exit 0
fi
if ! need tmux; then
    if need apt-get && need sudo; then sudo apt-get install -y -q tmux >/dev/null || true; fi
    if need brew; then brew install tmux >/dev/null || true; fi
fi
need tmux || die "tmux is not installed; install it, then run $HOME_DIR/pair-start.sh"
"$HOME_DIR/pair-start.sh"
sleep 5
if "$HOME_DIR/bin/nvpair-tui" members >/dev/null 2>&1; then
    log "PAIR is up. Cluster:"
    "$HOME_DIR/bin/nvpair-tui" members || true
else
    log "PAIR is starting; check with: $HOME_DIR/bin/nvpair-tui members"
fi
cat <<EOF

Next steps
  Pair with another machine that runs PAIR:
    from the other machine, Add node -> this machine's address -> invite, then here:
      NVPAIR_PIN=<six digits> $HOME_DIR/bin/nvpair-tui accept
    or invite from here (prints the PIN to type on the other side):
      $HOME_DIR/bin/nvpair-tui invite <other-address> --wait
  Watch it:              tmux attach -t pair      (detach with Ctrl-b d)
  Engines:               a vLLM on :8000, SGLang on :30000, Ollama on :11434, or LM Studio on :1234 is adopted automatically
  Ports to allow in:     1234 11434 14318 14319 14320 14321 14322 14323 (TCP)
  Docs:                  docs/remote-networks.mdx, docs/terminal-interface.mdx
EOF
