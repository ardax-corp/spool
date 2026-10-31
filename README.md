# spool

Project and dependency manager for [Coil](https://github.com/ardax-corp/coil-lang):
the high-level front end over the `coil` toolchain, shipped as one standalone
executable.

- **Projects**: `new`, `init`, `build`, `run`, `check`, `test`, `fmt`, `clean`
- **Dependencies**: git (semver tags or a pinned `rev`) and path deps, a
  `coil.lock`, transitive resolution, `add`/`remove`/`update`, `tree`, `outdated`
- **Natives**: `download` fetches `[[ffi.native]]` shared libraries
- **Tooling**: `doctor`, `cache`

coil does not read `[module].roots` from `coil.toml`, so module roots come
from `--root` flags. spool builds those flags from the manifest, the linked
dependencies (the stdlib is one of them), then runs `coil` for you.

## Install

Two ways: download the prebuilt `spool` from the `edge` release and let it
fetch the rest with `spool setup`, or build from source with `bootstrap.sh`
(the contributor path). Either way, spool needs a coil toolchain at run time;
see [What spool needs](#what-spool-needs). There is no global stdlib: each
project declares it as a dependency (see [The stdlib](#the-stdlib)).

### From the edge release

The [`edge` pre-release](https://github.com/ardax-corp/spool/releases/tag/edge)
is rebuilt from `main` after every green CI run. It is a snapshot, not a
stable release. It currently has:

| Platform | Archive |
|---|---|
| Linux x86-64 (glibc) | `spool-x86_64-unknown-linux-gnu.tar.gz` |
| Linux ARM64 (glibc) | `spool-aarch64-unknown-linux-gnu.tar.gz` |
| Linux x86-64 (musl) | `spool-x86_64-unknown-linux-musl.tar.gz` |
| macOS, Apple silicon | `spool-aarch64-apple-darwin.tar.gz` |

plus a `SHA256SUMS` file. A pushed `v*` tag publishes the same archives in a
release of its own. There is no build for macOS on Intel or for Windows
(spool needs a POSIX `sh`; use WSL); on those, use `bootstrap.sh` below
where the platform is supported. Each archive holds a single `spool`
executable.

**1. spool.** Download, verify and install it (set `TRIPLE` to your row
above):

```bash
TRIPLE=x86_64-unknown-linux-gnu    # or aarch64-unknown-linux-gnu, x86_64-unknown-linux-musl, aarch64-apple-darwin
BASE=https://github.com/ardax-corp/spool/releases/download/edge
mkdir -p ~/.local/bin && cd "$(mktemp -d)"
curl -fLO "$BASE/spool-$TRIPLE.tar.gz" -O "$BASE/SHA256SUMS"
grep " spool-$TRIPLE.tar.gz\$" SHA256SUMS | sha256sum -c -    # macOS: shasum -a 256 -c -
tar xzf "spool-$TRIPLE.tar.gz" -C ~/.local/bin
```

**2. coil.** Let spool fetch it into `~/.coil`, where it looks for it:

```bash
~/.local/bin/spool setup --channel edge   # or stable (default), or a release tag
```

Without `--channel` (or `COIL_CHANNEL`), `stable` falls back to `edge`
with a note while coil-lang has no tagged release; an explicit
`--channel stable` does not.

`spool setup` downloads `coil-<triple>.tar.gz` (the musl archive on a
musl host) from the coil-lang release of
that channel, checks it against the release's `SHA256SUMS` (a release without
one, or a mismatch, is refused), and unpacks the toolkit into `~/.coil/bin`
with its helper binaries (`coil-fmt`, `coil-test`, `coil-lsp`, …) next to
`coil`. Run it again to update; the toolkit is swapped in only once it is
complete. `COIL_HOME=DIR` installs into `DIR` instead; spool itself only
looks in `~/.coil`, so then set `COIL` as it tells you. `COIL_LANG_URL`
points it at another repository. It does not install a stdlib: projects
declare their own (an old `~/.coil/stdlib` is unused and can be deleted).

**3. Check.** Put `~/.local/bin` (and, if you like, `~/.coil/bin`) on your
`PATH` and run:

```bash
spool doctor
```

To do step 2 by hand instead, unpack the coil-lang
[`edge` release](https://github.com/ardax-corp/coil-lang/releases/tag/edge)
archive into `~/.coil/bin` (verify it against `SHA256SUMS` the same way as
spool).

### What spool needs

spool finds coil in this order: `$COIL`, `coil` on `PATH`, then
`~/.coil/bin/coil`. The stdlib is not looked up anywhere: it is the
`stdlib` dependency of the project, fetched and locked like any other.
Plain `coil` does not look for modules on its own; `--root` is how a compile
is told where modules live, and spool passes it for you.

Runtime requirements: host `git` and `sh`. `curl` is needed for `download`.

### With bootstrap.sh

`bootstrap.sh` builds spool from this checkout and can fetch everything
else in one go. It needs `git`, `sh` and `curl`:

```bash
git clone https://github.com/ardax-corp/spool.git && cd spool
./bootstrap.sh              # → target/spool
./bootstrap.sh --install    # also: ~/.local/bin/spool, and ~/.coil/bin/coil
                            # if bootstrap built or downloaded it
./bootstrap.sh --channel edge --install   # same, with coil from the edge snapshot
```

Without a coil release for your platform (or with `--from-source`), it
builds coil from source, which needs `cargo`, libffi and pcre2 dev files.

`bootstrap.sh` does this:

1. Looks for a usable coil: `$COIL`, `coil` on `PATH`, `~/.coil/bin/coil`, or a
   previous bootstrap build. A candidate needs to meet `COIL_MIN_VERSION`, have
   `coil package`, and compile a probe that uses `env::args/exit`. A
   previous bootstrap build is reused only while its checkout is still the
   newest `COIL_LANG_REF`; otherwise it is rebuilt (incrementally). It warns
   when the coil lacks `coil mutate` or `coil test --json`.
2. If none qualifies, it downloads the coil-lang GitHub release asset
   `coil-<triple>.tar.gz` of the chosen channel (see below), when one exists.
   When the release lists a `SHA256SUMS`, the archive is checked against it.
3. If there is no release either, it builds coil-lang `main` from source into
   `.bootstrap/coil-lang` (needs `cargo`, libffi and pcre2 dev files).
4. Fetches coil-stdlib, coil-toml and coil-json (at the `rev`s
   pinned in this repo's `coil.toml`) into `.bootstrap/`. Pass `--use-siblings`
   to build against `../coil-stdlib`, `../coil-toml` and `../coil-json` instead.
5. Runs `coil package spool.hy -o target/spool`.

### Coil channels

`--channel NAME` (or `COIL_CHANNEL`) picks which coil-lang release step 2
downloads:

| Channel | Release |
|---|---|
| `stable` (default) | the latest tagged release; pre-releases are never picked |
| `edge` | the rolling `edge` pre-release, rebuilt from coil-lang `main` after every green CI run (a snapshot, not a stable release) |
| a tag, e.g. `v0.2.0` | that release |

A channel other than `stable` is asked for on purpose, so step 1 is skipped
(only an explicit `$COIL` still wins) and the release is downloaded again on
every run, to follow the snapshot. A download is kept in
`.bootstrap/release` for the channel it came from only. `edge` requires the
release to publish `SHA256SUMS`; if it is missing or does not match,
bootstrap refuses the archive and falls back to the source build.
`GITHUB_TOKEN` is sent with the release lookup when set, which avoids API rate
limits on shared CI runners.

CI example (coil from edge, then spool built with it):

```bash
export COIL="$(./bootstrap.sh --channel edge --coil-only)"   # prints the coil path
./bootstrap.sh                                               # uses $COIL
```

Other flags: `--from-source` (skip installed coil and releases),
`--coil-only`. Overrides: `COIL_LANG_REPO/REF`, `COIL_STDLIB_REPO/REF`,
`COIL_TOML_REPO/REF`, `COIL_JSON_REPO/REF`, `COIL_STDLIB_DIR`, `COIL_TOML_DIR`,
`COIL_JSON_DIR`, `SPOOL_BOOTSTRAP_DIR`, `COIL_RELEASES_URL`.

## Quick start

```bash
spool new hello && cd hello
spool run                 # packages target/hello and runs it
spool run -- a b          # program arguments after --
spool test                # coil test with the project's roots
spool add greet --git https://github.com/ardax-corp/coil-greet.git --version '^0.1'
spool tree
```

`spool new <name> --lib` creates a library. Its entry module is
`src/<name>.hy`, so consumers write `use <name>::{item}`. More modules can
go in `src/<name>/` (`use <name>::client`) or next to it in `src/`; spool
passes each dependency's `src/` as a root, so consumers resolve them the
way the library resolves them itself.

## Commands

| Command | What it does |
|---|---|
| `new <name> [--lib] [--no-git]` / `init` | scaffold `coil.toml`, `src/`, `tests/`, `.gitignore` (and `git init`) |
| `build [-o PATH] [-O LEVEL]` | `coil package` of `[entry].file` (default `src/main.hy`) into `target/<name>`; the natives it pins go into the natives cache |
| `run [-O LEVEL] [-- ARGS]` | build, then exec `target/<name>` with ARGS and its exit code |
| `check` | `coil compile` without packaging |
| `clean [--all]` | remove `target/` (`--all`: also `.spool/`) |
| `test [PATH] [FLAGS]` | `coil test` (default `./tests`): `--coverage`, `--seed N`, `-j N`, `--fail-fast`, … |
| `coverage [PATH] [FLAGS]` | `test --coverage`: per-file coverage table and `target/coverage/lcov.info` (`--coverage-out F`, `--coverage-per-test F`) |
| `infect [PATH] [FLAGS]` | mutation testing (`coil mutate`): `--files GLOB`, `--operators`, `--min-score P`, `--json`, … |
| `fmt [--check] [PATHS]` | `coil fmt` (default `src tests`) |
| `debug [FILE] [FLAGS]` | `coil debug` on `[entry].file` (`--dap` for an IDE adapter) |
| `dissect [FILE] [FLAGS]` | `coil dissect` of `[entry].file` (`--fn`, `--il`, `--ast`, …) |
| `lsp` | `coil lsp` on stdio, started from the project root |
| `coil [ARGS]` | plain `coil ARGS` from the project root (no flags added) |
| `install [--locked] [--with-natives]` | fetch, resolve, prune and link dependencies |
| `add <name> --git URL [--version REQ \| --rev REV]` | declare a git dependency, then install (`REQ` may be `latest`) |
| `add <name> --path DIR` | declare a path dependency, then install |
| `remove <name>` | drop the dependency, prune `coil.lock` and stale links |
| `update [name]` | re-resolve to the newest allowed versions (moves `rev` branches and `latest`) |
| `tree` | print the dependency graph |
| `outdated` | locked vs newest compatible vs newest tag (`latest`: locked sha vs the current tip) |
| `download [EXE]` | fetch FFI natives for the project or a packaged EXE |
| `allow-include <name>` | allow a dependency's include-hook |
| `allow-comptime <name>` | let a dependency's compile-time code use its own `[comptime]` grants |
| `doctor` | check coil, stdlib, git, sh, curl, cache and project roots |
| `cache dir` / `cache clean` | show or clear the shared git cache |
| `cache gc [--dry-run]` | remove cached checkouts and clones no known project's `coil.lock` uses (see [Cache](#cache)) |

Commands that compile (`build`, `run`, `check`, `test`, `infect`, `debug`,
`dissect`) run `install` first when dependencies are declared but
`.spool/deps` does not exist yet.

`test`, `infect`, `fmt`, `debug`, `dissect` and `lsp` forward every flag to
coil unchanged, so `spool <cmd> --help` shows coil's own options and new coil
flags work without a spool release. spool adds the compile flags below and,
for `debug`/`dissect`, `[entry].file` when no file is named.

### Test and mutation reports

`test` and `infect` run coil with `--json` and render its event stream
while the run goes: one line per test file, failing cases with their reason
and captured output, then a summary (and coverage per file with
`--coverage`). `infect` lists surviving and untested mutants as they finish
and ends with the mutation score. The exit status is 1 on a failed test, a
score under `--min-score`, or a harness error.

| Flag | Effect |
|---|---|
| `--color auto\|always\|never` | default `auto`: color when stdout is a terminal, unless `NO_COLOR` is set or `TERM=dumb` |
| `--plain` | coil's own text report instead |
| `--json` | coil's raw NDJSON events (for tools); also implied by `--log-json` / `--log-lsp` |

This needs a coil whose `coil test` / `coil mutate` stream `--json` events
(ardax-corp/coil-lang#584). With an older coil, spool says so and shows
coil's own report; `spool infect` needs `coil mutate`. `spool doctor` lists
which of these the coil it found has.

`run` packages `target/<name>` rather than running the entry in memory:
`coil FILE` cannot pass program arguments, and the packaged binary sees a
normal argv.

Editors: point the Coil LSP client at `spool lsp`; it is the only thing to
start. From any folder inside the project it links missing dependencies
(scripts off), then starts `coil lsp` with the project directory
(`--workspace`) and the same roots (`[module].roots`, `.spool/deps`, the
stdlib, each dependency's `src/`) and grants as every other command, so imports resolve and granted
calls such as `env::exit` are not flagged, whatever folder the editor sent.
That needs a coil whose `coil lsp` accepts `--root` (ardax-corp/coil-lang#589)
and `--workspace`; with an older one spool passes what it accepts.

`add` and `remove` restore `coil.toml` and `coil.lock` if the install fails.

### Compile flags

spool runs `coil` from the project root with:

- `--root` for each `[module].roots` entry (default `./src`)
- `--root .spool/deps` when dependencies are linked
- `--root <stdlib>`: a manifest root that already is a stdlib (coil-stdlib
  itself), else the project's `stdlib` dependency (see [The stdlib](#the-stdlib)).
  A project without one compiles with no stdlib, and spool warns
- `--root <checkout>/src` for each linked dependency, after the stdlib (see
  [Linking](#linking))
- grants the manifest records: `[permissions]` (`read`, `write`, `net`,
  `env`, `exec`, `exit`, `attach` set to `true` give `--allow-<name>`, and
  `all = true` gives `--allow-all`), the older `[env]
  allow_exit/allow_ffi_exec` and `[ffi] allow_attach`, `[ffi]
  allow` (`--allow-dload`), and `[ffi] search_paths` (`--ffi-search-path`)
- `--ffi-search-path` for each linked dependency's own `[ffi] search_paths`,
  after the project's (see [Dependency natives](#dependency-natives))
- `dload` integrity, which coil no longer reads from `coil.toml` /
  `coil.lock` itself:
  - `--dload-pin STEM=SHA256` for each `coil.lock` `[[package.native]]`
    `sha256`. STEM is the native row's `stem` / `lib`, else the package name
    without its `coil-` prefix. A hash that is not 64 hex digits is skipped.
  - `--dload-trusted STEM` for each `trusted = true` dependency: its name,
    the name without `coil-` (`coil-crypto` → `crypto`), and the lock's
    native stems for it
- compile-time grants (see [Compile-time grants](#compile-time-grants)):
  `--comptime-read/-write/-env/-net` for the project's `[comptime]`
  keys, `--comptime-cache <project>/.comptime` (or `[comptime] cache`), and
  each `allow-comptime` dependency's own `[comptime]` grants scoped to its
  modules (`--comptime-env gen=TOKEN`)
- `coil package` (`spool build` / `run`) and `coil natives dump` also get
  one `--ffi-native name=…,version=…,path=…[,package=…][,requires=a;b][,requires-hint=…]`
  per `[[ffi.native]]` row (`path` made absolute, `,` in a value escaped as
  `\,`). `coil package` also gets each linked dependency's rows (see
  [Dependency natives](#dependency-natives)); `coil natives dump` gets the
  project's only

`coil.toml.example` lists every key spool reads.

A program needs a grant for each capability its `main` (or a test) can
reach: reading or writing files, the network, environment variables,
running programs (`exec`, for the built-in `process` module). coil names the
missing flag when one is not granted:

```toml
[permissions]
read = true
net = true
```

The coil binary is `$COIL`, then `coil` on `PATH`, then `~/.coil/bin/coil`.

## Dependencies

```toml
[dependencies]
greet = { git = "https://github.com/ardax-corp/coil-greet.git", version = "^0.1" }
toml  = { git = "https://github.com/ardax-corp/coil-toml.git", rev = "3e0da9d…" }
msgpack = { git = "https://github.com/ardax-corp/coil-msgpack.git", version = "latest" }
local = { path = "../local" }
```

- `version` is matched against `v`-prefixed or bare semver tags: `^`, `~`,
  `>=`, `>`, `<=`, `<`, `=`, exact, `*`, and comma-joined ranges
  (`">=1.2, <2"`). Prerelease tags are never picked by a range.
- `rev` pins a branch, tag or commit. The lock stores the resolved sha plus the
  `ref`. `install` keeps the pin, and `update` moves a branch pin. A
  dependency sets `version` or `rev`, not both.
- `version = "latest"` tracks the tip of the default branch, whatever it is
  called (`git ls-remote URL HEAD`), for libraries without release tags. It
  is locked like a branch pin, with `ref = 'HEAD'` and the resolved sha:
  `install` keeps the sha, and `update` moves it to the new tip. It works in
  transitive manifests too, and cannot be combined with `rev`.
- `spool add NAME --git URL` with neither `--version` nor `--rev` writes
  `version = "*"` (the newest release tag). When the repo has no version tags
  at all, it writes `version = "latest"` instead and prints a note:

  ```text
  spool: note: msgpack has no version tags; using version = "latest" (the default branch tip)
  ```
- `trusted = true` lets that dependency's `dload` stems skip the sha256 pin
  (`--dload-trusted`, see [Compile flags](#compile-flags)). The stem still
  needs `[ffi] allow`.

Resolution walks the reachable graph: the project, its path deps, and every
locked checkout's `coil.toml`. Compatible requirements unify. Incompatible
ones fail with the requesters named:

```text
diamond conflict for base: hello requires @dev, mid requires ^1
```

`latest` counts as a pin here: two `latest` requirements unify, but `latest`
together with a range or a different `rev` is a conflict
(`diamond conflict for l: a requires latest, d requires ^1.0`).

Lock rows nothing reaches any more are pruned. `install --locked` fails
instead of changing the lock (CI):

```text
coil.lock is out of date (needs fixture); run without --locked to update it
```

Every locked checkout is verified against its `content_hash` (the git tree
id). A mismatched checkout is deleted from the cache and the command fails.

Names and URLs from any manifest, including transitive ones, are validated.
Package names match `[A-Za-z_][A-Za-z0-9_-]*`. Git URLs must use `https://`,
`http://`, `ssh://`, `git://`, `git@host:`, `file://` or an absolute path.
Values reach `git`/`sh` only as positional arguments, never inside a script.

### Linking

```text
.spool/deps/<name>     -> <checkout>/src
.spool/deps/<name>.hy  -> <checkout>/src/<name>.hy   (when it exists)
```

spool passes `.spool/deps` as a root, and then each `<checkout>/src` (the
real path behind `.spool/deps/<name>`), so a dependency resolves its modules
for you the same way it does in its own repo:

| Import | Resolves to |
|---|---|
| `use toml::{Toml}` | `src/toml.hy`, through the file link (single-file libraries) |
| `use greet::hello` | `src/hello.hy`, through the directory link |
| `use tls::client::{enable}` | `src/tls/client.hy`, through the package's `src/` root |
| `use simd::{features}` (coil-sdl) | `src/simd.hy`, a second top-level module of the package |

Dependency roots come after the stdlib, so a package's top-level module never
shadows a stdlib module. A package without `src/` is linked, and used as a
root, at its checkout root. `coil.toml` is never edited, and consumers do not
add `.spool/deps/<name>` to `[module].roots` (an existing entry like that is
harmless).

### The stdlib

There is no global stdlib. Each project declares it like any other git
dependency, and `spool new` / `spool init` add it:

```toml
[dependencies]
stdlib = { git = "https://github.com/ardax-corp/coil-stdlib.git", version = "latest" }
```

`version = "latest"` follows coil-stdlib's tip (edge): `coil.lock` records
the commit in use and `spool update` moves it. That is risky, so spool warns
on `new` and on every install until it is pinned:

```toml
stdlib = { git = "https://github.com/ardax-corp/coil-stdlib.git", rev = "<full commit sha>" }
```

It is checked out into the shared cache like any package. Projects pinning
different versions each build against their own; projects on the same commit
share one checkout. A library that declares a stdlib requirement constrains
its consumers' stdlib like any shared dependency (a conflict is a diamond
error). `COIL_STDLIB_REPO` changes the URL `spool new` writes.

### Dependency natives

A package that ships a native library names it in its own `coil.toml`,
relative to its own checkout. coil-tls:

```toml
[ffi]
search_paths = ["./native"]

[[ffi.native]]
name = "tls"
version = "0.1.0"
path = "./native"
```

spool resolves those paths against the dependency's checkout (the directory
behind `.spool/deps/<name>`), never against the consumer:

- each dependency's `[ffi] search_paths` becomes `--ffi-search-path`, after
  the project's own and in dependency-name order. Only directories that exist
  inside the checkout are passed: an absolute or `..` path is dropped, and so
  is a consumer-layout path such as coil-http's `./.spool/deps/tls/native`,
  which no checkout has.
- `spool build` / `run` pass each dependency's `[[ffi.native]]` rows to
  `coil package` as `--ffi-native`, for every stem the project does not
  declare itself (the project's own row wins; between dependencies, the first
  by name). The library is taken from the first search directory that holds
  it, the file `spool test` loads (so a sibling build named in the project's
  own `[ffi] search_paths` still wins), else from the row's own `path`, where
  coil names the missing file.
- after packaging, `spool build` copies each library the exe pins into the
  natives cache (see [Native libraries](#native-libraries-spool-download)),
  where a packaged exe looks first. `target/<name>` then runs from any
  directory with no `spool download` and no URL. An entry already there with
  the right sha256 is left alone.

These paths only locate files. Loading one still needs the consumer's
`[ffi] allow` and a pin or `trusted = true`.

spool does not build natives. Build one in the dependency's checkout, whose
tree id ignores untracked files (`make -C "$(dirname "$(readlink -f
.spool/deps/tls)")/native" artifact` for coil-tls), or point the project's own
`[ffi] search_paths` at a sibling build. Until then, `spool build` fails with
coil's `expected library at <checkout>/native/libtls.so`.

## Engine range

A package may set `[package].coil` to a semver range. spool compares it with
`coil --version` of the coil it would run. Prerelease suffixes such as
`0.2.0-dev` are compared by their base version.

```toml
[package]
name = "http"
version = "1.2.0"
coil = ">=0.1.0"
```

The project, path deps and locked checkouts are checked before anything is
fetched. New checkouts are checked again before link:

```text
package http requires coil >=0.2.0, running 0.1.0
```

## Hook trust

Hooks are off by default. `may_run_hook` is the gate. Every host `sh` of a user
script goes through it first (`kind` `script` for current-project `[scripts]`,
`kind` `include` for a dependency `[package].include`).

`--enable-scripts` opts in. `--ignore-scripts` always wins, including in CI.
`SPOOL_IGNORE_SCRIPTS=0` is the same opt-in the gate already understands.

```bash
spool install --enable-scripts
spool install --ignore-scripts
spool allow-include http
```

`spool allow-include <name>` records the consumer allowlist in `coil.lock`,
not in `coil.toml`. spool rejects unknown `coil.toml` sections, so do not add
a `[hooks]` table there. `[package].include` is the include path on a
package. The allowlist is the lock `[hooks]` table:

```toml
[hooks]
allow_include = ['http']
```

`[[package]]` stores `hook_path` and `hook_hash` for include-hooks. Those
run after link when opted in. They still need `allow_include` plus a matching
path and hash. Empty hash is first-pin then the same gate. A present hash is
never rewritten. A missing lock row is deny, no `sh`.

`may_run_hook` raises these strings:

```text
hooks are off (--ignore-scripts)
include-hook for http is not allowlisted
untrusted hook: missing lock hash for http
hook path mismatch for http
hook hash mismatch for http
```

## Compile-time grants

Code coil runs while compiling (`comptime`, a `const`, a macro) does IO only
when the build grants it. `[comptime]` in `coil.toml` lists what the
project's own compile-time code may use:

```toml
[comptime]
read = ["schemas"]          # paths, relative to the project
write = ["gen"]
env = ["CI"]
net = ["api.example.com:443"]
cache = ".comptime"         # result cache (the default)
```

Each key becomes `--comptime-<key>` for every module of the project. Paths
are made absolute under the project root.

A dependency's `[comptime]` is ignored until the consumer allows it:

```bash
spool allow-comptime gen
```

That records the package in the lock `[hooks]` table, which install keeps:

```toml
[hooks]
allow_comptime = ['gen']
```

An allowed dependency's grants are scoped to its own top-level modules (the
`.hy` files and directories under its module root): `env = ["GEN_TOKEN"]`
in `gen` gives `--comptime-env gen=GEN_TOKEN`, so the project's modules do
not get them. Paths resolve under the dependency's checkout. A dependency
with `[comptime]` that is not allowed gets a note on stderr.

## Project scripts

The current project's `coil.toml` may declare lifecycle scripts. Paths are
relative to the project root. Missing keys are no-ops. Unknown keys are errors
(spool rejects unknown `coil.toml` keys).

```toml
[scripts]
pre_install = "./scripts/pre-install.sh"
post_install = "./scripts/post-install.sh"
pre_update = "./scripts/pre-update.sh"
post_update = "./scripts/post-update.sh"
```

Default is still off. `--enable-scripts` opts in on `install`, `add`, and
`update`. `--ignore-scripts` wins even when both flags are present.

With `--enable-scripts`:

- `spool install` runs `pre_install` then fetch/link, then `post_install`
- `spool update` runs `pre_update` / `post_update`
- `spool add` uses the install pair

`pre_*` runs after engine checks and before fetch/link. `post_*` runs after a
successful link. `sh` runs from the project root. Non-zero exit is
`spool: error: <path> exited <status>` and aborts. A missing file is
`spool: error: missing script <path>`.

Every `sh` goes through `may_run_hook` first (`kind` `script`). Scripts skip
the include allowlist. They still need a lock hash.

Hashes live in lock `[scripts]`, not on a `[[package]]` row. The hash is
`git hash-object` of the file. First opted-in run records path and hash.
After that, the existing pin is checked first. A changed file is a hash
mismatch. It does not `sh` and does not rewrite the lock:

```toml
[scripts]
pre_install = './scripts/pre-install.sh'
pre_install_hash = 'abc123'
post_install = './scripts/post-install.sh'
post_install_hash = 'def456'
```

That diagnostic is `hook hash mismatch for <package>`, using the current
`[package].name` (or `app` if the name is empty).

A dependency's `[scripts]` are not executed during a consumer install. Those
fire only when that repo is the current project.

## Include hooks

A library may declare a hook that runs when another project depends on it.

```toml
[package]
name = "native-bits"
include = "./hooks/include.sh"
```

The path is relative to that package's checkout, not the consumer. Missing
`include` is a no-op. A declared file that is not on disk is
`spool: error: missing include-hook <name> <path>`.

`spool install`, `add`, and `update` run include-hooks after link, including
transitives. `sh` runs from the checkout. `SPOOL_PROJECT` is still the
consumer.

Default is still off. `--enable-scripts` / `SPOOL_IGNORE_SCRIPTS=0` opt in.
`--ignore-scripts` wins even when both flags are present. Include-hooks also
need `spool allow-include <name>` on the consumer. Opt-in without that
allowlist is deny, no `sh`.

Every include `sh` goes through `may_run_hook` first (`kind` `include`). The
pin is `hook_path` / `hook_hash` on that dep's `[[package]]` row. The hash is
`git hash-object` of the file. First opted-in run records them when that row
exists and `hook_hash` is empty. No `[[package]]` row (a path dep, or any
name not in the lock) is missing lock hash: no first-pin, no `sh`. After a
pin exists, it is checked first. A changed include file is a hash mismatch.
It does not `sh` and does not rewrite the lock:

```toml
[[package]]
name = 'http'
hook_path = './hooks/include.sh'
hook_hash = 'abc123'
```

Non-zero exit aborts the consumer command:

```text
spool: error: include-hook http ./hooks/include.sh exited 9
```

## Install order

1. `coil.toml` parses; `[package].coil` of the project, path deps and cached
   checkouts
2. `pre_install` / `pre_update` if `--enable-scripts`
3. Check out every locked package and verify its tree id
4. Resolve (or, with `--locked`, fail if anything would change), then prune
5. Write `coil.lock` if it changed; engine check on new checkouts
6. Link `.spool/deps` (stale links removed)
7. Include-hooks (the hook can see its own checkout; `SPOOL_PROJECT` is the consumer)
8. `post_install` / `post_update` — only after a successful link
9. `--with-natives`: `download`

`add` and `remove` use the install pair; `update` uses the update pair.

## Native libraries (`spool download`)

Direct shared libraries declared in `[[ffi.native]]` (or embedded in a
packaged exe) are fetched into a content-addressed cache:

```toml
[[ffi.native]]
name = "regex"              # dload stem
package = "coil-regex"      # optional, default: name
version = "0.3.0"
path = "./native"           # holds libregex.so; coil hashes it
url = "https://example.com/coil-regex/0.3.0/libregex.so"
sha256 = "<64 hex digits>"  # optional; checks a fetch of a file not in path yet
requires = ["libpcre2-8.so.0"]
requires_hint = "apt install libpcre2-8-0"
```

```text
~/.coil/natives/cache/<package>/<version>/<sha256_16>/<filename>
```

A packaged exe looks there too. The sha256 and size come from
`coil natives dump --tsv` (`package, version, filename, sha256, size`); coil
carries no URLs, so each one is the `url` of the project's `[[ffi.native]]`
row with that package and version (for a packaged exe too: run it from the
project). Rows without a `url` are skipped: a packaged app also finds a
library beside the executable or in `lib/` there. `spool build` already puts
the libraries it packaged from local files into this cache (see
[Dependency natives](#dependency-natives)); for another machine, putting them
in place is up to you. Only https URLs are fetched. Each file is checked against the sha256
and size before it is moved into place. Transitive sonames (`requires`) must
come from the OS.

In project mode a row whose file is not in its `path` yet has nothing for
coil to hash: `coil natives dump` lists it as `missing`, with no sha256.
spool fetches it from `url` (https only) into the row's `path`, where
`spool build` hashes and pins it. With a `sha256` on the row the download is
checked against it first (on a mismatch the partial file is removed and
`download` fails). Without one it is placed unchecked, with a warning
(`WARNING: fetched … over https without a hash check …; coil package pins it
when it hashes it. Add sha256 = "<hex>" to [[ffi.native]] …`): until then
only https vouches for it. A file already in `path` is left alone. `sha256`
is 64 hex digits (any case; anything else is a manifest error); rows that
are present keep the pinned download above, whose sha256 comes from coil.

```bash
spool download ./hello          # a packaged exe
spool download                  # project [[ffi.native]]
spool install --with-natives
```

## Cache

Default root: `$XDG_CACHE_HOME/coil` or `~/.cache/coil` (the cache coil
itself uses). `[cache] dir` in `~/.config/coil/config.toml` wins.

```text
<cache_root>/git/
  <host>/<owner>/<repo>/     # bare clone
  checkouts/<tree-id>/       # detached worktree
  projects/<hash>            # a project that uses the cache (its root)
```

Checkouts are keyed by tree id: each version of a package gets its own, and
projects that lock the same content share one. Each project links
`.spool/deps/<name>` to the checkout its `coil.lock` names.

Projects may install at the same time: spool holds `<repo>.lock` (a
directory beside the bare clone) while it fetches or adds a checkout, and
moves each checkout into place only once it is complete. A lock whose pid is
gone is taken over; a waiter gives up after ten minutes.

`spool cache gc` frees what no project needs any more. Every install and
every compiling command records its project under `projects/`; gc keeps each
checkout and bare clone a recorded project's `coil.lock` names, forgets
projects whose `coil.lock` is gone, and removes the rest (`--dry-run` lists
it). Anything fetched in the last hour (`SPOOL_CACHE_GC_GRACE_MIN`) and any
clone whose lock is held is kept, so an install in progress is safe. A
project spool has not run in since recording began is unknown to gc; if its
checkouts go, `spool install` there fetches them again. `spool cache clean`
removes everything, including checkouts other projects link to.

## Private git

spool stores no credentials. git runs with `GIT_TERMINAL_PROMPT=0`, so a
missing credential fails instead of hanging. Use whatever works for
`git clone`: ssh-agent with `git@host:owner/repo.git`, `GIT_ASKPASS`,
credential helpers, or `url.<base>.insteadOf`.

## Develop

```bash
export COIL="$(./bootstrap.sh --channel edge --coil-only)"   # newest edge coil
./bootstrap.sh    # → target/spool, built with that coil
# To hack on coil-lang itself: ./bootstrap.sh --from-source (COIL_LANG_REF picks the ref)
./target/spool install        # links the stdlib, coil-toml, … (pinned revs in coil.toml)
./target/spool test           # unit tests
./scripts/smoke_all.sh        # end-to-end smoke tests against target/spool
```

`spool.hy` is the entry; modules are under `src/`:

| Module | Role |
|---|---|
| `cli` | argv parsing |
| `proc` | child processes (constant scripts, positional args) |
| `git` | ls-remote, bare cache, worktrees, tree ids |
| `resolve` | constraints, tag/rev picking, pruning, engine checks |
| `sync` | the install/add/update/remove pipeline |
| `lock`, `manifest` | `coil.lock` and `coil.toml` |
| `roots` | `.spool/deps` links and each dependency's module root |
| `lifecycle`, `hooks` | `[scripts]`, include-hooks, trust gate |
| `toolchain` | coil discovery, compile flags |
| `natives`, `report`, `scaffold` | `download`, `tree`/`outdated`, `new`/`init` |
| `render` | `test`/`infect` reports from coil's `--json` events (uses coil-json) |

## Coil quirks this repo works around

- A call to a function declared later in the file fails to typecheck when
  that function's signature names an imported class (`expected Rec, found
  rec::Rec`). Plain forward references work.
- In a function that returns `Result`, a `Result`-typed **parameter** is
  corrupted (for example, its `Err` payload reads as empty). Helpers that
  inspect a `Result` return `bool` instead (see `tests/include.hy`).
- coil-toml panics (index out of bounds) when a document ends right after a
  value with no trailing newline. `decode_manifest` appends one.
- coil-toml `main` predates field-visibility enforcement. Spool pins the
  default-branch commit with the fix.
- Records are tab-joined strings, from when userland class types could not
  cross module boundaries.
