#!/usr/bin/env bash
# Several projects install the same dependency at once on a cold shared
# cache: every install succeeds and they share one checkout.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPOOL="${SPOOL_BIN:-$ROOT/target/spool}"
COIL_BIN="${COIL:-coil}"
GREET_SRC="$ROOT/examples/greet"
BASE="$ROOT/scratch/parallel"
CACHE="$BASE/cache"
N=6
ROUNDS=3

if [[ ! -x "$COIL_BIN" ]]; then
  if ! command -v "$COIL_BIN" >/dev/null 2>&1; then
    echo "smoke_parallel_install: coil not found (set COIL)" >&2
    exit 1
  fi
fi

rm -rf "$BASE"
mkdir -p "$BASE"

FIX="$BASE/greet"
cp -a "$GREET_SRC/." "$FIX/"
git init -q "$FIX"
git -C "$FIX" config user.email "spool@test"
git -C "$FIX" config user.name "spool"
git -C "$FIX" add -A
git -C "$FIX" commit -q -m "greet 0.1.0"
git -C "$FIX" tag v0.1.0
URL="file://$FIX"

for i in $(seq 1 "$N"); do
  mkdir -p "$BASE/p$i/src"
  cat > "$BASE/p$i/coil.toml" <<EOF
[package]
name = "p$i"
version = "0.0.1"

[module]
roots = ["./src"]

[dependencies]
greet = { git = "$URL", version = "^0.1" }
EOF
done

export COIL="$COIL_BIN"
export COIL_CACHE_DIR="$CACHE"

for round in $(seq 1 "$ROUNDS"); do
  rm -rf "$CACHE" "$BASE"/p*/coil.lock "$BASE"/p*/.spool
  pids=()
  for i in $(seq 1 "$N"); do
    SPOOL_PROJECT="$BASE/p$i" "$SPOOL" install >"$BASE/p$i.out" 2>&1 &
    pids+=("$!")
  done
  failed=0
  for i in $(seq 1 "$N"); do
    if ! wait "${pids[$((i - 1))]}"; then
      echo "smoke_parallel_install: round $round: p$i failed:" >&2
      cat "$BASE/p$i.out" >&2
      failed=1
    fi
  done
  [[ "$failed" -eq 0 ]] || exit 1
  first="$(cd "$BASE/p1/.spool/deps/greet" && pwd -P)"
  for i in $(seq 2 "$N"); do
    test "$(cd "$BASE/p$i/.spool/deps/greet" && pwd -P)" = "$first"
  done
  test "$(ls "$CACHE/git/checkouts" | wc -l | tr -d ' ')" = 1
done

# A lock left by a spool that was killed (its pid is gone) is taken over.
BARE="$(cd "$BASE/p1/.spool/deps/greet" && git rev-parse --path-format=absolute --git-common-dir)"
test ! -e "$BARE.lock"
sh -c 'exit 0' &
dead=$!
wait "$dead"
mkdir "$BARE.lock"
echo "$dead" > "$BARE.lock/pid"
rm -rf "$CACHE/git/checkouts"
SPOOL_PROJECT="$BASE/p1" "$SPOOL" install >/dev/null 2>&1
test -d "$(cd "$BASE/p1/.spool/deps/greet" && pwd -P)"
test ! -e "$BARE.lock"

echo "smoke_parallel_install: ok"
