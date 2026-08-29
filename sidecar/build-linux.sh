#!/usr/bin/env bash
#
# Builds the Linux sidecar binary. Node's SEA format cannot cross-compile, so
# this has to run on Linux — WSL, a container, or CI all work:
#
#     wsl bash build-linux.sh          # from Windows, with WSL installed
#     bash build-linux.sh              # from inside Linux
#
# Two things it handles that a bare `node build.mjs` does not:
#
#   1. Building on a Windows drive mount (/mnt/c) is very slow and the
#      node_modules there holds win32 binaries, so sources are copied to the
#      Linux filesystem, built there, and only the binary is copied back.
#   2. Finding a Linux Node when the PATH is full of Windows ones. Under WSL,
#      `npm` often resolves to /mnt/c/Program Files/nodejs/npm, which would
#      produce a Windows build.
#
# Do not strip the result. The SEA blob does not survive it — the binary
# segfaults on start.

set -euo pipefail

NODE_VERSION="v22.18.0"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${IQ_BUILD_DIR:-$HOME/.cache/iq-sidecar-build}"

echo "==> Locating a Linux Node"
NODE_BIN=""
for candidate in "$HOME/.local/node22/bin" "$(dirname "$(command -v node 2>/dev/null || echo /nonexistent)")"; do
  if [ -x "$candidate/node" ] && "$candidate/node" --version >/dev/null 2>&1; then
    # Reject anything living on a Windows mount.
    case "$candidate" in
      /mnt/*) continue ;;
    esac
    NODE_BIN="$candidate"
    break
  fi
done

if [ -z "$NODE_BIN" ]; then
  echo "    No Linux Node found. Installing $NODE_VERSION under ~/.local (no sudo)."
  DEST="$HOME/.local/node22"
  mkdir -p "$DEST"
  curl -fsSL -o /tmp/node-iq.tar.xz \
    "https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION-linux-x64.tar.xz"
  tar -xJf /tmp/node-iq.tar.xz -C "$DEST" --strip-components=1
  rm -f /tmp/node-iq.tar.xz
  NODE_BIN="$DEST/bin"
fi

export PATH="$NODE_BIN:$PATH"
echo "    node $(node --version) at $(command -v node)"

echo "==> Staging sources in $WORK_DIR"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
# Every TypeScript source, not an enumerated list: a hardcoded set silently
# omits new modules, and the failure surfaces as a typecheck error much later.
cp "$SRC_DIR"/*.ts "$WORK_DIR/"
for f in package.json tsconfig.json build.mjs; do
  cp "$SRC_DIR/$f" "$WORK_DIR/$f"
done
cd "$WORK_DIR"

echo "==> npm install"
npm install --no-audit --no-fund --loglevel=error

echo "==> Typecheck"
npx tsc --noEmit

echo "==> Build"
node build.mjs

echo "==> Verifying the binary starts"
PORT=$(( 20000 + RANDOM % 20000 ))
./bin/iq-sidecar --port "$PORT" --token buildcheck >/tmp/iq-buildcheck.log 2>&1 &
CHECK_PID=$!
# Give it a moment, then confirm it answers and is bound to loopback only.
for _ in $(seq 1 20); do
  sleep 0.5
  if curl -fsS -m 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    break
  fi
done

if ! curl -fsS -m 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
  kill "$CHECK_PID" 2>/dev/null || true
  echo "    FAILED: the built binary does not answer. See /tmp/iq-buildcheck.log" >&2
  exit 1
fi

UNAUTH=$(curl -s -o /dev/null -w '%{http_code}' -m 2 "http://127.0.0.1:$PORT/read?signature=x")
kill "$CHECK_PID" 2>/dev/null || true

if [ "$UNAUTH" != "401" ]; then
  echo "    FAILED: expected 401 without a token, got $UNAUTH" >&2
  exit 1
fi
echo "    starts, and refuses unauthenticated calls"

echo "==> Installing into $SRC_DIR/bin"
mkdir -p "$SRC_DIR/bin"
cp bin/iq-sidecar "$SRC_DIR/bin/iq-sidecar"

echo
echo "Done: $SRC_DIR/bin/iq-sidecar ($(stat -c%s bin/iq-sidecar) bytes)"
echo "The executable bit is lost on a Windows mount; IQHost re-applies it"
echo "with chmod +x after extracting to user://bin at startup."
