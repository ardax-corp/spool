// spool — Coil project and dependency manager (standalone; build with bootstrap.sh).
use env::{args, var, cwd, exit};
use term::{println, eprintln};
use io::fs::{remove_dir_all};
use string::{format};
use text::{split, split_once, contains, starts_with, join as text_join};
use util::{
    join2, path_exists, path_dirname, path_is_absolute, ensure_dir, home_dir, trim_or,
    check_pkg_name, check_git_url, vec_has,
};
use cli::{parse_args, opt, has, positionals, raw_args, at_most, strs, strs2, strs3, strs4, no_strs};
use version::{spool_version};
use proc::{run_in, spawn, sh_run, sh_capture, which};
use toolchain::{
    find_coil, require_coil, coil_version_output, find_stdlib, compile_flags, project_roots, env_or,
    ffi_native_flags,
};
use manifest::{
    deps_read, dep_kind, dep_name, make_git_rev_dep, make_path_dep, deps_append, deps_remove,
    manifest_body, section_string, package_name_read,
};
use lock::{lock_read_or_empty, lock_pkg_name, lock_add_allow_include};
use hooks::{hooks_are_off};
use sync::{sync, snapshot, restore};
use report::{print_tree, print_outdated};
use natives::{download_natives};
use scaffold::{scaffold};
use render::{render_events};
use config::{cache_root};

fn usage() -> string {
    return "spool " + spool_version() + " — Coil project and dependency manager

Usage: spool <command> [options]

Project:
  new <name> [--lib] [--no-git]     create a project in ./<name>
  init [--name N] [--lib] [--no-git]
                                    create a project in the current directory
  build [-o PATH] [-O LEVEL]        package [entry].file into target/<name>
  run [-O LEVEL] [-- ARGS...]       build, then run target/<name> ARGS
  check                             compile without packaging
  clean [--all]                     remove target/ (--all: also .spool/)

Language tools (flags go to coil unchanged; see `spool <cmd> --help`):
  test [PATH] [FLAGS...]            run tests (default: ./tests; --coverage,
                                    --seed N, -j N, --fail-fast, ...)
  coverage [PATH] [FLAGS...]        tests with line coverage: per-file table and
                                    target/coverage/lcov.info (--coverage-out F,
                                    --coverage-per-test F)
  infect [PATH] [FLAGS...]          mutation testing (--files GLOB,
                                    --min-score P, --operators, ...)
    test/infect also take --color auto|always|never and --plain (coil's
    own text report); --json prints coil's raw NDJSON events
  fmt [--check] [PATHS...]          format sources (default: src tests)
  debug [FILE] [FLAGS...]           debugger REPL on [entry].file (--dap: IDE)
  dissect [FILE] [FLAGS...]         dump bytecode / IL / AST of [entry].file
  lsp                               start the language server on stdio
  coil [ARGS...]                    run coil as-is from the project root

Dependencies:
  install [--locked] [--with-natives]
                                    fetch, resolve and link dependencies
  add <name> --git URL [--version REQ | --rev REV]
  add <name> --path DIR             declare a dependency, then install
  remove <name>                     drop a dependency and prune coil.lock
  update [name]                     re-resolve to the newest allowed versions
  tree                              print the dependency graph
  outdated                          compare locked tags with the remote
  download [EXE]                    fetch FFI natives (project or packaged EXE)
  allow-include <name>              allow a dependency's include-hook

Tooling:
  doctor                            check the toolchain and environment
  cache dir | cache clean           show or clear the shared git cache
  version, --version                print the spool version
  help, --help                      show this help

Lifecycle flags (install/add/update/remove):
  --enable-scripts    run [scripts] and allowlisted include-hooks
  --ignore-scripts    never run hooks (wins over --enable-scripts)

Environment: COIL, COIL_STDLIB_DIR, COIL_CACHE_DIR, COIL_NATIVES_DIR,
             SPOOL_PROJECT, SPOOL_IGNORE_SCRIPTS=0
";
}

fn say(string msg) {
    eprintln("spool: " + msg);
}

fn out(string msg) {
    println(msg);
}

fn current_dir() -> Result<string, string> {
    return match cwd() {
        Result::Ok(c) => c,
        Result::Err(_) => raise "cannot read the current directory",
    };
}

