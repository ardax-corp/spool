#!/usr/bin/env bash
# COI-11: install a git/path dep, `use` it, compile and run.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPOOL="${SPOOL_BIN:-$ROOT/target/spool}"
COIL_BIN="${COIL:-coil}"
GREET_SRC="$ROOT/examples/greet"
FIX="$ROOT/scratch/greet_repo"
CACHE="$ROOT/scratch/cache_consume"
GIT_PROJ="$ROOT/scratch/proj_consume_git"
PATH_PROJ="$ROOT/scratch/proj_consume_path"

if [[ ! -x "$COIL_BIN" ]]; then
  if ! command -v "$COIL_BIN" >/dev/null 2>&1; then
    echo "smoke_consume: coil not found (set COIL)" >&2
    exit 1
  fi
fi

rm -rf "$FIX" "$CACHE" "$GIT_PROJ" "$PATH_PROJ"
mkdir -p "$FIX" "$GIT_PROJ/src" "$PATH_PROJ/src"

cp -a "$GREET_SRC/." "$FIX/"
git init -q "$FIX"
git -C "$FIX" config user.email "spool@test"
git -C "$FIX" config user.name "spool"
git -C "$FIX" add -A
git -C "$FIX" commit -q -m "greet 0.1.0"
git -C "$FIX" tag v0.1.0
URL="file://$FIX"

write_consumer() {
  local dest="$1"
  cat > "$dest/coil.toml" <<EOF
[package]
name = "consume"
version = "0.0.1"

[module]
roots = ["./src"]

[entry]
file = "src/main.hy"
EOF
  cat > "$dest/src/main.hy" <<'EOF'
use greet::hello;
use io::sync::{print};

fn main() {
    match print(hello("spool")) {
        Result::Ok(_) => 0,
        Result::Err(_) => 0,
    };
}
EOF
}

export COIL="$COIL_BIN"
export COIL_CACHE_DIR="$CACHE"

write_consumer "$GIT_PROJ"
export SPOOL_PROJECT="$GIT_PROJ"
"$SPOOL" add greet --git "$URL" --version "^0.1"
test -L "$GIT_PROJ/.spool/deps/greet"
test -f "$GIT_PROJ/.spool/deps/greet/hello.hy"
GOT="$(cd "$GIT_PROJ" && "$SPOOL" run 2>/dev/null)"
test "$GOT" = "hello, spool"

write_consumer "$PATH_PROJ"
export SPOOL_PROJECT="$PATH_PROJ"
"$SPOOL" add greet --path "$GREET_SRC"
test -L "$PATH_PROJ/.spool/deps/greet"
test -f "$PATH_PROJ/.spool/deps/greet/hello.hy"
GOT="$(cd "$PATH_PROJ" && "$SPOOL" run 2>/dev/null)"
test "$GOT" = "hello, spool"

echo "smoke_consume: ok"
