#!/usr/bin/env bash
# COI-13: git auth failures must not hang and must mention credential knobs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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
OUT="$("$ROOT/spool" add secret --git 'git@github.com:spool-nope/nope.git' --version '*' 2>&1)"
RC=$?
set -e
if [[ "$RC" -eq 0 ]]; then
  echo "smoke_auth: expected git failure" >&2
  exit 1
fi
echo "$OUT" | grep -q "git failed"
echo "$OUT" | grep -q "ssh-agent"
echo "$OUT" | grep -q "GIT_ASKPASS"
echo "$OUT" | grep -q "insteadOf"

PRE="$ROOT/scratch/proj_auth_preamble"
rm -rf "$PRE"
mkdir -p "$PRE/src"
cat > "$PRE/coil.toml" <<'EOF'
[package]
name = "preamble"
version = "0.0.1"
[module]
roots = ["./src"]
[env]
allow_exec = true
EOF
echo "// app" > "$PRE/src/main.hy"
export SPOOL_PROJECT="$PRE"
unset GIT_SSH_COMMAND
"$ROOT/spool" add local --path "$ROOT/examples/greet"
grep -q "GIT_TERMINAL_PROMPT=0" "$PRE/.spool/fetch.sh"

echo "smoke_auth: ok"