/// SPOOL_PROJECT, else the nearest directory upward holding coil.toml.
fn find_project() -> Result<string, string> {
    let forced = env_or("SPOOL_PROJECT", "");
    if len(forced) > 0 {
        return forced;
    }
    let dir = current_dir()?;
    let d = dir;
    while true {
        if path_exists(join2(d, "coil.toml")) {
            return d;
        }
        let up = path_dirname(d);
        if up == d || len(up) == 0 || up == "." {
            break;
        }
        d = up;
    }
    raise format("could not find coil.toml in %s or any parent directory", dir);
}

fn hooks_off_from(Vec<string> parsed) -> bool {
    if has(parsed, "--ignore-scripts") {
        return true;
    }
    if has(parsed, "--enable-scripts") {
        return false;
    }
    return hooks_are_off(env_or("SPOOL_IGNORE_SCRIPTS", "1"));
}

fn hook_flags() -> Vec<string> {
    return strs2("--enable-scripts", "--ignore-scripts");
}

fn with_hook_flags(Vec<string> extra) -> Vec<string> {
    let out = hook_flags();
    let i = 0;
    while i < len(extra) {
        out.push(extra[i]);
        i = i + 1;
    }
    return out;
}

// ---- project commands ------------------------------------------------------

fn project_name(string root) -> string {
    let n = package_name_read(join2(root, "coil.toml"));
    if len(n) == 0 {
        return "app";
    }
    return n;
}

fn entry_of(string root) -> Result<string, string> {
    let body = manifest_body(join2(root, "coil.toml"))?;
    let e = section_string(body, "entry", "file")?;
    if len(e) > 0 {
        return e;
    }
    if path_exists(join2(root, "src/main.hy")) {
        return "src/main.hy";
    }
    raise "nothing to build: set [entry] file in coil.toml (or add src/main.hy)";
}

fn has_deps(string root) -> Result<bool, string> {
    let deps = deps_read(join2(root, "coil.toml"))?;
    return len(deps) > 0;
}

/// Install first when dependencies are declared but never linked.
fn ensure_installed(string root) -> Result<int, string> {
    if has_deps(root)? == false {
        return 0;
    }
    if path_exists(join2(root, ".spool/deps")) {
        return 0;
    }
    say("dependencies not linked yet; running install");
    let hooks_off = hooks_are_off(env_or("SPOOL_IGNORE_SCRIPTS", "1"));
    return sync(root, false, no_strs(), hooks_off, "pre_install", "post_install")?;
}

fn coil_in(string root, Vec<string> argv) -> Result<int, string> {
    let coil = require_coil()?;
    return run_in(root, coil, argv)?;
}

fn push_all(Vec<string> dst, Vec<string> src) -> Vec<string> {
    let i = 0;
    while i < len(src) {
        dst.push(src[i]);
        i = i + 1;
    }
    return dst;
}

fn build_to(string root, string output, string opt_level) -> Result<int, string> {
    ensure_installed(root)?;
    let entry = entry_of(root)?;
    ensure_dir(path_dirname(output))?;
    let argv = strs("package");
    argv = push_all(argv, compile_flags(root)?);
    argv = push_all(argv, ffi_native_flags(root)?);
    if len(opt_level) > 0 {
        argv.push("-O");
        argv.push(opt_level);
    }
    argv.push("-o");
    argv.push(output);
    argv.push(entry);
    let code = coil_in(root, argv)?;
    if code != 0 {
        raise format("build failed (coil exit %i)", code);
    }
    return 0;
}

fn default_output(string root) -> string {
    return join2(root, "target/" + project_name(root));
}

fn cmd_build(Vec<string> rest) -> Result<int, string> {
    let p = parse_args(rest, strs4("-o", "--output", "-O", "--opt-level"), no_strs())?;
    at_most(positionals(p), 0, "spool build [-o PATH] [-O LEVEL]")?;
    let root = find_project()?;
    let o = opt(p, "-o");
    if len(o) == 0 {
        o = opt(p, "--output");
    }
    if len(o) == 0 {
        o = default_output(root);
    }
    let lvl = opt(p, "-O");
    if len(lvl) == 0 {
        lvl = opt(p, "--opt-level");
    }
    build_to(root, o, lvl)?;
    say("built " + o);
    return 0;
}

fn cmd_run(Vec<string> rest) -> Result<int, string> {
    let p = parse_args(rest, strs2("-O", "--opt-level"), no_strs())?;
    let root = find_project()?;
    let o = default_output(root);
    let lvl = opt(p, "-O");
    if len(lvl) == 0 {
        lvl = opt(p, "--opt-level");
    }
    build_to(root, o, lvl)?;
    let argv = push_all(positionals(p), raw_args(p));
    return spawn(o, argv)?;
}

