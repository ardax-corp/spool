# spool

Git-based library dependency manager for [Coil](https://github.com/ardax-corp/coil-lang).

`spool` is a **Coil userland** project (not part of the `coil` Rust CLI). It resolves
semver tags from git remotes, pins them in `coil.lock`, fetches into a shared
content-addressed cache, and maintains project-local `.spool/deps` roots that the
compiler already understands via `[module].roots`.

## Naming

| Tool | Role |
|------|------|
| **`spool`** | Library dependencies (`install` / `add` / `update`) |
| **`coil package`** | Embed a `.hyc` into a runner executable — unrelated |

## Status (M4)

- [x] `coil.lock` read/write (COI-5)
- [x] Git fetch into content-addressed cache (COI-4) — bash `fetch.sh` + shared cache
- [x] Manage `.spool/deps` + ensure `./.spool/deps` in `[module].roots` (COI-6)
- [x] `spool install` (COI-7) via `./spool install` (plan → fetch → link)
- [x] `spool add` / `update` (COI-8–9)
- [x] Demo package `greet` (`examples/greet`, also [coil-greet](https://github.com/ardax-corp/coil-greet) `v0.1.0`)
- [x] Consume smoke: install → `use` → compile/run (`scripts/smoke_consume.sh`)
- [x] Private git via host credentials (COI-13)
- [x] Lock integrity + diagnostics (COI-14)
- [x] Transitive deps and diamond errors (COI-15)
- [x] Engine range `[package].coil` fail-closed on install/add/update (COI-105)
- [x] Hook trust gate: `--ignore-scripts`, lock `hook_path` / `hook_hash`, `allow-include` (COI-227)
- [x] Current-project `[scripts]` runner (`--enable-scripts`, host `sh`) (COI-103). Dependency include-hooks still do not run.

## Requirements

- Coil toolchain (`coil` on `PATH`, or set `COIL`)
- Host `git` and `sh`
- Coil stdlib: default `../coil-stdlib/src` relative to this repo
  ([coil-stdlib](https://github.com/ardax-corp/coil-stdlib))

## Engine range

A package may set `[package].coil` to a semver range against the running Coil
toolchain. The key is optional. Spool stores the string as written.

```toml
[package]
name = "http"
version = "1.2.0"
coil = ">=0.1.0"
```

The engine string is `coil --version`. coil-lang prints `coil 0.1.0` for that
flag and for `-V`. Spool takes the token after `coil` and compares it to the
range. It uses the `coil` binary already selected by `COIL` or `PATH`.

`spool install`, `add`, and `update` check the current project, path deps, and
locked git checkouts that already exist. Missing key and in-range `>=0.1.0` are
no-ops. Out-of-range `>=0.2.0` and `^0.2` fail closed before git fetch.

A git dep whose `coil.toml` is not on disk yet is checked after checkout, before
`link`.

The diagnostic names the package, the range, and the running version:

```text
package http requires coil >=0.2.0, running 0.1.0
```

Range language is the same as git-dep `version`: caret (`^`), `>=`, `>`, `<=`,
`<`, `=`, exact, or `*`.

## Hook trust

Hooks are off by default. `may_run_hook` is the gate. Every host `sh` of a user
script goes through it first (`kind` `script` for current-project `[scripts]`).
`allow_exec` is not a gate.

`--enable-scripts` opts in. `--ignore-scripts` always wins, including in CI.
`SPOOL_IGNORE_SCRIPTS=0` is the same opt-in the gate already understands.

```bash
./spool install --enable-scripts
./spool install --ignore-scripts
./spool allow-include http
```

`spool allow-include <name>` records the consumer allowlist in `coil.lock`,
not in `coil.toml`. coil-lang still errors on unknown manifest sections, so do
not add a `[hooks]` table there. `[package].include` is the include path on a
package. The allowlist is the lock `[hooks]` table:

```toml
[hooks]
allow_include = ['http']
```

`[[package]]` may also store `hook_path` and `hook_hash` for include-hooks.
Those still do not run (COI-104). An include-hook is eligible only when that
package is on `allow_include` and both the path and the content hash match the
lock.

`may_run_hook` raises these strings:

```text
hooks are off (--ignore-scripts)
include-hook for http is not allowlisted
untrusted hook: missing lock hash for http
hook path mismatch for http
hook hash mismatch for http
```

## Project scripts

The current project's `coil.toml` may declare lifecycle scripts. Paths are
relative to the project root. Missing keys are no-ops. Unknown keys are errors
(coil-lang already owns that schema).

```toml
[scripts]
pre_install = "./scripts/pre-install.sh"
post_install = "./scripts/post-install.sh"
pre_update = "./scripts/pre-update.sh"
post_update = "./scripts/post-update.sh"
```

With `--enable-scripts`:

- `spool install` runs `pre_install` then fetch/link, then `post_install`
- `spool update` runs `pre_update` / `post_update`
- `spool add` that materializes deps uses the install pair

`pre_*` runs before fetch/link for that command. `post_*` runs after a
successful link. Non-zero exit aborts with the script path and exit status.

Hashes are stored in lock `[scripts]` (`pre_install` / `pre_install_hash`, …),
not on a `[[package]]` row. The current project is not a git pin. A changed
script file is re-hashed on the next opted-in run.

A dependency's `[scripts]` and `[package].include` are not executed during a
consumer install.

## Cache

Default root: `$XDG_CACHE_HOME/coil` or `~/.cache/coil`.

Override:

- Env: `COIL_CACHE_DIR` (wins)
- File: `~/.config/coil/config.toml` → `[cache] dir = "…"`

Layout:

```text
<cache_root>/git/
  <host>/<owner>/<repo>/     # bare clone
  checkouts/
    <tree-id>/               # detached worktree
```

## Develop

```bash
export COIL=/path/to/coil-lang/target/release/coil
$COIL test
./spool help
./scripts/smoke_install.sh   # local git fixture → install
./scripts/smoke_add.sh       # add git+path deps, then update
./scripts/smoke_consume.sh   # add greet, `use greet::hello`, run it
./scripts/smoke_integrity.sh # hash mismatch, missing/corrupt lock
./scripts/smoke_auth.sh      # git auth failure message
./scripts/smoke_transitive.sh # unify compatible pins, diamond error
./scripts/smoke_engine.sh     # [package].coil range: omit / in-range / too-old
./scripts/smoke_hooks.sh      # --ignore-scripts, allow-include, include-hooks stay off
./scripts/smoke_scripts.sh    # current-project [scripts]: default off, opt-in, fail, no dep scripts
```

## Private git

spool does not store credentials. It runs host `git` with `GIT_TERMINAL_PROMPT=0` so a missing credential fails instead of hanging on a prompt.

Use whatever already works for `git clone` on your machine:

- `ssh-agent` and `git@host:owner/repo.git` URLs
- `GIT_ASKPASS` / `SSH_ASKPASS`
- git credential helpers
- `url.<base>.insteadOf` in `~/.gitconfig` to rewrite HTTPS to SSH

`GIT_SSH_COMMAND` and those variables are passed through to clone/fetch/`ls-remote`.

## Consume a library

`.spool/deps/<name>` is a symlink to the checkout's `src/` directory when that
exists, so `use greet::hello` maps to `hello.hy` in the package.

```bash
./spool add greet --git https://github.com/ardax-corp/coil-greet.git --version '^0.1'
```

```coil
use greet::hello;
```

`greet` is function-style on purpose. Userland class types still cannot cross
module boundaries (COI-12). Enums and functions in a git/path dep compile and run.

`install` flow:

1. Coil `check_install` + `[package].coil` engine range (current project and cached checkouts)
2. Coil `plan` — read `coil.lock`, write `.spool/fetch.sh` + `.spool/links.tsv`
3. Bash runs `fetch.sh` (git clone/fetch + worktree)
4. Coil engine range again for newly fetched `coil.toml` files, then `link`
5. If `--enable-scripts`, current-project `post_install` after a successful link

`pre_install` (when opted in) runs after engine checks and before fetch/link.

`add` / `update` flow:

1. Coil checks `[package].coil` on the current project (and path deps / cached checkouts)
2. Coil upserts `[dependencies]` (`add`) or lists git deps (`update`)
3. Bash `git ls-remote --tags`; Coil picks the highest matching semver tag
4. Bash `resolve.sh` fetches a worktree and records the tree hash
5. Coil merges `coil.lock`, then the usual plan → fetch → verify tree hash → engine range → link
6. `add` / `update` then walk each package `coil.toml` for transitive git deps (unify compatible pins, error on diamonds)
7. Opted-in `add` uses `pre_install` / `post_install`; `update` uses `pre_update` / `post_update`

Design: Linear project **Git-based package manager** (COI-1 design doc).

## Coil quirks this repo works around

- No forward references within a module file
- `env::exec` / `env::exit` warnings fail in-memory compile; `extern` in imported
  modules panics (`invalid library handle`); `system(3)` breaks after `Vec` alloc
- So git stays in the bash driver; Coil does plan/pick/lock/link only
