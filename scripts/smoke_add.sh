#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPOOL="${SPOOL_BIN:-$ROOT/target/spool}"
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

"$SPOOL" add fixture --git "$URL" --version "^1.0"
test -L "$PROJ/.spool/deps/fixture"
grep -q "name = 'fixture'" "$PROJ/coil.lock"
grep -q "tag = 'v1.1.0'" "$PROJ/coil.lock"
grep -q 'fixture = { git =' "$PROJ/coil.toml"
# coil.toml is never edited for roots; spool passes .spool/deps as --root.
if grep -q '.spool/deps' "$PROJ/coil.toml"; then
  echo "smoke_add: coil.toml should not be rewritten" >&2
  exit 1
fi

"$SPOOL" add local_lib --path "$PATHLIB"
test -L "$PROJ/.spool/deps/local_lib"
grep -q 'local_lib = { path =' "$PROJ/coil.toml"
test -f "$PROJ/.spool/deps/local_lib/lib.hy"

echo "v1.2" > "$FIX/README.md"
git -C "$FIX" add -A
git -C "$FIX" commit -q -m "v1.2"
git -C "$FIX" tag v1.2.0

"$SPOOL" update fixture
grep -q "tag = 'v1.2.0'" "$PROJ/coil.lock"

# remove drops the manifest line, the lock row, and the link.
"$SPOOL" remove fixture
if grep -q 'fixture' "$PROJ/coil.toml" "$PROJ/coil.lock"; then
  echo "smoke_add: remove left fixture behind" >&2
  exit 1
fi
test ! -e "$PROJ/.spool/deps/fixture"
test -L "$PROJ/.spool/deps/local_lib"

echo "smoke_add: ok"
