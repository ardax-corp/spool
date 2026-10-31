#!/usr/bin/env bash
# Two projects on one machine pin different stdlib versions: each builds
# against its own pick, while projects on the same version share one cached
# checkout.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPOOL="${SPOOL_BIN:-$ROOT/target/spool}"
COIL_BIN="${COIL:-coil}"
BASE="$ROOT/scratch/stdlib_versions"
CACHE="$BASE/cache"

if [[ ! -x "$COIL_BIN" ]]; then
  if ! command -v "$COIL_BIN" >/dev/null 2>&1; then
    echo "smoke_stdlib_versions: coil not found (set COIL)" >&2
    exit 1
  fi
fi

. "$ROOT/scripts/smoke_stdlib.sh.inc"

rm -rf "$BASE"
mkdir -p "$BASE"

# A stdlib repo with v0.1.0 and v0.2.0; `num::stdlib_marker()` tells them apart.
STD="$BASE/stdlib"
mkdir -p "$STD"
cp -R "$SMOKE_STDLIB/src" "$STD/src"
cat > "$STD/coil.toml" <<'EOF'
[package]
name = "stdlib"
version = "0.1.0"
EOF
cp "$STD/src/num.coil" "$BASE/num.coil.orig"
mark() {
  cp "$BASE/num.coil.orig" "$STD/src/num.coil"
  printf '\nfn stdlib_marker() -> string {\n    return "%s";\n}\n' "$1" >> "$STD/src/num.coil"
}
git init -q "$STD"
git -C "$STD" config user.email "spool@test"
git -C "$STD" config user.name "spool"
mark one
git -C "$STD" add -A
git -C "$STD" commit -q -m "stdlib 0.1.0"
git -C "$STD" tag v0.1.0
mark two
sed -i.bak 's/0.1.0/0.2.0/' "$STD/coil.toml" && rm -f "$STD/coil.toml.bak"
git -C "$STD" add -A
git -C "$STD" commit -q -m "stdlib 0.2.0"
git -C "$STD" tag v0.2.0
URL="file://$STD"

write_app() {
  local dest="$1"
  mkdir -p "$dest/src"
  cat > "$dest/coil.toml" <<'EOF'
[package]
name = "app"
version = "0.0.1"

[module]
roots = ["./src"]

[entry]
file = "src/main.coil"
EOF
  cat > "$dest/src/main.coil" <<'EOF'
use num::{stdlib_marker};
use io::sync::{print};

fn main() {
    match print(stdlib_marker()) {
        Result::Ok(_) => 0,
        Result::Err(_) => 0,
    };
}
EOF
}

export COIL="$COIL_BIN"
export XDG_CACHE_HOME="$CACHE"
CACHE="$CACHE/coil"

run_app() {
  local dir="$1"
  (cd "$dir" && SPOOL_PROJECT="$dir" "$SPOOL" run 2>"$dir/run.err") || {
    cat "$dir/run.err" >&2
    return 1
  }
}

A="$BASE/a"
B="$BASE/b"
C="$BASE/c"
write_app "$A"
write_app "$B"
write_app "$C"
SPOOL_PROJECT="$A" "$SPOOL" add stdlib --git "$URL" --version "^0.1.0" >/dev/null
SPOOL_PROJECT="$B" "$SPOOL" add stdlib --git "$URL" --version "^0.2.0" >/dev/null
SPOOL_PROJECT="$C" "$SPOOL" add stdlib --git "$URL" --version "=0.2.0" >/dev/null

grep -q "tag = 'v0.1.0'" "$A/coil.lock"
grep -q "tag = 'v0.2.0'" "$B/coil.lock"

GOT_A="$(run_app "$A")"
GOT_B="$(run_app "$B")"
GOT_C="$(run_app "$C")"
if [[ "$GOT_A" != "one" || "$GOT_B" != "two" || "$GOT_C" != "two" ]]; then
  echo "smoke_stdlib_versions: a=$GOT_A b=$GOT_B c=$GOT_C (want one/two/two)" >&2
  exit 1
fi

# Different versions: two checkouts. Same version: one shared checkout.
real() { (cd "$1" && pwd -P); }
RA="$(real "$A/.spool/deps/stdlib")"
RB="$(real "$B/.spool/deps/stdlib")"
RC="$(real "$C/.spool/deps/stdlib")"
test "$RA" != "$RB"
test "$RB" = "$RC"

echo "smoke_stdlib_versions: ok"
