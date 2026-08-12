#!/usr/bin/env bash
# COI-15: transitive fetch/lock and diamond conflict.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COIL_BIN="${COIL:-coil}"
CACHE="$ROOT/scratch/cache_trans"
BASE="$ROOT/scratch/trans"

if [[ ! -x "$COIL_BIN" ]]; then
  if ! command -v "$COIL_BIN" >/dev/null 2>&1; then
    echo "smoke_transitive: coil not found (set COIL)" >&2
    exit 1
  fi
fi

rm -rf "$CACHE" "$BASE"
mkdir -p "$BASE"

init_git() {
  local dir="$1"
  git init -q "$dir"
  git -C "$dir" config user.email "spool@test"
  git -C "$dir" config user.name "spool"
}

commit_tag() {
  local dir="$1"
  local msg="$2"
  local tag="$3"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "$msg"
  git -C "$dir" tag "$tag"
}

# c v1.0.0 and v1.2.0 and v2.0.0
C="$BASE/c"
mkdir -p "$C/src"
cat > "$C/coil.toml" <<'EOF'
[package]
name = "c"
version = "1.0.0"
[module]
roots = ["./src"]
EOF
echo "// c" > "$C/src/lib.hy"
init_git "$C"
commit_tag "$C" "c 1.0.0" v1.0.0
sed -i 's/1.0.0/1.2.0/' "$C/coil.toml"
commit_tag "$C" "c 1.2.0" v1.2.0
sed -i 's/1.2.0/2.0.0/' "$C/coil.toml"
commit_tag "$C" "c 2.0.0" v2.0.0
C_URL="file://$C"

# a depends on c ^1.0
A="$BASE/a"
mkdir -p "$A/src"
cat > "$A/coil.toml" <<EOF
[package]
name = "a"
version = "0.1.0"
[module]
roots = ["./src"]
[dependencies]
c = { git = "$C_URL", version = "^1.0" }
EOF
echo "// a" > "$A/src/lib.hy"
init_git "$A"
commit_tag "$A" "a 0.1.0" v0.1.0
A_URL="file://$A"

# b depends on c ^1.2 (compatible with a)
B="$BASE/b"
mkdir -p "$B/src"
cat > "$B/coil.toml" <<EOF
[package]
name = "b"
version = "0.1.0"
[module]
roots = ["./src"]
[dependencies]
c = { git = "$C_URL", version = "^1.2" }
EOF
echo "// b" > "$B/src/lib.hy"
init_git "$B"
commit_tag "$B" "b 0.1.0" v0.1.0
B_URL="file://$B"

# d depends on c ^2.0 (conflicts with a)
D="$BASE/d"
mkdir -p "$D/src"
cat > "$D/coil.toml" <<EOF
[package]
name = "d"
version = "0.1.0"
[module]
roots = ["./src"]
[dependencies]
c = { git = "$C_URL", version = "^2.0" }
EOF
echo "// d" > "$D/src/lib.hy"
init_git "$D"
commit_tag "$D" "d 0.1.0" v0.1.0
D_URL="file://$D"

write_app() {
  local dest="$1"
  mkdir -p "$dest/src"
  cat > "$dest/coil.toml" <<EOF
[package]
name = "app"
version = "0.0.1"
[module]
roots = ["./src"]
[env]
allow_exec = true
EOF
  echo "// app" > "$dest/src/main.hy"
}

export COIL="$COIL_BIN"
export COIL_CACHE_DIR="$CACHE"

OK="$BASE/ok"
write_app "$OK"
export SPOOL_PROJECT="$OK"
"$ROOT/spool" add a --git "$A_URL" --version "^0.1"
"$ROOT/spool" add b --git "$B_URL" --version "^0.1"
grep -q "name = 'c'" "$OK/coil.lock"
grep -q "tag = 'v1.2.0'" "$OK/coil.lock"
test -L "$OK/.spool/deps/c"
test -L "$OK/.spool/deps/a"
test -L "$OK/.spool/deps/b"

BAD="$BASE/bad"
write_app "$BAD"
export SPOOL_PROJECT="$BAD"
"$ROOT/spool" add a --git "$A_URL" --version "^0.1"
set +e
OUT="$("$ROOT/spool" add d --git "$D_URL" --version "^0.1" 2>&1)"
RC=$?
set -e
if [[ "$RC" -eq 0 ]]; then
  echo "smoke_transitive: expected diamond failure" >&2
  exit 1
fi
echo "$OUT" | grep -q "diamond conflict for c"
echo "$OUT" | grep -q "a requires"
echo "$OUT" | grep -q "d requires"

echo "smoke_transitive: ok"
