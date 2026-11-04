#!/usr/bin/env bash
# Native packaging: a dependency's `[[ffi.native]]` row with a shared library
# (`path`) and a static archive (`static`). `spool build` links the archive
# into a native executable that runs with no shared library anywhere;
# `spool build --vm` packages the VM runner, which loads the shared one.
#
#   stat: src/stat.coil declares `extern "stat" { fn stat_add(...) }`;
#         native/ holds the C source, built in the checkout into
#         libstat.so and libstat.a.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPOOL="${SPOOL_BIN:-$ROOT/target/spool}"
COIL_BIN="${COIL:-coil}"
S="$ROOT/scratch/native_static"

fail() {
  echo "smoke_native_static: $*" >&2
  exit 1
}

if ! command -v "$COIL_BIN" >/dev/null 2>&1 && [[ ! -x "$COIL_BIN" ]]; then
  fail "coil not found (set COIL)"
fi
if ! "$COIL_BIN" package --help 2>&1 | grep -q -- '--link-static'; then
  echo "smoke_native_static: skipped (this coil has no native packaging)"
  exit 0
fi
CC="${CC:-cc}"
if ! command -v "$CC" >/dev/null 2>&1 || ! command -v ar >/dev/null 2>&1; then
  echo "smoke_native_static: skipped (no C compiler or ar)"
  exit 0
fi
case "$(uname -s)" in
  Darwin) LIB=libstat.dylib ;;
  *) LIB=libstat.so ;;
esac

. "$ROOT/scripts/smoke_stdlib.sh.inc"

rm -rf "$S"
mkdir -p "$S/stat/src" "$S/stat/native"

cat > "$S/stat/coil.toml" <<'EOF'
[package]
name = "stat"
version = "0.1.0"

[module]
roots = ["./src"]

[ffi]
search_paths = ["./native"]

[[ffi.native]]
name = "stat"
version = "0.1.0"
path = "./native"
static = "./native/libstat.a"
EOF
cat > "$S/stat/src/stat.coil" <<'EOF'
extern "stat" {
    fn stat_add(int a, int b) -> int;
}

fn add(int a, int b) -> int {
    return stat_add(a, b);
}
EOF
cat > "$S/stat/native/stat.c" <<'EOF'
long stat_add(long a, long b) { return a + b; }
EOF
printf '*.so\n*.dylib\n*.a\n*.o\n' > "$S/stat/.gitignore"
git init -q "$S/stat"
git -C "$S/stat" config user.email "spool@test"
git -C "$S/stat" config user.name "spool"
git -C "$S/stat" add -A
git -C "$S/stat" commit -q -m "stat 0.1.0"
git -C "$S/stat" tag v0.1.0

APP="$S/app"
mkdir -p "$APP/src"
cat > "$APP/coil.toml" <<EOF
[package]
name = "app"
version = "0.0.1"

[module]
roots = ["./src"]

[entry]
file = "src/main.coil"

[ffi]
allow = ["stat"]

[dependencies]
$SMOKE_STDLIB_DEP
stat = { git = "file://$S/stat", version = "^0.1", trusted = true }
EOF
cat > "$APP/src/main.coil" <<'EOF'
use stat::{add};
use io::sync::{print};
use string::{format};

fn main() {
    match print(format("sum %i", add(40, 2))) {
        Result::Ok(_) => 0,
        Result::Err(_) => 0,
    };
}
EOF

export COIL="$COIL_BIN"
export XDG_CACHE_HOME="$S/cache"
export HOME="$S/home"
mkdir -p "$HOME"
export SPOOL_PROJECT="$APP"
WANT="sum 42"
(cd "$APP" && "$SPOOL" install) >/dev/null
CHECKOUT="$(dirname "$(readlink -f "$APP/.spool/deps/stat")")"
NATIVE="$CHECKOUT/native"

# Not built yet: spool names the archive it expects before coil runs.
if out="$(cd "$APP" && "$SPOOL" build 2>&1)"; then
  fail "native build succeeded with no libstat.a"
fi
grep -q "static library $NATIVE/libstat.a does not exist" <<<"$out" || fail "missing-archive error: $out"

"$CC" -c -fPIC -o "$NATIVE/stat.o" "$NATIVE/stat.c"
ar rcs "$NATIVE/libstat.a" "$NATIVE/stat.o"

# 1. Native (the default): linked in, runs from anywhere with no shared
#    library and nothing in the natives cache.
(cd "$APP" && "$SPOOL" build) >/dev/null || fail "native build"
GOT="$(cd / && "$APP/target/app")"
[[ "$GOT" == "$WANT" ]] || fail "native target/app printed '$GOT'"
[[ ! -e "$HOME/.coil/natives/cache/stat" ]] || fail "a static native was put in the natives cache"

# 2. VM: --vm (and [build] mode = "vm") load the shared library instead.
"$CC" -shared -fPIC -o "$NATIVE/$LIB" "$NATIVE/stat.c"
(cd "$APP" && "$SPOOL" build --vm) >/dev/null || fail "vm build"
GOT="$(cd / && "$APP/target/app")"
[[ "$GOT" == "$WANT" ]] || fail "vm target/app printed '$GOT'"
ls "$HOME/.coil/natives/cache/stat/0.1.0/"*/"$LIB" >/dev/null || fail "vm build did not cache the shared native"
printf '\n[build]\nmode = "vm"\n' >> "$APP/coil.toml"
GOT="$(cd "$APP" && "$SPOOL" run)"
[[ "$GOT" == "$WANT" ]] || fail "spool run ([build] mode = vm) printed '$GOT'"
# --native overrides the manifest; the shared library is not needed.
rm -f "$NATIVE/$LIB"
GOT="$(cd "$APP" && "$SPOOL" run --native)"
[[ "$GOT" == "$WANT" ]] || fail "spool run --native printed '$GOT'"

echo "smoke_native_static: ok"
