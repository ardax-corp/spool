#!/usr/bin/env bash
# Native packaging: a dependency's `[[ffi.native]]` row with a shared library
# (`path`) and a static archive (`static`). `spool build` links the archive
# into a native executable that runs with no shared library anywhere;
# `spool build --jit` packages the JIT runner, which loads the shared one.
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
# Without coil's native packaging only the prebuilt download and cache gc
# part (3) runs; it builds nothing.
LINKS=1
if ! "$COIL_BIN" package --help 2>&1 | grep -q -- '--link-static'; then
  echo "smoke_native_static: this coil has no native packaging; only checking prebuilt download and gc"
  LINKS=0
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

if [[ "$LINKS" == 1 ]]; then
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

# 2. JIT: --jit (and [build] mode = "jit") load the shared library instead.
"$CC" -shared -fPIC -o "$NATIVE/$LIB" "$NATIVE/stat.c"
(cd "$APP" && "$SPOOL" build --jit) >/dev/null || fail "jit build"
GOT="$(cd / && "$APP/target/app")"
[[ "$GOT" == "$WANT" ]] || fail "jit target/app printed '$GOT'"
ls "$HOME/.coil/natives/cache/stat/0.1.0/"*/"$LIB" >/dev/null || fail "jit build did not cache the shared native"
printf '\n[build]\nmode = "jit"\n' >> "$APP/coil.toml"
GOT="$(cd "$APP" && "$SPOOL" run)"
[[ "$GOT" == "$WANT" ]] || fail "spool run ([build] mode = jit) printed '$GOT'"
# --native overrides the manifest; the shared library is not needed.
rm -f "$NATIVE/$LIB"
GOT="$(cd "$APP" && "$SPOOL" run --native)"
[[ "$GOT" == "$WANT" ]] || fail "spool run --native printed '$GOT'"
fi

# 3. A prebuilt archive (static_url + static_sha256, `{target}` = host
#    triple) served over https from a local server: `spool download` fetches
#    it into the natives cache, the native build then links it offline, and
#    `spool cache gc` keeps it while a project declares it.
if ! command -v openssl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "smoke_native_static: ok (prebuilt part skipped: no openssl or python3)"
  exit 0
fi
TARGET="$(uname -m | sed 's/^arm64$/aarch64/; s/^amd64$/x86_64/')"
case "$(uname -s)" in
  Darwin) TARGET="$TARGET-apple-darwin" ;;
  *) if ldd --version 2>&1 | grep -qi musl; then TARGET="$TARGET-unknown-linux-musl"; else TARGET="$TARGET-unknown-linux-gnu"; fi ;;
esac
SRV="$S/srv"
mkdir -p "$SRV/$TARGET" "$S/pre/src"
printf 'long pre_mul(long a, long b) { return a * b; }\n' > "$S/pre.c"
"$CC" -c -fPIC -o "$S/pre.o" "$S/pre.c"
ar rcs "$SRV/$TARGET/libpre.a" "$S/pre.o"
if command -v sha256sum >/dev/null 2>&1; then
  SHA="$(sha256sum "$SRV/$TARGET/libpre.a" | awk '{print $1}')"
else
  SHA="$(shasum -a 256 "$SRV/$TARGET/libpre.a" | awk '{print $1}')"
fi
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
  -addext subjectAltName=DNS:localhost -keyout "$S/key.pem" -out "$S/cert.pem" >/dev/null 2>&1
