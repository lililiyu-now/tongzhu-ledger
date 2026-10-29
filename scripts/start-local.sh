#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
NODE_BIN="$(command -v node || true)"
if [ -z "$NODE_BIN" ] || ! "$NODE_BIN" -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 22 ? 0 : 1)' ; then
  BUNDLED_NODE="$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node"
  if [ -x "$BUNDLED_NODE" ]; then NODE_BIN="$BUNDLED_NODE"; else echo '请安装 Node.js 22 或更高版本。'; exit 1; fi
fi
exec "$NODE_BIN" scripts/local.mjs
