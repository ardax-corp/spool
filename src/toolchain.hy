// Locate the coil toolchain and turn a project manifest into coil flags.
use env::{var};
use string::{format};
use util::{join2, join3, path_exists, path_is_absolute, home_dir, trim_or};
use proc::{which, sh_capture, first_line};
use manifest::{
    manifest_body, module_roots_parse, section_string, section_bool, section_strings,
};
use config::{config_path};
use io::file::{read_text};
use text::{starts_with, slice};

fn env_or(string key, string fallback) -> string {
    return match var(key) {
        Result::Ok(v) => {
            let t = trim_or(v);
            if len(t) == 0 {
                return fallback;
            }
            return t;
        },
        Result::Err(_) => fallback,
    };
}

/// `$COIL`, then `coil` on PATH, then ~/.coil/bin/coil. "" when none.
fn find_coil() -> string {
    let c = env_or("COIL", "");
    if len(c) > 0 {
        return c;
    }
    let on_path = which("coil");
    if len(on_path) > 0 {
        return on_path;
    }
    match home_dir() {
        Result::Ok(h) => {
            let p = join2(h, ".coil/bin/coil");
            if path_exists(p) {
                return p;
            }
        },
        Result::Err(_) => {},
    };
    return "";
}

fn require_coil() -> Result<string, string> {
    let c = find_coil();
    if len(c) == 0 {
        raise "coil not found: set COIL, put coil on PATH, or run ./bootstrap.sh --install";
    }
    return c;
}

/// Raw `coil --version` output ("" when it fails).
fn coil_version_output(string coil) -> string {
    let a: Vec<string> = Vec::new();
    a.push(coil);
    return match sh_capture("\"$1\" --version 2>/dev/null", a) {
        Result::Ok(res) => {
            let (code, body) = res;
            if code != 0 {
                return "";
            }
            return first_line(body);
        },
        Result::Err(_) => "",
    };
}

fn stdlib_from_config() -> string {
    let path = match config_path() {
        Result::Ok(p) => p,
        Result::Err(_) => {
            return "";
        },
    };
    if path_exists(path) == false {
        return "";
    }
    let body = match read_text(path) {
        Result::Ok(s) => s,
        Result::Err(_) => {
            return "";
        },
    };
    return match section_string(body, "stdlib", "dir") {
        Result::Ok(s) => s,
        Result::Err(_) => "",
    };
}

/// A stdlib checkout dir (with src/) or a src dir itself → the src dir.
fn stdlib_src_of(string dir) -> string {
    if len(dir) == 0 {
        return "";
    }
    let src = join2(dir, "src");
    if path_exists(join2(src, "text.hy")) {
        return src;
    }
    if path_exists(join2(dir, "text.hy")) {
        return dir;
    }
    return "";
}

/// coil-stdlib `src`: COIL_STDLIB_DIR, COIL_STDLIB, config `[stdlib] dir`,
/// then ~/.coil/stdlib. "" when none is found.
fn find_stdlib() -> string {
    let s = stdlib_src_of(env_or("COIL_STDLIB_DIR", ""));
    if len(s) > 0 {
        return s;
    }
    s = stdlib_src_of(env_or("COIL_STDLIB", ""));
    if len(s) > 0 {
        return s;
    }
    s = stdlib_src_of(stdlib_from_config());
    if len(s) > 0 {
        return s;
    }
    match home_dir() {
        Result::Ok(h) => {
            return stdlib_src_of(join2(h, ".coil/stdlib"));
        },
        Result::Err(_) => {},
    };
    return "";
}

fn abs_under(string root, string p) -> string {
    if path_is_absolute(p) {
        return p;
    }
    if starts_with(p, "./") {
        return join2(root, match slice(p, 2, len(p)) {
            Result::Ok(x) => x,
            Result::Err(_) => p,
        });
    }
    return join2(root, p);
}

/// Absolute `--root` dirs for a project: [module].roots, `.spool/deps`,
/// then the stdlib unless the manifest already lists a stdlib root.
fn project_roots(string root) -> Result<Vec<string>, string> {
    let body = manifest_body(join2(root, "coil.toml"))?;
    let rel = module_roots_parse(body)?;
    let out: Vec<string> = Vec::new();
    let has_stdlib = false;
    let i = 0;
    while i < len(rel) {
        let r = abs_under(root, rel[i]);
        i = i + 1;
        if path_exists(join2(r, "text.hy")) && path_exists(join3(r, "io", "file.hy")) {
            has_stdlib = true;
        }
        out.push(r);
    }
    let deps = join2(root, ".spool/deps");
    if path_exists(deps) {
        out.push(deps);
    }
    if has_stdlib == false {
        let stdlib = find_stdlib();
        if len(stdlib) > 0 {
            out.push(stdlib);
        }
    }
    return out;
}

/// Host grants coil.toml records but coil does not apply by itself.
fn grant_flags(string root) -> Result<Vec<string>, string> {
    let body = manifest_body(join2(root, "coil.toml"))?;
    let out: Vec<string> = Vec::new();
    if section_bool(body, "env", "allow_exec")? {
        out.push("--allow-exec");
    }
    if section_bool(body, "env", "allow_exit")? {
        out.push("--allow-exit");
    }
    if section_bool(body, "env", "allow_ffi_exec")? {
        out.push("--allow-ffi-exec");
    }
    if section_bool(body, "ffi", "allow_attach")? {
        out.push("--allow-attach");
    }
    let stems = section_strings(body, "ffi", "allow")?;
    let i = 0;
    while i < len(stems) {
        out.push("--allow-dload");
        out.push(stems[i]);
        i = i + 1;
    }
    let search = section_strings(body, "ffi", "search_paths")?;
    i = 0;
    while i < len(search) {
        out.push("--ffi-search-path");
        out.push(abs_under(root, search[i]));
        i = i + 1;
    }
    return out;
}

/// `--root <dir>` pairs plus grant flags, ready to append to a coil subcommand.
fn compile_flags(string root) -> Result<Vec<string>, string> {
    let roots = project_roots(root)?;
    let out: Vec<string> = Vec::new();
    let i = 0;
    while i < len(roots) {
        out.push("--root");
        out.push(roots[i]);
        i = i + 1;
    }
    let grants = grant_flags(root)?;
    i = 0;
    while i < len(grants) {
        out.push(grants[i]);
        i = i + 1;
    }
    return out;
}
