#!/usr/bin/env bash
# spool#38 / coil-tls#17: a dependency's native library, located by that
# dependency's own coil.toml, works for `spool test`, `spool build` and
# `spool run` of a consumer that ships no native of its own.
#
#   nat  (coil-tls shape): src/nat.hy calls dload("nat"); native/ holds the C
#        source and, once built in the checkout, libnat.so; coil.toml has
#        [ffi] search_paths = ["./native"] and a [[ffi.native]] row.
#   mid  (coil-http shape): uses nat, and its coil.toml keeps the old
#        consumer-layout path ./.spool/deps/nat/native.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPOOL="${SPOOL_BIN:-$ROOT/target/spool}"
COIL_BIN="${COIL:-coil}"
S="$ROOT/scratch/dep_natives"

if [[ ! -x "$COIL_BIN" ]]; then
  if ! command -v "$COIL_BIN" >/dev/null 2>&1; then
    echo "smoke_dep_natives: coil not found (set COIL)" >&2
    exit 1
  fi
fi
CC="${CC:-cc}"
if ! command -v "$CC" >/dev/null 2>&1; then
  echo "smoke_dep_natives: skipped (no C compiler)"
  exit 0
fi
case "$(uname -s)" in
  Darwin) LIB=libnat.dylib ;;
  *) LIB=libnat.so ;;
esac

fail() {
  echo "smoke_dep_natives: $*" >&2
  exit 1
}

. "$ROOT/scripts/smoke_stdlib.sh.inc"

rm -rf "$S"
mkdir -p "$S/nat/src" "$S/nat/native" "$S/mid/src"

cat > "$S/nat/coil.toml" <<'EOF'
[package]
name = "nat"
version = "0.1.0"

[module]
roots = ["./src"]

[ffi]
search_paths = ["./native"]

[[ffi.native]]
name = "nat"
version = "0.1.0"
path = "./native"
EOF
cat > "$S/nat/src/nat.hy" <<'EOF'
use ffi::{declare, dload, invoke};
use ffi::types::{Int};

/// a + b through libnat; -1 when the library does not load.
fn add(int a, int b) -> int {
    let lib = match dload("nat") {
        Result::Ok(h) => h,
        Result::Err(_) => {
            return -1;
        },
    };
    let f = match declare(lib, "nat_add", (Int, Int), Int) {
        Result::Ok(v) => v,
        Result::Err(_) => {
            return -1;
        },
    };
    return match invoke(lib, f, (a, b)) {
        Result::Ok(v) => v,
        Result::Err(_) => -1,
    };
}
EOF
cat > "$S/nat/native/nat.c" <<'EOF'
long nat_add(long a, long b) { return a + b; }
EOF
printf '*.so\n*.dylib\n' > "$S/nat/.gitignore"

cat > "$S/mid/coil.toml" <<EOF
[package]
name = "mid"
version = "0.1.0"

[dependencies]
nat = { git = "file://$S/nat", version = "^0.1", trusted = true }

[module]
roots = ["./src"]

[ffi]
search_paths = ["./.spool/deps/nat/native"]
EOF
cat > "$S/mid/src/mid.hy" <<'EOF'
use nat::{add};
use string::{format};

fn sum_text(int a, int b) -> string {
    return format("sum %i", add(a, b));
}
EOF

for r in nat mid; do
  git init -q "$S/$r"
  git -C "$S/$r" config user.email "spool@test"
  git -C "$S/$r" config user.name "spool"
  git -C "$S/$r" add -A
  git -C "$S/$r" commit -q -m "$r 0.1.0"
  git -C "$S/$r" tag v0.1.0
done

build_native() {
  "$CC" -shared -fPIC -o "$1/$LIB" "$S/nat/native/nat.c"
}

