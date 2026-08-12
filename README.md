# spool

Git-based library dependency manager for [Coil](https://github.com/DaGhostman/coil-lang).

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
- [x] Demo package `greet` (`examples/greet`, also [coil-greet](https://github.com/DaGhostman/coil-greet) `v0.1.0`)
- [x] Consume smoke: install → `use` → compile/run (`scripts/smoke_consume.sh`)
- [x] Private git via host credentials (COI-13)
- [x] Lock integrity + diagnostics (COI-14)
- [x] Transitive deps and diamond errors (COI-15)

## Requirements

- Coil toolchain (`coil` on `PATH`, or set `COIL`) built with `[package]`/`[dependencies]`
  manifest support (coil-lang `feature/coi-3` or later)
- Host `git` and `sh`
- Coil stdlib: default `../coil-lang/stdlib` relative to this repo

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
./spool add greet --git https://github.com/DaGhostman/coil-greet.git --version '^0.1'
```

```coil
use greet::hello;
```

`greet` is function-style on purpose. Userland class types still cannot cross
module boundaries (COI-12). Enums and functions in a git/path dep compile and run.

`install` flow:

1. Coil `plan` — read `coil.lock`, write `.spool/fetch.sh` + `.spool/links.tsv`
2. Bash runs `fetch.sh` (git clone/fetch + worktree)
3. Coil `link` — symlink `.spool/deps/<name>` and ensure roots

`add` / `update` flow:

1. Coil upserts `[dependencies]` (`add`) or lists git deps (`update`)
2. Bash `git ls-remote --tags`; Coil picks the highest matching semver tag
3. Bash `resolve.sh` fetches a worktree and records the tree hash
4. Coil merges `coil.lock`, then the usual plan → fetch → verify tree hash → link
5. `add` / `update` then walk each package `coil.toml` for transitive git deps (unify compatible pins, error on diamonds)

Design: Linear project **Git-based package manager** (COI-1 design doc).

## Coil quirks this repo works around

- No forward references within a module file
- `env::exec` / `env::exit` warnings fail in-memory compile; `extern` in imported
  modules panics (`invalid library handle`); `system(3)` breaks after `Vec` alloc
- So git stays in the bash driver; Coil does plan/pick/lock/link only
- **coil-lang `main` rejects `[package]` / `[dependencies]` (E0900, COI-21).** Local and CI
  builds use a compiler with those tables (coil-lang `feature/coi-3`, or the
  patch in `ci/coil-package-manifest.patch`). Drop the patch once that lands on
  `main`.