fn cmd_check(Vec<string> rest) -> Result<int, string> {
    let p = parse_args(rest, no_strs(), no_strs())?;
    at_most(positionals(p), 0, "spool check")?;
    let root = find_project()?;
    ensure_installed(root)?;
    let entry = entry_of(root)?;
    let dir = join2(root, "target/.check");
    ensure_dir(dir)?;
    let argv = strs("compile");
    argv = push_all(argv, compile_flags(root)?);
    argv.push("-o");
    argv.push(join2(dir, project_name(root) + ".hyc"));
    argv.push(entry);
    let code = coil_in(root, argv)?;
    if code != 0 {
        raise format("check failed (coil exit %i)", code);
    }
    say("ok");
    return 0;
}

// ---- coil tool passthrough -------------------------------------------------
// These commands forward every flag to the coil subcommand unchanged, so new
// coil options work without a spool release. spool only adds the project's
// --root / grant flags and, where coil wants an entry file, [entry].file.

/// Drop spool lifecycle flags that `main` hoisted from before the command.
fn tool_args(Vec<string> rest) -> Vec<string> {
    let out: Vec<string> = Vec::new();
    let i = 0;
    while i < len(rest) {
        if rest[i] != "--enable-scripts" && rest[i] != "--ignore-scripts" {
            out.push(rest[i]);
        }
        i = i + 1;
    }
    return out;
}

/// True when `args` hold a positional (or `--entry`), skipping the values of
/// flags in `valued`.
fn has_target(Vec<string> args, Vec<string> valued) -> bool {
    let i = 0;
    while i < len(args) {
        let a = args[i];
        i = i + 1;
        if a == "--" {
            return i < len(args);
        }
        if a == "--entry" || starts_with(a, "--entry=") {
            return true;
        }
        if starts_with(a, "-") && a != "-" {
            if vec_has(valued, a) {
                i = i + 1;
            }
            continue;
        }
        return true;
    }
    return false;
}

/// `coil <sub> <project flags> <args…>` from the project root.
fn coil_tool(string sub, Vec<string> args, bool install) -> Result<int, string> {
    let root = find_project()?;
    if install {
        ensure_installed(root)?;
    }
    let argv = strs(sub);
    argv = push_all(argv, compile_flags(root)?);
    argv = push_all(argv, args);
    return coil_in(root, argv)?;
}

/// Like coil_tool, but appends [entry].file when `args` name no target.
fn coil_entry_tool(string sub, Vec<string> args, Vec<string> valued) -> Result<int, string> {
    let root = find_project()?;
    ensure_installed(root)?;
    let argv = strs(sub);
    argv = push_all(argv, compile_flags(root)?);
    argv = push_all(argv, args);
    if has_target(args, valued) == false {
        argv.push(entry_of(root)?);
    }
    return coil_in(root, argv)?;
}

/// Valued flags shared by coil's compiling subcommands.
fn compile_valued() -> Vec<string> {
    let v = strs4("-O", "--opt-level", "--root", "--entry");
    v.push("--allow-dload");
    v.push("--ffi-search-path");
    v.push("--dload-pin");
    v.push("--dload-trusted");
    return v;
}

// ---- rendered reports (test, infect) ----------------------------------------
// coil emits NDJSON events (`--json`); `spool __render` reads them from a pipe
// and prints a compact, colored report while the run is still going.

/// Split spool's report flags from coil's. `--plain` (or any flag that picks
/// coil's own output format, or help) means "pass coil's output through".
fn report_flags(Vec<string> args) -> Result<(Vec<string>, bool, string), string> {
    let out: Vec<string> = Vec::new();
    let plain = false;
    let color = "auto";
    let i = 0;
    while i < len(args) {
        let a = args[i];
        i = i + 1;
        if a == "--plain" {
            plain = true;
            continue;
        }
        if a == "--color" {
            if i >= len(args) {
                raise "--color needs a value (auto, always or never)";
            }
            color = args[i];
            i = i + 1;
            continue;
        }
        if starts_with(a, "--color=") {
            let kv = split_once(a, "=")?;
            let (_, v) = kv;
            color = v;
            continue;
        }
        if a == "--json" || a == "--log-json" || a == "--log-lsp" || a == "-h" || a == "--help" {
            plain = true;
        }
        out.push(a);
    }
    if color != "auto" && color != "always" && color != "never" {
        raise format("--color must be auto, always or never (got %s)", color);
    }
    return (out, plain, color);
}

