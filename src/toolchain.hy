// Locate the coil toolchain and turn a project manifest into coil flags.
use env::{var};
use string::{format};
use util::{join2, join3, path_exists, path_is_absolute, home_dir, trim_or};
use proc::{which, sh_capture, first_line};
use manifest::{
    manifest_body, module_roots_parse, section_string, section_bool, section_strings,
    trusted_deps_parse, ffi_natives_parse, native_name, native_package, native_version,
    native_path, native_requires, native_requires_hint,
};
use lock::{lock_native_parse, lock_native_pkg, lock_native_stem, lock_native_sha};
use config::{config_path};
use io::file::{read_text};
use text::{starts_with, slice, contains, replace, to_lower};

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

/// The `dload` stem for a lock package: the native row's `stem` / `lib`, else
/// the package name without its `coil-` prefix (`coil-tls` → `tls`).
fn dload_stem(string pkg, string native_stem) -> string {
    if len(native_stem) > 0 {
        return native_stem;
    }
    if starts_with(pkg, "coil-") {
        return match slice(pkg, 5, len(pkg)) {
            Result::Ok(x) => x,
            Result::Err(_) => pkg,
        };
    }
    return pkg;
}

/// 64 hex digits (coil rejects any other `--dload-pin` hash).
fn is_sha256_hex(string s) -> bool {
    if len(s) != 64 {
        return false;
    }
    let lower = match to_lower(s) {
        Result::Ok(x) => x,
        Result::Err(_) => {
            return false;
        },
    };
    let i = 0;
    while i < 64 {
        let c = match slice(lower, i, i + 1) {
            Result::Ok(x) => x,
            Result::Err(_) => {
                return false;
            },
        };
        if contains("0123456789abcdef", c) == false {
            return false;
        }
        i = i + 1;
    }
    return true;
}

fn push_unique(Vec<string> v, string s) -> Vec<string> {
    let i = 0;
    while i < len(v) {
        if v[i] == s {
            return v;
        }
        i = i + 1;
    }
    v.push(s);
    return v;
}

/// `dload` integrity flags from manifest and lock text (coil reads neither):
/// `--dload-pin STEM=SHA256` per lock `[[package.native]]` with a 64-hex
/// sha256, and `--dload-trusted STEM` for each `trusted = true` dependency:
/// its name, the name without `coil-`, and its lock native stems.
fn dload_flags(string manifest, string lock) -> Result<Vec<string>, string> {
    let natives = lock_native_parse(lock)?;
    let out: Vec<string> = Vec::new();
    let pins: Vec<string> = Vec::new();
    let i = 0;
    while i < len(natives) {
        let n = natives[i];
        i = i + 1;
        let sha = lock_native_sha(n);
        if is_sha256_hex(sha) {
            pins = push_unique(pins, dload_stem(lock_native_pkg(n), lock_native_stem(n)) + "=" + sha);
        }
    }
    i = 0;
    while i < len(pins) {
        out.push("--dload-pin");
        out.push(pins[i]);
        i = i + 1;
    }
    let trusted = trusted_deps_parse(manifest)?;
    let stems: Vec<string> = Vec::new();
    i = 0;
    while i < len(trusted) {
        let name = trusted[i];
        i = i + 1;
        stems = push_unique(stems, name);
        stems = push_unique(stems, dload_stem(name, ""));
        let j = 0;
        while j < len(natives) {
            if lock_native_pkg(natives[j]) == name {
                stems = push_unique(stems, dload_stem(name, lock_native_stem(natives[j])));
            }
            j = j + 1;
        }
    }
    i = 0;
    while i < len(stems) {
        out.push("--dload-trusted");
        out.push(stems[i]);
        i = i + 1;
    }
    return out;
}

/// `\,` for each comma, so a value cannot end an `--ffi-native` field.
fn spec_escape(string v) -> string {
    return match replace(v, ",", "\\,") {
        Result::Ok(x) => x,
        Result::Err(_) => v,
    };
}

/// One `--ffi-native` value per `[[ffi.native]]` row (relative `path` is
/// resolved against `root`).
fn ffi_native_specs(string root, string manifest) -> Result<Vec<string>, string> {
    let rows = ffi_natives_parse(manifest)?;
    let out: Vec<string> = Vec::new();
    let i = 0;
    while i < len(rows) {
        let r = rows[i];
        i = i + 1;
        let spec = "name=" + spec_escape(native_name(r));
        spec = spec + ",version=" + spec_escape(native_version(r));
        spec = spec + ",path=" + spec_escape(abs_under(root, native_path(r)));
        if native_package(r) != native_name(r) {
            spec = spec + ",package=" + spec_escape(native_package(r));
        }
        if len(native_requires(r)) > 0 {
            spec = spec + ",requires=" + spec_escape(native_requires(r));
        }
        if len(native_requires_hint(r)) > 0 {
            spec = spec + ",requires-hint=" + spec_escape(native_requires_hint(r));
        }
        out.push(spec);
    }
    return out;
}

/// `--ffi-native SPEC` pairs for `coil package` / `coil natives dump`.
fn ffi_native_flags(string root) -> Result<Vec<string>, string> {
    let specs = ffi_native_specs(root, manifest_body(join2(root, "coil.toml"))?)?;
    let out: Vec<string> = Vec::new();
    let i = 0;
    while i < len(specs) {
        out.push("--ffi-native");
        out.push(specs[i]);
        i = i + 1;
    }
    return out;
}

/// coil.lock text, or "" when the project has none.
fn lock_text(string root) -> string {
    let path = join2(root, "coil.lock");
    if path_exists(path) == false {
        return "";
    }
    return match read_text(path) {
        Result::Ok(s) => s,
        Result::Err(_) => "",
    };
}

/// Host grants coil.toml records but coil does not apply by itself, plus the
/// `dload` pins / trusted stems from coil.toml and coil.lock.
fn grant_flags(string root) -> Result<Vec<string>, string> {
    let body = manifest_body(join2(root, "coil.toml"))?;
    let out: Vec<string> = Vec::new();
    // `[permissions] read = true` → `--allow-read`; `all = true` → `-A`.
    if section_bool(body, "permissions", "all")? {
        out.push("--allow-all");
    }
    let caps = ["read", "write", "net", "env", "exec", "exit", "attach"];
    let c = 0;
    while c < len(caps) {
        if section_bool(body, "permissions", caps[c])? {
            out.push("--allow-" + caps[c]);
        }
        c = c + 1;
    }
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
    let dload = dload_flags(body, lock_text(root))?;
    i = 0;
    while i < len(dload) {
        out.push(dload[i]);
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