PORT_FILE="$S/port"
cat > "$S/serve.py" <<'PY'
import functools, http.server, ssl, sys
srv, cert, key, port_file = sys.argv[1:]
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=srv)
httpd = http.server.HTTPServer(("localhost", 0), handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
open(port_file, "w").write(str(httpd.server_address[1]))
httpd.serve_forever()
PY
python3 "$S/serve.py" "$SRV" "$S/cert.pem" "$S/key.pem" "$PORT_FILE" 2>/dev/null &
SRV_PID=$!
trap 'kill "$SRV_PID" 2>/dev/null || true' EXIT
for _ in $(seq 50); do [[ -s "$PORT_FILE" ]] && break; sleep 0.1; done
[[ -s "$PORT_FILE" ]] || fail "https server did not start"
PORT="$(cat "$PORT_FILE")"
export CURL_CA_BUNDLE="$S/cert.pem"
export NO_PROXY="localhost,127.0.0.1${NO_PROXY:+,$NO_PROXY}"
export no_proxy="$NO_PROXY"

cat > "$S/pre/coil.toml" <<EOF
[package]
name = "pre"
version = "0.1.0"

[module]
roots = ["./src"]

[[ffi.native]]
name = "pre"
version = "0.1.0"
static_url = "https://localhost:$PORT/{target}/libpre.a"
static_sha256 = "$SHA"
EOF
cat > "$S/pre/src/pre.coil" <<'EOF'
extern "pre" {
    fn pre_mul(int a, int b) -> int;
}

fn mul(int a, int b) -> int {
    return pre_mul(a, b);
}
EOF
git init -q "$S/pre"
git -C "$S/pre" config user.email "spool@test"
git -C "$S/pre" config user.name "spool"
git -C "$S/pre" add -A
git -C "$S/pre" commit -q -m "pre 0.1.0"
git -C "$S/pre" tag v0.1.0

APP2="$S/app2"
mkdir -p "$APP2/src"
cat > "$APP2/coil.toml" <<EOF
[package]
name = "app2"
version = "0.0.1"

[module]
roots = ["./src"]

[entry]
file = "src/main.coil"

[ffi]
allow = ["pre"]

[dependencies]
$SMOKE_STDLIB_DEP
pre = { git = "file://$S/pre", version = "^0.1", trusted = true }
EOF
cat > "$APP2/src/main.coil" <<'EOF'
use pre::{mul};
use io::sync::{print};
use string::{format};

fn main() {
    match print(format("product %i", mul(6, 7))) {
        Result::Ok(_) => 0,
        Result::Err(_) => 0,
    };
}
EOF
export SPOOL_PROJECT="$APP2"
(cd "$APP2" && "$SPOOL" install) >/dev/null
ENTRY="$HOME/.coil/natives/static/pre/0.1.0/${SHA:0:16}"
out="$(cd "$APP2" && "$SPOOL" download 2>&1)" || fail "spool download: $out"
[[ -f "$ENTRY/libpre.a" ]] || fail "download did not cache the static archive: $out"
grep -q "1 installed" <<<"$out" || fail "download count: $out"
out="$(cd "$APP2" && "$SPOOL" download 2>&1)" || fail "second download: $out"
grep -q "0 installed, 1 skipped" <<<"$out" || fail "second download fetched again: $out"
# Offline from here: the build links the cached archive.
kill "$SRV_PID" 2>/dev/null || true
if [[ "$LINKS" == 1 ]]; then
  (cd "$APP2" && "$SPOOL" build) >/dev/null || fail "native build from the cached prebuilt archive"
  GOT="$(cd / && "$APP2/target/app2")"
  [[ "$GOT" == "product 42" ]] || fail "prebuilt target/app2 printed '$GOT'"
fi
# A cache entry whose sha256 no longer matches is fetched again (which fails
# offline), never used.
printf 'x' >> "$ENTRY/libpre.a"
if (cd "$APP2" && "$SPOOL" download) >/dev/null 2>&1; then
  fail "download accepted a cache entry whose sha256 no longer matches"
fi
cp "$SRV/$TARGET/libpre.a" "$ENTRY/libpre.a"

# gc keeps an entry a project declares and removes one none does.
export SPOOL_CACHE_GC_GRACE_MIN=0
STALE="$HOME/.coil/natives/static/pre/0.0.9/0123456789abcdef"
mkdir -p "$STALE"
: > "$STALE/libpre.a"
"$SPOOL" cache gc >/dev/null 2>&1 || fail "cache gc"
[[ -f "$ENTRY/libpre.a" ]] || fail "cache gc removed a declared static archive"
[[ ! -e "$HOME/.coil/natives/static/pre/0.0.9" ]] || fail "cache gc kept an unused static archive"
rm -rf "$APP2"
"$SPOOL" cache gc >/dev/null 2>&1 || fail "cache gc (project gone)"
[[ ! -e "$ENTRY" ]] || fail "cache gc kept the archive of a deleted project"

echo "smoke_native_static: ok"