/// --color always/never, else NO_COLOR, TERM=dumb, then "is stdout a tty".
fn want_color(string mode) -> bool {
    if mode == "always" {
        return true;
    }
    if mode == "never" {
        return false;
    }
    if len(env_or("NO_COLOR", "")) > 0 || env_or("TERM", "") == "dumb" {
        return false;
    }
    return match sh_run("[ -t 1 ]", no_strs()) {
        Result::Ok(code) => code == 0,
        Result::Err(_) => false,
    };
}

/// Absolute path of this spool executable ("" when it cannot be told).
fn self_exe() -> string {
    let argv = match args() {
        Result::Ok(v) => v,
        Result::Err(_) => no_strs(),
    };
    if len(argv) == 0 {
        return "";
    }
    let a = argv[0];
    let parts = match split(a, "/") {
        Result::Ok(v) => v,
        Result::Err(_) => strs(a),
    };
    // Run in memory (`coil spool.hy`), argv[0] is coil itself.
    if parts[len(parts) - 1] == "coil" {
        return "";
    }
    if contains(a, "/") == false {
        return which(a);
    }
    if path_is_absolute(a) {
        return a;
    }
    return match current_dir() {
        Result::Ok(d) => join2(d, a),
        Result::Err(_) => "",
    };
}

/// `coil ARGS --help` output (stdout and stderr), "" when it cannot run.
fn coil_help(string coil, Vec<string> args) -> string {
    let a = strs(coil);
    a = push_all(a, args);
    return match sh_capture("\"$@\" --help 2>&1", a) {
        Result::Ok(res) => {
            let (_, body) = res;
            return body;
        },
        Result::Err(_) => "",
    };
}

/// Whether this coil has the `coil <sub>` subcommand.
fn coil_has_command(string coil, string sub) -> bool {
    return contains(coil_help(coil, no_strs()), "\n  " + sub + " ");
}

/// Whether `coil <sub>` streams `--json` events (older coils do not, and
/// an older `coil mutate --json` prints one object at the end instead).
fn coil_streams_json(string coil, string sub) -> bool {
    return contains(coil_help(coil, strs(sub)), "NDJSON events");
}

fn update_coil_hint() -> string {
    return "update coil: rerun ./bootstrap.sh (it rebuilds an outdated bootstrap coil), or point COIL at a newer build; see `spool doctor`";
}

/// `coil <sub> … --json | spool __render <view>` from the project root.
fn coil_rendered(string sub, string view, Vec<string> rest) -> Result<int, string> {
    let parsed = report_flags(tool_args(rest))?;
    let (coil_args, plain, color_mode) = parsed;
    let me = self_exe();
    if plain || len(me) == 0 {
        return coil_tool(sub, coil_args, true)?;
    }
    let coil = require_coil()?;
    if coil_has_command(coil, sub) == false {
        raise format("%s has no `coil %s`\n%s", coil, sub, update_coil_hint());
    }
    if coil_streams_json(coil, sub) == false {
        say(format("%s has no `coil %s --json` events, so this is coil's own report", coil, sub));
        say("(" + update_coil_hint() + ")");
        return coil_tool(sub, coil_args, true)?;
    }
    let root = find_project()?;
    ensure_installed(root)?;
    let color = "plain";
    if want_color(color_mode) {
        color = "color";
    }
    let argv = strs4(root, me, view, color);
    argv.push(coil);
    argv.push(sub);
    argv = push_all(argv, compile_flags(root)?);
    argv = push_all(argv, coil_args);
    argv.push("--json");
    // The renderer's status is the run's: it fails on a red summary, an
    // error event, or a coil that stops without a summary.
    return sh_run(
        "cd \"$1\" || exit 125; me=\"$2\"; view=\"$3\"; color=\"$4\"; shift 4; \"$@\" | \"$me\" __render \"$view\" \"$color\"",
        argv,
    )?;
}

fn cmd_test(Vec<string> rest) -> Result<int, string> {
    return coil_rendered("test", "test", rest)?;
}

/// `test --coverage`: the per-file table plus target/coverage/lcov.info.
fn cmd_coverage(Vec<string> rest) -> Result<int, string> {
    let args = strs("--coverage");
    args = push_all(args, rest);
    return coil_rendered("test", "test", args)?;
}

