#!/usr/bin/env bash
# Language-tool passthrough: run, test (forwarded flags), infect, fmt,
# dissect, debug, lsp and the raw `coil` escape hatch.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPOOL="${SPOOL_BIN:-$ROOT/target/spool}"
BASE="$ROOT/scratch/tools"

fail() {
  echo "smoke_tools: $*" >&2
  exit 1
}

rm -rf "$BASE"
mkdir -p "$BASE"
cd "$BASE"
"$SPOOL" new app --no-git >/dev/null 2>&1 || fail "new"
cd app

out="$("$SPOOL" run -- one two 2>/dev/null)" || fail "run"
[[ -n "$out" ]] || fail "run printed nothing"

"$SPOOL" test --no-shuffle --show-output >/dev/null 2>&1 || fail "test with forwarded flags"

# Rendered report (coil test --json → spool __render), plain when piped.
# A coil without `--json` events gets coil's own report instead.
coil_help="$("$SPOOL" coil test --help 2>&1 || true)"
if grep -q "NDJSON events" <<<"$coil_help"; then
  out="$("$SPOOL" test --seed 1 2>/dev/null)" || fail "rendered test"
  grep -q "test passed\|tests passed" <<<"$out" || fail "rendered test has no summary: $out"
  grep -q $'\x1b' <<<"$out" && fail "piped output must not be colored"
  # Capture before grepping: `grep -q` closing the pipe early would fail it.
  out="$("$SPOOL" test --color always 2>/dev/null)" || fail "test --color always"
  grep -q $'\x1b' <<<"$out" || fail "--color always printed no color"
  out="$("$SPOOL" test --json 2>/dev/null)" || fail "test --json"
  grep -q '"event":"summary"' <<<"$out" || fail "test --json passes events through"
  out="$("$SPOOL" test --plain 2>&1)" || fail "test --plain"
  grep -q "test result: ok" <<<"$out" || fail "test --plain shows coil's report"
  # A reader that goes away must not hang the renderer.
  timeout 60 "$SPOOL" test | head -n 1 >/dev/null || [[ ${PIPESTATUS[0]} -ne 124 ]] || fail "test | head hung"
  mkdir -p tests/red
  printf '%s\n' 'test("always red") {' '    assert(1 == 2, "one is not two")?;' '}' > tests/red/red.hy
  set +e
  out="$("$SPOOL" test 2>/dev/null)"
  rc=$?
  set -e
  [[ $rc -eq 1 ]] || fail "red test run exit $rc, want 1"
  grep -q "one is not two" <<<"$out" || fail "failure reason not shown: $out"
  rm -rf tests/red
else
  echo "smoke_tools: coil has no --json events; checking the fallback"
  out="$("$SPOOL" test 2>&1)" || fail "test fallback"
  grep -q "test result: ok" <<<"$out" || fail "fallback shows coil's report"
fi
"$SPOOL" test --coverage >/dev/null 2>&1 || fail "test --coverage"
[[ -f target/coverage/lcov.info ]] || fail "test --coverage wrote no lcov"

"$SPOOL" infect --json >infect.json 2>/dev/null || fail "infect --json"
grep -q '"score"' infect.json || fail "infect --json printed no score"
out="$("$SPOOL" infect 2>&1)" || fail "infect"
grep -q "mutation score" <<<"$out" || fail "infect shows no score"

"$SPOOL" fmt >/dev/null 2>&1 || fail "fmt"
"$SPOOL" fmt --check >/dev/null 2>&1 || fail "fmt --check after fmt"

"$SPOOL" dissect --no-source >/dev/null 2>&1 || fail "dissect defaults to [entry].file"

printf 'quit\n' | "$SPOOL" debug --batch >/dev/null 2>&1 || fail "debug defaults to [entry].file"

"$SPOOL" coil --version | grep -q '^coil ' || fail "coil passthrough"

# lsp: an initialize request must get a response on stdout.
body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}'
# Hold stdin open briefly: on EOF coil-lsp can exit before it flushes.
reply="$({ printf 'Content-Length: %d\r\n\r\n%s' "${#body}" "$body"; sleep 3; } \
  | timeout 20 "$SPOOL" lsp 2>/dev/null || true)"
grep -q '"capabilities"' <<<"$reply" || fail "lsp did not answer initialize"

echo "smoke_tools: ok"