# A consumer of mid; `extra` is appended to its [ffi] table.
write_consumer() {
  local dest="$1" extra="${2:-}"
  mkdir -p "$dest/src" "$dest/tests"
  cat > "$dest/coil.toml" <<EOF
[package]
name = "app"
version = "0.0.1"

[module]
roots = ["./src"]

[entry]
file = "src/main.hy"

[ffi]
allow = ["nat"]
$extra

[dependencies]
$SMOKE_STDLIB_DEP
mid = { git = "file://$S/mid", version = "^0.1" }
nat = { git = "file://$S/nat", version = "^0.1", trusted = true }
EOF
  cat > "$dest/src/main.hy" <<'EOF'
use mid::{sum_text};
use io::sync::{print};

fn main() {
    match print(sum_text(40, 2)) {
        Result::Ok(_) => 0,
        Result::Err(_) => 0,
    };
}
EOF
  cat > "$dest/tests/sum.hy" <<'EOF'
use tests::assert;
use mid::{sum_text};

test("dependency native loads") {
    assert!(sum_text(1, 2) == "sum 3");
}
EOF
}

export COIL="$COIL_BIN"
WANT="sum 42"

# 1. The native is built in the dependency's own checkout, as coil-tls's
#    docs say (`make -C <checkout>/native artifact`). Nothing in the consumer
#    names it.
export XDG_CACHE_HOME="$S/cache_a"
export HOME="$S/home_a"
mkdir -p "$HOME"
NATIVES="$HOME/.coil/natives"
APP="$S/app_checkout"
write_consumer "$APP"
export SPOOL_PROJECT="$APP"
(cd "$APP" && "$SPOOL" install) >/dev/null
NAT_CHECKOUT="$(dirname "$(readlink -f "$APP/.spool/deps/nat")")"
[[ -f "$NAT_CHECKOUT/coil.toml" ]] || fail "nat checkout not found at $NAT_CHECKOUT"
[[ ! -e "$APP/.spool/deps/nat/native" ]] || fail ".spool/deps/nat/native exists; the link layout changed"

# Not built yet: packaging names the checkout path it expects.
if out="$(cd "$APP" && "$SPOOL" build 2>&1)"; then
  fail "build succeeded with no $LIB anywhere"
fi
grep -q "$NAT_CHECKOUT/native/$LIB" <<<"$out" || fail "build error does not name the checkout native: $out"

build_native "$NAT_CHECKOUT/native"
(cd "$APP" && "$SPOOL" test) >/dev/null || fail "spool test (checkout native)"
GOT="$(cd "$APP" && "$SPOOL" run)"
[[ "$GOT" == "$WANT" ]] || fail "spool run printed '$GOT'"
# The built exe runs on its own, from anywhere: spool build put the native
# it packaged into the natives cache.
GOT="$(cd / && "$APP/target/app")"
[[ "$GOT" == "$WANT" ]] || fail "target/app printed '$GOT'"
ls "$NATIVES"/cache/nat/0.1.0/*/"$LIB" >/dev/null || fail "native not cached"
# A second build finds the cache entry and leaves it alone.
(cd "$APP" && "$SPOOL" build) >/dev/null || fail "rebuild"
grep -q '.spool/deps' "$APP/coil.toml" && fail "coil.toml gained a .spool/deps path"

# 2. The documented layout before spool#38: the consumer points its own
#    [ffi] search_paths at a sibling build. The dependency checkout (a fresh
#    cache) has no native; that sibling file is what gets tested and packaged.
export XDG_CACHE_HOME="$S/cache_b"
export HOME="$S/home_b"
mkdir -p "$HOME"
NATIVES="$HOME/.coil/natives"
SIB="$S/sibling/native"
mkdir -p "$SIB"
build_native "$SIB"
APP="$S/app_sibling"
write_consumer "$APP" "search_paths = [\"../sibling/native\"]"
export SPOOL_PROJECT="$APP"
(cd "$APP" && "$SPOOL" install) >/dev/null
NAT_CHECKOUT="$(dirname "$(readlink -f "$APP/.spool/deps/nat")")"
[[ ! -e "$NAT_CHECKOUT/native/$LIB" ]] || fail "fresh checkout already has $LIB"
(cd "$APP" && "$SPOOL" test) >/dev/null || fail "spool test (sibling native)"
GOT="$(cd "$APP" && "$SPOOL" run)"
[[ "$GOT" == "$WANT" ]] || fail "spool run (sibling) printed '$GOT'"

echo "smoke_dep_natives: ok"