fn cmd_infect(Vec<string> rest) -> Result<int, string> {
    return coil_rendered("mutate", "infect", rest)?;
}

fn cmd_render(Vec<string> rest) -> Result<int, string> {
    if len(rest) != 2 {
        raise "usage: spool __render <test|infect> <color|plain>";
    }
    return render_events(rest[0], rest[1] == "color")?;
}

fn cmd_debug(Vec<string> rest) -> Result<int, string> {
    let args = tool_args(rest);
    // The DAP adapter takes the program from the client's launch request.
    if vec_has(args, "--dap") {
        return coil_tool("debug", args, true)?;
    }
    let valued = compile_valued();
    valued.push("-x");
    return coil_entry_tool("debug", args, valued)?;
}

fn cmd_dissect(Vec<string> rest) -> Result<int, string> {
    let valued = compile_valued();
    valued.push("--fn");
    return coil_entry_tool("dissect", tool_args(rest), valued)?;
}

fn cmd_fmt(Vec<string> rest) -> Result<int, string> {
    let args = tool_args(rest);
    let root = find_project()?;
    let argv = strs("fmt");
    argv = push_all(argv, args);
    if has_target(args, no_strs()) == false {
        let n = len(argv);
        if path_exists(join2(root, "src")) {
            argv.push("src");
        }
        if path_exists(join2(root, "tests")) {
            argv.push("tests");
        }
        if len(argv) == n {
            raise "nothing to format";
        }
    }
    return coil_in(root, argv)?;
}

/// The language server talks over stdio, so nothing here may print to stdout.
/// In a project, the server gets the same roots and grants as every other
/// coil command (needs a coil whose `coil lsp` takes `--root`,
/// ardax-corp/coil-lang#589; older ones get no flags).
fn cmd_lsp(Vec<string> rest) -> Result<int, string> {
    let argv = strs("lsp");
    let dir = "";
    match find_project() {
        Result::Ok(root) => {
            dir = root;
            let lsp_help = coil_help(require_coil()?, strs("lsp"));
            if contains(lsp_help, "--root") {
                argv = push_all(argv, compile_flags(root)?);
            } else {
                say("this coil's `coil lsp` takes no --root; dependencies and the stdlib will not resolve");
                say("(" + update_coil_hint() + ")");
            }
        },
        Result::Err(_) => {
            dir = current_dir()?;
        },
    };
    argv = push_all(argv, tool_args(rest));
    return coil_in(dir, argv)?;
}

/// Escape hatch: plain `coil ARGS…` from the project root (or cwd).
fn cmd_coil(Vec<string> rest) -> Result<int, string> {
    let dir = match find_project() {
        Result::Ok(r) => r,
        Result::Err(_) => current_dir()?,
    };
    return coil_in(dir, rest)?;
}

fn remove_tree(string p) -> Result<int, string> {
    if path_exists(p) == false {
        return 0;
    }
    return match remove_dir_all(p) {
        Result::Ok(_) => 0,
        Result::Err(_) => raise format("cannot remove %s", p),
    };
}

fn cmd_clean(Vec<string> rest) -> Result<int, string> {
    let p = parse_args(rest, no_strs(), strs("--all"))?;
    at_most(positionals(p), 0, "spool clean [--all]")?;
    let root = find_project()?;
    remove_tree(join2(root, "target"))?;
    if has(p, "--all") {
        remove_tree(join2(root, ".spool"))?;
    }
    say("clean");
    return 0;
}

fn cmd_new(Vec<string> rest, bool here) -> Result<int, string> {
    let p = parse_args(rest, strs("--name"), strs2("--lib", "--no-git"))?;
    let pos = positionals(p);
    let dir = "";
    let name = opt(p, "--name");
    if here {
        at_most(pos, 0, "spool init [--name N] [--lib] [--no-git]")?;
        dir = current_dir()?;
        if len(name) == 0 {
            let parts = match split(dir, "/") {
                Result::Ok(v) => v,
                Result::Err(_) => strs("app"),
            };
            name = parts[len(parts) - 1];
        }
    } else {
        if len(pos) != 1 {
            raise "usage: spool new <name> [--lib] [--no-git]";
        }
        if len(name) == 0 {
            name = pos[0];
        }
        dir = join2(current_dir()?, pos[0]);
        if path_exists(dir) {
            raise format("%s already exists", dir);
        }
    }
    scaffold(dir, name, has(p, "--lib"), has(p, "--no-git") == false)?;
    let kind = "binary";
    if has(p, "--lib") {
        kind = "library";
    }
    say(format("created %s package `%s` in %s", kind, name, dir));
    if len(find_stdlib()) == 0 {
        say("note: coil-stdlib not found; set COIL_STDLIB_DIR or run ./bootstrap.sh --install");
    }
    return 0;
}

