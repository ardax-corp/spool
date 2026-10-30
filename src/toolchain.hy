// Locate the coil toolchain and turn a project manifest into coil flags.
use env::var;
use string::format;
use util::{join2, join3, path_exists, path_is_absolute, home_dir, trim_or, vec_has, tsv_field};
use roots::{dep_module_roots, dep_checkouts, checkout_module_root};
use proc::{which, sh_capture, first_line};
use manifest::{manifest_body, manifest_validate, module_roots_parse, section_string, section_bool, section_strings, trusted_deps_parse, ffi_natives_parse, native_name, native_package, native_version, native_path, native_requires, native_requires_hint};
use lock::{lock_native_parse, lock_native_pkg, lock_native_stem, lock_native_sha, lock_allow_comptime};
use config::config_path;
use io::file::read_text;
use text::{Searchable, Text};
use io::fs::{is_dir, list_dir};
use term::eprintln;

fn env_or(string key, string fallback) -> string {
    return match var(key) {
        Result::Ok(v) => {
            let t = trim_or(v);
            if t.len() == 0 {
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
    if c.len() > 0 {
        return c;
    }
    let on_path = which("coil");
    if on_path.len() > 0 {
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
    }
    return "";
}

fn require_coil() -> Result<string, string> {
    let c = find_coil();
    if c.len() == 0 {
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

fn abs_under(string root, string p) -> string {
    if path_is_absolute(p) {
        return p;
    }
    if p.starts_with("./") {
        return join2(
            root,
            match p.slice(2, p.len()) {
                Result::Ok(x) => x,
                Result::Err(_) => p,
            },
        );
    }
    return join2(root, p);
}

/// A module root that holds coil-stdlib (`text.hy` and `io/file.hy`).
fn is_stdlib_root(string dir) -> bool {
    return path_exists(join2(dir, "text.hy")) && path_exists(join3(dir, "io", "file.hy"));
}

/// The first of `roots` that holds the stdlib, or "".
fn dep_stdlib_root(Vec<string> roots) -> string {
    let i = 0;
    while i < roots.len() {
        if is_stdlib_root(roots[i]) {
            return roots[i];
        }
        i = i + 1;
    }
    return "";
}

/// Absolute `--root` dirs for a project: [module].roots, `.spool/deps`,
/// the stdlib, then each linked package's module root (<checkout>/src,
/// spool#30). There is no global stdlib: it is a manifest root that holds
/// one (coil-stdlib itself), else the stdlib the project declares under
/// [dependencies], locked to a version like any package. Only one goes in:
/// coil takes the first root that has a module.
fn project_roots(string root) -> Result<Vec<string>, string> {
    let body = manifest_body(join2(root, "coil.toml"))?;
    let rel = module_roots_parse(body)?;
    let out: Vec<string> = Vec::new();
    let has_stdlib = false;
    let i = 0;
    while i < rel.len() {
        let r = abs_under(root, rel[i]);
        i = i + 1;
        if is_stdlib_root(r) {
            has_stdlib = true;
        }
        out.push(r);
    }
    let deps = join2(root, ".spool/deps");
    if path_exists(deps) {
        out.push(deps);
    }
    let pkg_roots = dep_module_roots(root);
    if has_stdlib == false {
        let stdlib = dep_stdlib_root(pkg_roots);
        if stdlib.len() > 0 {
            out.push(stdlib);
        }
    }
    // After the stdlib, so a dependency's top-level modules never shadow a
    // stdlib module (for the consumer or for the stdlib's own imports).
    i = 0;
    while i < pkg_roots.len() {
        if vec_has(out, pkg_roots[i]) == false {
            out.push(pkg_roots[i]);
        }
        i = i + 1;
    }
    return out;
}

/// The stdlib a project compiles against: a manifest root or a linked
/// dependency that is one, or "" when it has none.
fn project_stdlib(string root) -> string {
    let roots = match project_roots(root) {
        Result::Ok(r) => r,
        Result::Err(_) => {
            return "";
        },
    };
    return dep_stdlib_root(roots);
}

/// The `dload` stem for a lock package: the native row's `stem` / `lib`, else
/// the package name without its `coil-` prefix (`coil-tls` → `tls`).
fn dload_stem(string pkg, string native_stem) -> string {
    if native_stem.len() > 0 {
        return native_stem;
    }
    if pkg.starts_with("coil-") {
        return match pkg.slice(5, pkg.len()) {
            Result::Ok(x) => x,
            Result::Err(_) => pkg,
        };
    }
    return pkg;
}

/// 64 hex digits (coil rejects any other `--dload-pin` hash).
fn is_sha256_hex(string s) -> bool {
    if s.len() != 64 {
        return false;
    }
    let lower = s.to_lower();
    let i = 0;
    while i < 64 {
        let c = match lower.slice(i, i + 1) {
            Result::Ok(x) => x,
            Result::Err(_) => {
                return false;
            },
        };
        if "0123456789abcdef".contains(c) == false {
            return false;
        }
        i = i + 1;
    }
    return true;
}

fn push_unique(Vec<string> v, string s) -> Vec<string> {
    let i = 0;
    while i < v.len() {
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
    while i < natives.len() {
        let n = natives[i];
        i = i + 1;
        let sha = lock_native_sha(n);
        if is_sha256_hex(sha) {
            pins = push_unique(
                pins,
                dload_stem(lock_native_pkg(n), lock_native_stem(n)) + "=" + sha,
            );
        }
    }
    i = 0;
    while i < pins.len() {
        out.push("--dload-pin");
        out.push(pins[i]);
        i = i + 1;
    }
    let trusted = trusted_deps_parse(manifest)?;
    let stems: Vec<string> = Vec::new();
    i = 0;
    while i < trusted.len() {
        let name = trusted[i];
        i = i + 1;
        stems = push_unique(stems, name);
        stems = push_unique(stems, dload_stem(name, ""));
        let j = 0;
        while j < natives.len() {
            if lock_native_pkg(natives[j]) == name {
                stems = push_unique(stems, dload_stem(name, lock_native_stem(natives[j])));
            }
            j = j + 1;
        }
    }
    i = 0;
    while i < stems.len() {
        out.push("--dload-trusted");
        out.push(stems[i]);
        i = i + 1;
    }
    return out;
}

/// `\,` for each comma, so a value cannot end an `--ffi-native` field.
fn spec_escape(string v) -> string {
    return v.replace_all(",", "\\,");
}

/// The `--ffi-native` value for one `[[ffi.native]]` row (relative `path`
/// is resolved against `root`).
fn native_spec(string root, string r) -> string {
    let spec = "name=" + spec_escape(native_name(r));
    spec = spec + ",version=" + spec_escape(native_version(r));
    spec = spec + ",path=" + spec_escape(abs_under(root, native_path(r)));
    if native_package(r) != native_name(r) {
        spec = spec + ",package=" + spec_escape(native_package(r));
    }
    if native_requires(r).len() > 0 {
        spec = spec + ",requires=" + spec_escape(native_requires(r));
    }
    if native_requires_hint(r).len() > 0 {
        spec = spec + ",requires-hint=" + spec_escape(native_requires_hint(r));
    }
    return spec;
}

/// One `--ffi-native` value per `[[ffi.native]]` row (relative `path` is
/// resolved against `root`).
fn ffi_native_specs(string root, string manifest) -> Result<Vec<string>, string> {
    let rows = ffi_natives_parse(manifest)?;
    let out: Vec<string> = Vec::new();
    let i = 0;
    while i < rows.len() {
        out.push(native_spec(root, rows[i]));
        i = i + 1;
    }
    return out;
}

fn flag_pairs(string flag, Vec<string> values) -> Vec<string> {
    let out: Vec<string> = Vec::new();
    let i = 0;
    while i < values.len() {
        out.push(flag);
        out.push(values[i]);
        i = i + 1;
    }
    return out;
}

/// `--ffi-native SPEC` pairs for the project's own `[[ffi.native]]` rows
/// (`coil natives dump`, so `spool download`).
fn ffi_native_flags(string root) -> Result<Vec<string>, string> {
    return flag_pairs(
        "--ffi-native",
        ffi_native_specs(root, manifest_body(join2(root, "coil.toml"))?)?,
    );
}

// ---- dependency natives (spool#38, coil-tls#17) ----------------------------
// A dependency's coil.toml names its native library relative to its own
// checkout (coil-tls: `[ffi] search_paths = ["./native"]`). Those paths are
// resolved against that checkout (dep_checkouts), never the consumer. They
// locate files only: loading one still needs the consumer's `[ffi] allow` and
// a pin or `trusted = true`.

/// Relative and free of `..` segments, so it stays inside the checkout.
fn inside_checkout(string p) -> bool {
    if p.len() == 0 || path_is_absolute(p) {
        return false;
    }
    let parts = p.split("/");
    let i = 0;
    while i < parts.len() {
        if parts[i] == ".." {
            return false;
        }
        i = i + 1;
    }
    return true;
}

fn is_directory(string p) -> bool {
    if path_exists(p) == false {
        return false;
    }
    return match is_dir(p) {
        Result::Ok(d) => d,
        Result::Err(_) => false,
    };
}

/// A checkout's coil.toml text, or "" without a readable one.
fn checkout_manifest(string checkout) -> string {
    let path = join2(checkout, "coil.toml");
    if path_exists(path) == false {
        return "";
    }
    return match read_text(path) {
        Result::Ok(s) => s,
        Result::Err(_) => "",
    };
}

/// Each linked dependency's `[ffi] search_paths`, resolved against its own
/// checkout, in dependency-name order. Only existing directories inside the
/// checkout: an absolute or `..` path is dropped, and so is a consumer-layout
/// path such as coil-http's `./.spool/deps/tls/native`, which a checkout
/// never has.
fn dep_ffi_search_paths(string root) -> Vec<string> {
    let out: Vec<string> = Vec::new();
    let deps = dep_checkouts(root);
    let i = 0;
    while i < deps.len() {
        let checkout = tsv_field(deps[i], 1);
        i = i + 1;
        let body = checkout_manifest(checkout);
        if body.len() == 0 {
            continue;
        }
        let none: Vec<string> = Vec::new();
        let paths = match section_strings(body, "ffi", "search_paths") {
            Result::Ok(v) => v,
            Result::Err(_) => none,
        };
        let j = 0;
        while j < paths.len() {
            let p = paths[j];
            j = j + 1;
            if inside_checkout(p) == false {
                continue;
            }
            let abs = abs_under(checkout, p);
            if is_directory(abs) {
                out = push_unique(out, abs);
            }
        }
    }
    return out;
}

/// The project's own `[ffi] search_paths`, absolute.
fn own_ffi_search_paths(string root, string body) -> Result<Vec<string>, string> {
    let search = section_strings(body, "ffi", "search_paths")?;
    let out: Vec<string> = Vec::new();
    let i = 0;
    while i < search.len() {
        out = push_unique(out, abs_under(root, search[i]));
        i = i + 1;
    }
    return out;
}

/// The `--ffi-search-path` dirs, in coil's lookup order: the project's own,
/// then each dependency's (dep_ffi_search_paths).
fn ffi_search_dirs(string root, string body) -> Result<Vec<string>, string> {
    let out = own_ffi_search_paths(root, body)?;
    let deps = dep_ffi_search_paths(root);
    let i = 0;
    while i < deps.len() {
        out = push_unique(out, deps[i]);
        i = i + 1;
    }
    return out;
}

/// Whether `dir` holds the shared library for stem `name`
/// (`lib<name>.so`, `lib<name>.dylib` or `<name>.dll`).
fn dir_has_lib(string dir, string name) -> bool {
    return path_exists(join2(dir, "lib" + name + ".so")) ||
           path_exists(join2(dir, "lib" + name + ".dylib")) ||
           path_exists(join2(dir, name + ".dll"));
}

/// `r` with its path field replaced (record layout in manifest.hy).
fn with_native_path(string r, string path) -> string {
    return native_name(r) + "\t" + native_package(r) + "\t" + native_version(r) + "\t" + path + "\t" +
           tsv_field(r, 4) + "\t" + native_requires(r) + "\t" + native_requires_hint(r) + "\t" +
           tsv_field(r, 7);
}

/// The `[[ffi.native]]` rows `coil package` gets, every path absolute: the
/// project's own, then each linked dependency's for a stem the project does
/// not declare itself (first dependency by name wins). A dependency row
/// whose path leaves its checkout is dropped. Its library is taken from the
/// first search dir that holds it (the file `spool test` loads, so a
/// consumer's sibling build in its own search_paths still wins), else from
/// the row's own path, where coil reports it missing.
fn package_native_rows(string root) -> Result<Vec<string>, string> {
    let body = manifest_body(join2(root, "coil.toml"))?;
    let own = ffi_natives_parse(body)?;
    let out: Vec<string> = Vec::new();
    let names: Vec<string> = Vec::new();
    let i = 0;
    while i < own.len() {
        out.push(with_native_path(own[i], abs_under(root, native_path(own[i]))));
        names = push_unique(names, native_name(own[i]));
        i = i + 1;
    }
    let search = ffi_search_dirs(root, body)?;
    let deps = dep_checkouts(root);
    i = 0;
    while i < deps.len() {
        let dep = tsv_field(deps[i], 0);
        let checkout = tsv_field(deps[i], 1);
        i = i + 1;
        let dep_body = checkout_manifest(checkout);
        if dep_body.len() == 0 {
            continue;
        }
        let rows = match ffi_natives_parse(dep_body) {
            Result::Ok(v) => v,
            Result::Err(e) => raise format("dependency %s: %s", dep, e),
        };
        let j = 0;
        while j < rows.len() {
            let r = rows[j];
            j = j + 1;
            if vec_has(names, native_name(r)) || inside_checkout(native_path(r)) == false {
                continue;
            }
            names.push(native_name(r));
            let dir = abs_under(checkout, native_path(r));
            let k = 0;
            while k < search.len() {
                if dir_has_lib(search[k], native_name(r)) {
                    dir = search[k];
                    break;
                }
                k = k + 1;
            }
            out.push(with_native_path(r, dir));
        }
    }
    return out;
}

/// `--ffi-native SPEC` pairs for `coil package` (`spool build` / `run`): the
/// project's rows and its dependencies' (package_native_rows).
fn package_native_flags(string root) -> Result<Vec<string>, string> {
    let rows = package_native_rows(root)?;
    let specs: Vec<string> = Vec::new();
    let i = 0;
    while i < rows.len() {
        specs.push(native_spec(root, rows[i]));
        i = i + 1;
    }
    return flag_pairs("--ffi-native", specs);
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
    manifest_validate(body)?;
    let out: Vec<string> = Vec::new();
    // `[permissions] read = true` → `--allow-read`; `all = true` → `-A`.
    if section_bool(body, "permissions", "all")? {
        out.push("--allow-all");
    }
    let caps = ["read", "write", "net", "env", "exec", "exit", "attach"];
    let c = 0;
    while c < caps.len() {
        if section_bool(body, "permissions", caps[c])? {
            out.push("--allow-" + caps[c]);
        }
        c = c + 1;
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
    while i < stems.len() {
        out.push("--allow-dload");
        out.push(stems[i]);
        i = i + 1;
    }
    // The project's own search paths, then each dependency's (spool#38).
    let search = ffi_search_dirs(root, body)?;
    i = 0;
    while i < search.len() {
        out.push("--ffi-search-path");
        out.push(search[i]);
        i = i + 1;
    }
    let dload = dload_flags(body, lock_text(root))?;
    i = 0;
    while i < dload.len() {
        out.push(dload[i]);
        i = i + 1;
    }
    let ct = comptime_flags(root, body)?;
    i = 0;
    while i < ct.len() {
        out.push(ct[i]);
        i = i + 1;
    }
    return out;
}

/// The `[comptime]` grant keys, each a `--comptime-<key>` flag.
fn comptime_kinds() -> Vec<string> {
    return ["read", "write", "env", "net"];
}

/// `--comptime-<key> VALUE` for each `[comptime]` grant in `body`, each value
/// prefixed with `scope` (`""`, or `module=`). Paths are made absolute under
/// `base`, so a dependency's are its own.
fn comptime_grants(string body, string base, string scope) -> Result<Vec<string>, string> {
    let out: Vec<string> = Vec::new();
    let kinds = comptime_kinds();
    let k = 0;
    while k < kinds.len() {
        let kind = kinds[k];
        k = k + 1;
        let values = section_strings(body, "comptime", kind)?;
        let i = 0;
        while i < values.len() {
            let v = values[i];
            i = i + 1;
            if kind == "read" || kind == "write" {
                v = abs_under(base, v);
            }
            out.push("--comptime-" + kind);
            out.push(scope + v);
        }
    }
    return out;
}

/// The top-level modules a dependency provides: the `.hy` files and the
/// directories in its module root (`json.hy` and `json/` are `json`).
fn dep_top_modules(string checkout) -> Vec<string> {
    let out: Vec<string> = Vec::new();
    let dir = checkout_module_root(checkout);
    let entries = match list_dir(dir) {
        Result::Ok(v) => v,
        Result::Err(_) => {
            return out;
        },
    };
    let i = 0;
    while i < entries.len() {
        let name = entries[i];
        i = i + 1;
        if name.starts_with(".") {
            continue;
        }
        if name.ends_with(".hy") {
            name = match name.slice(0, name.len() - 3) {
                Result::Ok(s) => s,
                Result::Err(_) => name,
            };
        } else {
            let sub = match is_dir(join2(dir, name)) {
                Result::Ok(d) => d,
                Result::Err(_) => false,
            };
            if sub == false {
                continue;
            }
        }
        if vec_has(out, name) == false {
            out.push(name);
        }
    }
    return out;
}

/// Compile-time grants and the result cache (comptime step 14): the
/// project's `[comptime]` grants for every module, `--comptime-cache` at
/// `[comptime] cache` (default `.comptime`, meant to be committed), and the
/// `[comptime]` grants of each dependency that `spool allow-comptime`
/// allowed, scoped to that dependency's modules. A dependency that asks for
/// grants it was not given gets a note on stderr instead.
fn comptime_flags(string root, string body) -> Result<Vec<string>, string> {
    let out = comptime_grants(body, root, "")?;
    let cache = section_string(body, "comptime", "cache")?;
    if cache.len() == 0 {
        cache = ".comptime";
    }
    out.push("--comptime-cache");
    out.push(abs_under(root, cache));
    let allowed = lock_allow_comptime(lock_text(root))?;
    let deps = dep_checkouts(root);
    let i = 0;
    while i < deps.len() {
        let name = tsv_field(deps[i], 0);
        let checkout = tsv_field(deps[i], 1);
        i = i + 1;
        let manifest = join2(checkout, "coil.toml");
        if path_exists(manifest) == false {
            continue;
        }
        let dep_body = manifest_body(manifest)?;
        let wanted = comptime_grants(dep_body, checkout, "")?;
        if wanted.len() == 0 {
            continue;
        }
        if vec_has(allowed, name) == false {
            eprintln(
                format(
                    "spool: %s asks for compile-time grants ([comptime] in its coil.toml); `spool allow-comptime %s` gives them",
                    name,
                    name,
                ),
            );
            continue;
        }
        let modules = dep_top_modules(checkout);
        let m = 0;
        while m < modules.len() {
            let scoped = comptime_grants(dep_body, checkout, modules[m] + "=")?;
            m = m + 1;
            let j = 0;
            while j < scoped.len() {
                out.push(scoped[j]);
                j = j + 1;
            }
        }
    }
    return out;
}

/// `--root <dir>` pairs plus grant flags, ready to append to a coil subcommand.
fn compile_flags(string root) -> Result<Vec<string>, string> {
    let roots = project_roots(root)?;
    let out: Vec<string> = Vec::new();
    let i = 0;
    while i < roots.len() {
        out.push("--root");
        out.push(roots[i]);
        i = i + 1;
    }
    let grants = grant_flags(root)?;
    i = 0;
    while i < grants.len() {
        out.push(grants[i]);
        i = i + 1;
    }
    return out;
}
