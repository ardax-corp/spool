#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COIL_BIN="${COIL:-coil}"
FIX="$ROOT/scratch/fixture_repo"
CACHE="$ROOT/scratch/cache"
PROJ="$ROOT/scratch/proj_add"
PATHLIB="$ROOT/scratch/pathlib"

rm -rf "$FIX" "$CACHE" "$PROJ" "$PATHLIB"
mkdir -p "$FIX" "$PROJ/src" "$PATHLIB/src"

git init -q "$FIX"
git -C "$FIX" config user.email "spool@test"
git -C "$FIX" config user.name "spool"
echo "v1" > "$FIX/README.md"
mkdir -p "$FIX/src"
echo "// fixture lib" > "$FIX/src/lib.hy"
git -C "$FIX" add -A
git -C "$FIX" commit -q -m "v1"
git -C "$FIX" tag v1.0.0
echo "v1.1" > "$FIX/README.md"
git -C "$FIX" add -A
git -C "$FIX" commit -q -m "v1.1"
git -C "$FIX" tag v1.1.0
URL="file://$FIX"

cat > "$PROJ/coil.toml" <<EOF
[package]
name = "smoke-add"
version = "0.0.1"

[module]
roots = ["./src"]

[env]
allow_exec = true
EOF
echo "// consumer" > "$PROJ/src/main.hy"

echo "// path lib" > "$PATHLIB/src/lib.hy"

export COIL="$COIL_BIN"
export COIL_CACHE_DIR="$CACHE"
export SPOOL_PROJECT="$PROJ"

"$ROOT/spool" add fixture --git "$URL" --version "^1.0"
test -L "$PROJ/.spool/deps/fixture"
grep -q "name = 'fixture'" "$PROJ/coil.lock"
grep -q "tag = 'v1.1.0'" "$PROJ/coil.lock"
grep -q 'fixture = { git =' "$PROJ/coil.toml"
grep -q '.spool/deps' "$PROJ/coil.toml"

"$ROOT/spool" add local_lib --path "$PATHLIB"
test -L "$PROJ/.spool/deps/local_lib"
grep -q 'local_lib = { path =' "$PROJ/coil.toml"
test -f "$PROJ/.spool/deps/local_lib/lib.hy"

echo "v1.2" > "$FIX/README.md"
git -C "$FIX" add -A
git -C "$FIX" commit -q -m "v1.2"
git -C "$FIX" tag v1.2.0

"$ROOT/spool" update fixture
grep -q "tag = 'v1.2.0'" "$PROJ/coil.lock"

echo "smoke_add: ok"