// ---- dependency commands ---------------------------------------------------

fn cmd_install(Vec<string> rest) -> Result<int, string> {
    let p = parse_args(rest, no_strs(), with_hook_flags(strs2("--locked", "--with-natives")))?;
    at_most(positionals(p), 0, "spool install [--locked] [--with-natives]")?;
    let root = find_project()?;
    sync(root, has(p, "--locked"), no_strs(), hooks_off_from(p), "pre_install", "post_install")?;
    if has(p, "--with-natives") {
        download_natives(require_coil()?, root, "")?;
    }
    say("install: ok");
    return 0;
}

/// Values written into coil.toml as TOML basic strings.
fn check_toml_value(string what, string v) -> Result<int, string> {
    if contains(v, "\"") || contains(v, "\\") || contains(v, "\n") {
        raise format("%s must not contain quotes, backslashes or newlines", what);
    }
    return 0;
}

fn cmd_add(Vec<string> rest) -> Result<int, string> {
    let p = parse_args(rest, strs4("--git", "--path", "--version", "--rev"), hook_flags())?;
    let pos = positionals(p);
    let usage = "spool add <name> --git URL [--version REQ | --rev REV]\n       spool add <name> --path DIR";
    if len(pos) != 1 {
        raise "usage: " + usage;
    }
    let name = pos[0];
    check_pkg_name(name)?;
    let git = opt(p, "--git");
    let path = opt(p, "--path");
    let version = opt(p, "--version");
    let rev = opt(p, "--rev");
    let dep = "";
    if len(git) > 0 {
        if len(path) > 0 {
            raise "--git and --path are mutually exclusive";
        }
        check_git_url(git)?;
        check_toml_value("--git", git)?;
        check_toml_value("--version", version)?;
        check_toml_value("--rev", rev)?;
        if len(version) > 0 && len(rev) > 0 {
            raise "--version and --rev are mutually exclusive";
        }
        if len(version) == 0 && len(rev) == 0 {
            version = "*";
        }
        dep = make_git_rev_dep(name, git, version, rev);
    } else {
        if len(path) == 0 {
            raise "need --git or --path\nusage: " + usage;
        }
        if len(version) > 0 || len(rev) > 0 {
            raise "--version / --rev only apply to --git";
        }
        check_toml_value("--path", path)?;
        dep = make_path_dep(name, path);
    }
    let root = find_project()?;
    let snap = snapshot(root);
    let (toml, lock_body, had_lock) = snap;
    deps_append(join2(root, "coil.toml"), dep)?;
    match sync(root, false, no_strs(), hooks_off_from(p), "pre_install", "post_install") {
        Result::Ok(_) => 0,
        Result::Err(e) => {
            restore(root, toml, lock_body, had_lock);
            raise e + "\n(coil.toml and coil.lock were restored)";
        },
    };
    say("added " + name);
    return 0;
}

fn cmd_remove(Vec<string> rest) -> Result<int, string> {
    let p = parse_args(rest, no_strs(), hook_flags())?;
    let pos = positionals(p);
    if len(pos) != 1 {
        raise "usage: spool remove <name>";
    }
    let root = find_project()?;
    let snap = snapshot(root);
    let (toml, lock_body, had_lock) = snap;
    deps_remove(join2(root, "coil.toml"), pos[0])?;
    match sync(root, false, no_strs(), hooks_off_from(p), "pre_install", "post_install") {
        Result::Ok(_) => 0,
        Result::Err(e) => {
            restore(root, toml, lock_body, had_lock);
            raise e + "\n(coil.toml and coil.lock were restored)";
        },
    };
    say("removed " + pos[0]);
    return 0;
}

