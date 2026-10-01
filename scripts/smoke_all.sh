#!/usr/bin/env bash
# Run every smoke script against the packaged spool (./bootstrap.sh first).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export SPOOL_BIN="${SPOOL_BIN:-$ROOT/target/spool}"
if [[ ! -x "$SPOOL_BIN" ]]; then
  echo "smoke_all: $SPOOL_BIN missing; run ./bootstrap.sh" >&2
  exit 1
fi
for s in "$ROOT"/scripts/smoke_*.sh; do
  [[ "$(basename "$s")" == smoke_all.sh ]] && continue
  echo "== $(basename "$s")"
  "$s"
done
echo "smoke_all: ok"
