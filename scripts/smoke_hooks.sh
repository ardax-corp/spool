#!/usr/bin/env bash
# COI-227: hook trust gates. No host sh for [scripts] / [package].include.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COIL_BIN="${COIL:-coil}"
CACHE="$ROOT/scratch/cache_hooks"
BASE="$ROOT/scratch/hooks"

if [[ ! -x "$COIL_BIN" ]]; then
  if ! command -v "$COIL_BIN" >/dev/null 2>&1; then
    echo "smoke_hooks: coil not found (set COIL)" >&2
    exit 1
  fi
fi

rm -rf "$CACHE" "$BASE"
mkdir -p "$BASE"

plant_hooks() {
  local dest="$1"
  mkdir -p "$dest/hooks"
  cat > "$dest/hooks/preinstall.sh" <<'EOS'
#!/bin/sh
touch "${SPOOL_PROJECT:-.}/HOOK_RAN"
EOS
  cat > "$dest/hooks/include.sh" <<'EOS'
#!/bin/sh
touch "${SPOOL_PROJECT:-.}/HOOK_RAN"
EOS
  chmod +x "$dest/hooks/preinstall.sh" "$dest/hooks/include.sh"
}

write_app() {
  local dest="$1"
  local name="$2"
  rm -rf "$dest"
  mkdir -p "$dest/src"
  plant_hooks "$dest"
  cat > "$dest/coil.toml" <<EOF
[package]
name = "$name"
version = "0.0.1"
include = "./hooks/include.sh"

[module]
roots = ["./src"]
[env]
allow_exec = true

[scripts]
pre_install = "./hooks/preinstall.sh"
post_install = "./hooks/preinstall.sh"
pre_update = "./hooks/preinstall.sh"
post_update = "./hooks/preinstall.sh"
EOF
  echo "// app" > "$dest/src/main.hy"
}

write_lib() {
  local dest="$1"
  local name="$2"
  rm -rf "$dest"
  mkdir -p "$dest/src"
  plant_hooks "$dest"
  cat > "$dest/coil.toml" <<EOF
[package]
name = "$name"
version = "1.0.0"
include = "./hooks/include.sh"
[module]
roots = ["./src"]
EOF
  echo "// lib" > "$dest/src/lib.hy"
}

assert_hooks_idle() {
  local proj="${1:-$SPOOL_PROJECT}"
  if [[ -f "$proj/HOOK_RAN" ]]; then
    echo "smoke_hooks: hook ran as a side effect ($proj/HOOK_RAN)" >&2
    exit 1
  fi
}

HELP="$("$ROOT/spool" help)"
echo "$HELP" | grep -q -- "--ignore-scripts"
echo "$HELP" | grep -q "allow-include"

export COIL="$COIL_BIN"
export COIL_CACHE_DIR="$CACHE"

# Default install: allow_exec is on, hooks stay off, no sh.
APP="$BASE/app"
write_app "$APP" "app"
export SPOOL_PROJECT="$APP"
"$ROOT/spool" install
assert_hooks_idle "$APP"

# Flag is accepted and still does not exec.
"$ROOT/spool" --ignore-scripts install
assert_hooks_idle "$APP"
"$ROOT/spool" install --ignore-scripts
assert_hooks_idle "$APP"

# Path dep with include-hook: still no sh without allowlist.
LIB="$BASE/httplib"
write_lib "$LIB" "http"
"$ROOT/spool" add http --path "$LIB"
test -L "$APP/.spool/deps/http"
assert_hooks_idle "$APP"

# Explicit consumer allowlist is recorded in coil.lock (not coil.toml).
"$ROOT/spool" allow-include http
grep -q "\[hooks\]" "$APP/coil.lock"
grep -q "allow_include" "$APP/coil.lock"
grep -q "http" "$APP/coil.lock"
assert_hooks_idle "$APP"

# Allowlisted still does not exec in this PR (no 103/104 runners).
"$ROOT/spool" --ignore-scripts install
assert_hooks_idle "$APP"

# Git dep with include-hook: install does not sh, even with allow_exec.
FIX="$BASE/fixture"
write_lib "$FIX" "fixture"
git init -q "$FIX"
git -C "$FIX" config user.email "spool@test"
git -C "$FIX" config user.name "spool"
git -C "$FIX" add -A
git -C "$FIX" commit -q -m "init"
git -C "$FIX" tag v1.0.0
GITURL="file://$FIX"

GITAPP="$BASE/gitapp"
write_app "$GITAPP" "gitapp"
export SPOOL_PROJECT="$GITAPP"
"$ROOT/spool" add fixture --git "$GITURL" --version "^1.0"
test -L "$GITAPP/.spool/deps/fixture"
assert_hooks_idle "$GITAPP"
if grep -q "hook_path" "$GITAPP/coil.lock"; then
  echo "smoke_hooks: unexpected hook_path pin without 104 runner" >&2
  exit 1
fi

echo "smoke_hooks: ok"