fn cmd_update(Vec<string> rest) -> Result<int, string> {
    let p = parse_args(rest, no_strs(), hook_flags())?;
    let pos = positionals(p);
    at_most(pos, 1, "spool update [name]")?;
    let root = find_project()?;
    let packages = lock_read_or_empty(join2(root, "coil.lock"))?;
    let force: Vec<string> = Vec::new();
    let deps = deps_read(join2(root, "coil.toml"))?;
    let i = 0;
    while i < len(deps) {
        if dep_kind(deps[i]) == "g" {
            force.push(dep_name(deps[i]));
        }
        i = i + 1;
    }
    i = 0;
    while i < len(packages) {
        if vec_has(force, lock_pkg_name(packages[i])) == false {
            force.push(lock_pkg_name(packages[i]));
        }
        i = i + 1;
    }
    if len(pos) == 1 {
        if vec_has(force, pos[0]) == false {
            raise format("`%s` is not a git dependency", pos[0]);
        }
        force = strs(pos[0]);
    }
    if len(force) == 0 {
        raise "no git dependencies";
    }
    sync(root, false, force, hooks_off_from(p), "pre_update", "post_update")?;
    say("update: ok");
    return 0;
}

fn cmd_tree(Vec<string> rest) -> Result<int, string> {
    let p = parse_args(rest, no_strs(), no_strs())?;
    at_most(positionals(p), 0, "spool tree")?;
    let root = find_project()?;
    return print_tree(root, lock_read_or_empty(join2(root, "coil.lock"))?)?;
}

fn cmd_outdated(Vec<string> rest) -> Result<int, string> {
    let p = parse_args(rest, no_strs(), no_strs())?;
    at_most(positionals(p), 0, "spool outdated")?;
    let root = find_project()?;
    return print_outdated(root, lock_read_or_empty(join2(root, "coil.lock"))?)?;
}

fn cmd_download(Vec<string> rest) -> Result<int, string> {
    let p = parse_args(rest, no_strs(), no_strs())?;
    let pos = positionals(p);
    at_most(pos, 1, "spool download [EXE]")?;
    let coil = require_coil()?;
    if len(pos) == 1 {
        // URLs still come from the enclosing project's [[ffi.native]], if any.
        let dir = match find_project() {
            Result::Ok(r) => r,
            Result::Err(_) => current_dir()?,
        };
        let exe = pos[0];
        if path_is_absolute(exe) == false {
            exe = join2(current_dir()?, exe);
        }
        return download_natives(coil, dir, exe)?;
    }
    return download_natives(coil, find_project()?, "")?;
}

fn cmd_allow_include(Vec<string> rest) -> Result<int, string> {
    let p = parse_args(rest, no_strs(), no_strs())?;
    let pos = positionals(p);
    if len(pos) != 1 {
        raise "usage: spool allow-include <name>";
    }
    check_pkg_name(pos[0])?;
    let root = find_project()?;
    lock_add_allow_include(join2(root, "coil.lock"), pos[0])?;
    say("allow-include: " + pos[0]);
    return 0;
}

// ---- tooling ---------------------------------------------------------------

fn doctor_line(string label, string value, bool ok) -> bool {
    let mark = "ok     ";
    if ok == false {
        mark = "missing";
    }
    out(format("  [%s] %s %s", mark, label, value));
    return ok;
}

fn cmd_doctor(Vec<string> rest) -> Result<int, string> {
    parse_args(rest, no_strs(), no_strs())?;
    out("spool " + spool_version());
    let good = true;
    let coil = find_coil();
    if len(coil) > 0 {
        good = doctor_line("coil", coil + " (" + coil_version_output(coil) + ")", true) && good;
        doctor_line("coil mutate", "(spool infect)", coil_has_command(coil, "mutate"));
        doctor_line("coil test --json", "(rendered spool test / coverage)", coil_streams_json(coil, "test"));
    } else {
        good = doctor_line("coil", "(set COIL or run ./bootstrap.sh --install)", false) && good;
    }
    let stdlib = find_stdlib();
    if len(stdlib) > 0 {
        doctor_line("coil-stdlib", stdlib, true);
    } else {
        good = doctor_line("coil-stdlib", "(set COIL_STDLIB_DIR or ~/.coil/stdlib)", false) && good;
    }
    let tools = strs4("git", "sh", "curl", "tar");
    let i = 0;
    while i < len(tools) {
        let w = which(tools[i]);
        let ok = len(w) > 0;
        if tools[i] == "git" || tools[i] == "sh" {
            good = doctor_line(tools[i], w, ok) && good;
        } else {
            doctor_line(tools[i], w, ok);
        }
        i = i + 1;
    }
    let cache = cache_root()?;
    doctor_line("cache", cache, true);
    match find_project() {
        Result::Ok(root) => {
            doctor_line("project", root, true);
            match project_roots(root) {
                Result::Ok(roots) => {
                    out("  roots: " + text_join(roots, ", "));
                },
                Result::Err(e) => {
                    good = doctor_line("coil.toml", e, false) && good;
                },
            };
        },
        Result::Err(_) => {
            out("  (no project in this directory)");
        },
    };
    if good {
        return 0;
    }
    return 1;
}

