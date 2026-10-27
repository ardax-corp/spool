#!/usr/bin/env bash
# spool#30: a dependency whose modules live under src/<name>/ and that imports
# its own sibling modules (coil-tls `use tls::abi`, coil-http `use http::url`,
# coil-sdl `use simd`) resolves for the consumer without extra [module] roots.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPOOL="${SPOOL_BIN:-$ROOT/target/spool}"
COIL_BIN="${COIL:-coil}"
FIX="$ROOT/scratch/nest_repo"
CACHE="$ROOT/scratch/cache_nested"
GIT_PROJ="$ROOT/scratch/proj_nested_git"
PATH_PROJ="$ROOT/scratch/proj_nested_path"
OLD_PROJ="$ROOT/scratch/proj_nested_workaround"

if [[ ! -x "$COIL_BIN" ]]; then
  if ! command -v "$COIL_BIN" >/dev/null 2>&1; then
    echo "smoke_nested: coil not found (set COIL)" >&2
    exit 1
  fi
fi

. "$ROOT/scripts/smoke_stdlib.sh.inc"

rm -rf "$FIX" "$CACHE" "$GIT_PROJ" "$PATH_PROJ" "$OLD_PROJ"
mkdir -p "$FIX/src/nest" "$GIT_PROJ/src" "$PATH_PROJ/src" "$OLD_PROJ/src"

# Layout of coil-tls / coil-sdl: src/<name>.hy, src/<name>/*.hy and a second
# top-level module, all resolved through the package's own ./src root.
cat > "$FIX/coil.toml" <<'EOF'
[package]
name = "nest"
version = "0.1.0"

[module]
roots = ["./src"]
EOF
cat > "$FIX/src/nest.hy" <<'EOF'
use nest::inner::{twice};

fn shout(string s) -> string {
    return twice(s) + "!";
}
EOF
cat > "$FIX/src/nest/inner.hy" <<'EOF'
fn twice(string s) -> string {
    return s + s;
}
EOF
cat > "$FIX/src/extra.hy" <<'EOF'
use nest::{shout};

fn loud(string s) -> string {
    return "[" + shout(s) + "]";
}
EOF
git init -q "$FIX"
git -C "$FIX" config user.email "spool@test"
git -C "$FIX" config user.name "spool"
git -C "$FIX" add -A
git -C "$FIX" commit -q -m "nest 0.1.0"
git -C "$FIX" tag v0.1.0
URL="file://$FIX"

write_consumer() {
  local dest="$1"
  local roots="${2:-\"./src\"}"
  cat > "$dest/coil.toml" <<EOF
[package]
name = "consume_nested"
version = "0.0.1"

[module]
roots = [$roots]

[entry]
file = "src/main.hy"

[dependencies]
$SMOKE_STDLIB_DEP
EOF
  cat > "$dest/src/main.hy" <<'EOF'
use nest::{shout};
use nest::inner::{twice};
use extra::{loud};
use io::sync::{print};

fn main() {
    match print(twice("a") + " " + shout("b") + " " + loud("c")) {
        Result::Ok(_) => 0,
        Result::Err(_) => 0,
    };
}
EOF
}

export COIL="$COIL_BIN"
export COIL_CACHE_DIR="$CACHE"
WANT="aa bb! [cc!]"

write_consumer "$GIT_PROJ"
export SPOOL_PROJECT="$GIT_PROJ"
"$SPOOL" add nest --git "$URL" --version "^0.1"
GOT="$(cd "$GIT_PROJ" && "$SPOOL" run)"
test "$GOT" = "$WANT"
# coil.toml is never edited for roots.
if grep -q '.spool/deps' "$GIT_PROJ/coil.toml"; then
  echo "smoke_nested: coil.toml gained a .spool/deps root" >&2
  exit 1
fi

write_consumer "$PATH_PROJ"
export SPOOL_PROJECT="$PATH_PROJ"
"$SPOOL" add nest --path "$FIX"
GOT="$(cd "$PATH_PROJ" && "$SPOOL" run)"
test "$GOT" = "$WANT"

# The old workaround (the link as an extra [module] root) keeps working.
write_consumer "$OLD_PROJ" '"./src", ".spool/deps/nest"'
export SPOOL_PROJECT="$OLD_PROJ"
"$SPOOL" add nest --path "$FIX"
GOT="$(cd "$OLD_PROJ" && "$SPOOL" run)"
test "$GOT" = "$WANT"

echo "smoke_nested: ok"
