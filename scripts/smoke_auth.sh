#!/usr/bin/env bash
# COI-13: git auth failures must not hang and must mention credential knobs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPOOL="${SPOOL_BIN:-$ROOT/target/spool}"
COIL_BIN="${COIL:-coil}"
CACHE="$ROOT/scratch/cache_auth"
PROJ="$ROOT/scratch/proj_auth"

rm -rf "$CACHE" "$PROJ"
mkdir -p "$PROJ/src"
cat > "$PROJ/coil.toml" <<'EOF'
[package]
name = "auth"
version = "0.0.1"
[module]
roots = ["./src"]
[env]
allow_exec = true
EOF
echo "// app" > "$PROJ/src/main.hy"

export COIL="$COIL_BIN"
export COIL_CACHE_DIR="$CACHE"
export SPOOL_PROJECT="$PROJ"
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND=false

set +e
OUT="$("$SPOOL" add secret --git 'git@github.com:spool-nope/nope.git' --version '*' 2>&1)"
RC=$?
set -e
if [[ "$RC" -eq 0 ]]; then
  echo "smoke_auth: expected git failure" >&2
  exit 1
fi
echo "$OUT" | grep -q "git ls-remote failed"
echo "$OUT" | grep -q "ssh-agent"
echo "$OUT" | grep -q "GIT_ASKPASS"
echo "$OUT" | grep -q "insteadOf"
# A failed add leaves coil.toml as it was.
if grep -q secret "$PROJ/coil.toml"; then
  echo "smoke_auth: failed add was not rolled back" >&2
  exit 1
fi

# A credential prompt must never block: git runs with GIT_TERMINAL_PROMPT=0.
# With a fake askpass that would succeed, spool still must not prompt/hang.
export GIT_ASKPASS=/bin/false
set +e
timeout 30 "$SPOOL" add secret2 --git 'https://github.com/spool-nope-org/definitely-missing.git' >/dev/null 2>&1
RC=$?
set -e
if [[ "$RC" -eq 124 ]]; then
  echo "smoke_auth: spool hung on a credential prompt" >&2
  exit 1
fi

echo "smoke_auth: ok"