fn cmd_cache(Vec<string> rest) -> Result<int, string> {
    let p = parse_args(rest, no_strs(), no_strs())?;
    let pos = positionals(p);
    let sub = "dir";
    if len(pos) > 0 {
        sub = pos[0];
    }
    at_most(pos, 1, "spool cache dir | spool cache clean")?;
    let cache = cache_root()?;
    if sub == "dir" {
        out(cache);
        return 0;
    }
    if sub == "clean" {
        remove_tree(join2(cache, "git"))?;
        match home_dir() {
            Result::Ok(h) => {
                remove_tree(join2(h, ".cache/spool/tmp"))?;
            },
            Result::Err(_) => {},
        };
        say("cleared " + join2(cache, "git"));
        return 0;
    }
    raise "usage: spool cache dir | spool cache clean";
}

fn dispatch(string cmd, Vec<string> rest) -> Result<int, string> {
    if cmd == "help" || cmd == "--help" || cmd == "-h" {
        out(usage());
        return 0;
    }
    if cmd == "version" || cmd == "--version" || cmd == "-V" {
        out("spool " + spool_version());
        return 0;
    }
    if cmd == "new" {
        return cmd_new(rest, false)?;
    }
    if cmd == "init" {
        return cmd_new(rest, true)?;
    }
    if cmd == "build" {
        return cmd_build(rest)?;
    }
    if cmd == "run" {
        return cmd_run(rest)?;
    }
    if cmd == "check" {
        return cmd_check(rest)?;
    }
    if cmd == "test" {
        return cmd_test(rest)?;
    }
    if cmd == "__render" {
        return cmd_render(rest)?;
    }
    if cmd == "coverage" {
        return cmd_coverage(rest)?;
    }
    if cmd == "infect" {
        return cmd_infect(rest)?;
    }
    if cmd == "fmt" {
        return cmd_fmt(rest)?;
    }
    if cmd == "debug" {
        return cmd_debug(rest)?;
    }
    if cmd == "dissect" {
        return cmd_dissect(rest)?;
    }
    if cmd == "lsp" {
        return cmd_lsp(rest)?;
    }
    if cmd == "coil" {
        return cmd_coil(rest)?;
    }
    if cmd == "clean" {
        return cmd_clean(rest)?;
    }
    if cmd == "install" {
        return cmd_install(rest)?;
    }
    if cmd == "add" {
        return cmd_add(rest)?;
    }
    if cmd == "remove" || cmd == "rm" {
        return cmd_remove(rest)?;
    }
    if cmd == "update" {
        return cmd_update(rest)?;
    }
    if cmd == "tree" {
        return cmd_tree(rest)?;
    }
    if cmd == "outdated" {
        return cmd_outdated(rest)?;
    }
    if cmd == "download" {
        return cmd_download(rest)?;
    }
    if cmd == "allow-include" {
        return cmd_allow_include(rest)?;
    }
    if cmd == "doctor" {
        return cmd_doctor(rest)?;
    }
    if cmd == "cache" {
        return cmd_cache(rest)?;
    }
    raise format("unknown command `%s` (see spool help)", cmd);
}

fn main() {
    let argv = match args() {
        Result::Ok(v) => v,
        Result::Err(_) => no_strs(),
    };
    // Lifecycle flags may precede the command (`spool --ignore-scripts install`).
    let cmd = "help";
    let rest: Vec<string> = Vec::new();
    let leading: Vec<string> = Vec::new();
    let found = false;
    let i = 1;
    while i < len(argv) {
        let a = argv[i];
        i = i + 1;
        if found {
            rest.push(a);
            continue;
        }
        if a == "--enable-scripts" || a == "--ignore-scripts" {
            leading.push(a);
            continue;
        }
        cmd = a;
        found = true;
    }
    rest = push_all(rest, leading);
    match dispatch(cmd, rest) {
        Result::Ok(code) => {
            exit(code);
        },
        Result::Err(e) => {
            say("error: " + e);
            exit(1);
        },
    };
}
