// `spool download`: fetch direct FFI natives into
// ~/.coil/natives/cache/<package>/<version>/<sha256_16>/<filename>,
// where a packaged app looks for them. The pins come from
// `coil natives dump --tsv` (package, version, filename, sha256, size); coil
// carries no URLs, so each one comes from the project's `[[ffi.native]] url`.
// In project mode a row whose local file is not there yet is dumped as
// `missing` (no sha256); spool fetches it to that row's `path`, where
// `coil package` reads it and pins its hash. With a `[[ffi.native]] sha256`
// the download must match it; without one only https vouches for it until
// then, and spool says so with a warning.
use term::{println, eprintln};
use io::fs::{rename, remove_file};
use text::{Searchable, Text};
use string::format;
use util::{join2, ensure_dir, path_exists, home_dir, lines_of, trim_or, tsv_field};
use proc::{sh_capture, sh_run, first_line};
use toolchain::{ffi_native_flags, abs_under};
use manifest::{manifest_body, ffi_natives_parse, native_name, native_package, native_version, native_url, native_path, native_sha256};

fn natives_root() -> Result<string, string> {
    let h = home_dir()?;
    return join2(h, ".coil/natives");
}

fn cmd_line(string script) -> string {
    let a: Vec<string> = Vec::new();
    return match sh_capture(script, a) {
        Result::Ok(res) => {
            let (code, body) = res;
            return first_line(body);
        },
        Result::Err(_) => "",
    };
}

/// Rust `std::env::consts::OS` spelling (linux, macos, windows, …).
fn host_os() -> string {
    let os = cmd_line("uname -s").to_lower();
    if os == "darwin" {
        return "macos";
    }
    return os;
}

fn host_arch() -> string {
    let m = cmd_line("uname -m");
    if m == "amd64" {
        return "x86_64";
    }
    if m == "arm64" {
        return "aarch64";
    }
    return m;
}

fn sha256_of(string file) -> Result<string, string> {
    let a: Vec<string> = Vec::new();
    a.push(file);
    let res = sh_capture(
        "if command -v sha256sum >/dev/null 2>&1; then sha256sum \"$1\"; else shasum -a 256 \"$1\"; fi | awk '{print $1}'",
        a,
    )?;
    let (code, body) = res;
    if code != 0 {
        raise format("sha256 failed for %s", file);
    }
    return first_line(body);
}

fn size_of(string file) -> string {
    let a: Vec<string> = Vec::new();
    a.push(file);
    return match sh_capture("wc -c < \"$1\" | tr -d ' '", a) {
        Result::Ok(res) => {
            let (code, body) = res;
            return first_line(body);
        },
        Result::Err(_) => "",
    };
}

fn after_prefix(string s, string prefix) -> string {
    return match s.slice(prefix.len(), s.len()) {
        Result::Ok(x) => trim_or(x),
        Result::Err(_) => "",
    };
}

fn drop_file(string p) {
    match remove_file(p) {
        Result::Ok(_) => 0,
        Result::Err(_) => 0,
    }
}

/// Lock fields become path segments; keep them to one plain segment.
fn safe_segment(string what, string s) -> Result<int, string> {
    if s.len() == 0 || s == "." || s == ".." || s.contains("/") || s.contains("\\") {
        raise format("native lock has an unsafe %s: %s", what, s);
    }
    return 0;
}

fn cache_dir_for(string root, string package, string version, string hash16) -> string {
    return join2(join2(join2(join2(root, "cache"), package), version), hash16);
}

/// Fetch `url` (https only) to `part`; on failure `part` is removed.
fn curl_to(string part, string url) -> Result<int, string> {
    drop_file(part);
    let a: Vec<string> = Vec::new();
    a.push(part);
    a.push(url);
    let code = sh_run("curl -fsSL --proto '=https' --proto-redir '=https' -o \"$1\" \"$2\"", a)?;
    if code != 0 {
        drop_file(part);
        raise format("failed to fetch %s", url);
    }
    return 0;
}

/// A project row `coil natives dump` marks `missing`: its local file is not
/// there yet, so coil has no pin for it. It is fetched (https only) to
/// `dest_dir` (the row's resolved `path`), where `coil package` hashes and
/// pins it. With the row's own `sha256` the download must match it (else it
/// is removed and this fails); without one it is placed unchecked, with a
/// warning. A file already at `dest_dir` is left alone.
fn fetch_missing(
    string dest_dir,
    string name,
    string package,
    string version,
    string filename,
    string url,
    string sha,
) -> Result<bool, string> {
    if url.starts_with("https://") == false {
        raise format("%s: native url must be https://, got %s", package, url);
    }
    safe_segment("filename", filename)?;
    let dest = join2(dest_dir, filename);
    if path_exists(dest) {
        println(format("spool download: skip %s %s (%s is there now)", package, version, dest));
        return false;
    }
    ensure_dir(dest_dir)?;
    let part = dest + ".part";
    curl_to(part, url)?;
    if sha.len() == 0 {
        match rename(part, dest) {
            Result::Ok(_) => 0,
            Result::Err(_) => raise format("cannot move %s into place", dest),
        }
        eprintln(
            format(
                "spool download: WARNING: fetched %s %s -> %s over https without a hash check (sha256 %s); coil package pins it when it hashes it. Add sha256 = \"<hex>\" to [[ffi.native]] %s to check it",
                package,
                version,
                dest,
                sha256_of(dest)?,
                name,
            ),
        );
        return true;
    }
    let got = sha256_of(part)?;
    if got != sha {
        drop_file(part);
        raise format("sha256 mismatch for %s: expected %s, got %s", package, sha, got);
    }
    match rename(part, dest) {
        Result::Ok(_) => 0,
        Result::Err(_) => raise format("cannot move %s into place", dest),
    }
    println(
        format(
            "spool download: fetched %s %s -> %s (sha256 %s verified)",
            package,
            version,
            dest,
            sha,
        ),
    );
    return true;
}

fn fetch_one(
    string root,
    string package,
    string version,
    string filename,
    string url,
    string sha,
    string size,
) -> Result<bool, string> {
    if url.starts_with("https://") == false {
        raise format("%s: native url must be https://, got %s", package, url);
    }
    safe_segment("package", package)?;
    safe_segment("version", version)?;
    safe_segment("filename", filename)?;
    if sha.len() < 16 {
        raise format("%s: native lock has no sha256", package);
    }
    let hash16 = match sha.slice(0, 16) {
        Result::Ok(x) => x,
        Result::Err(_) => sha,
    };
    let dest_dir = cache_dir_for(root, package, version, hash16);
    let dest = join2(dest_dir, filename);
    if path_exists(dest) {
        if sha256_of(dest)? == sha {
            println(format("spool download: skip %s %s (%s)", package, version, filename));
            return false;
        }
        println(format("spool download: hash mismatch for %s; re-fetching", dest));
        drop_file(dest);
    }
    ensure_dir(dest_dir)?;
    let part = dest + ".part";
    curl_to(part, url)?;
    let got = sha256_of(part)?;
    if got != sha {
        drop_file(part);
        raise format("sha256 mismatch for %s: expected %s, got %s", package, sha, got);
    }
    if size.len() > 0 && size != "0" {
        let got_size = size_of(part);
        if got_size != size {
            drop_file(part);
            raise format("size mismatch for %s: expected %s, got %s", package, size, got_size);
        }
    }
    match rename(part, dest) {
        Result::Ok(_) => 0,
        Result::Err(_) => raise format("cannot move %s into place", dest),
    }
    println(format("spool download: installed %s %s -> %s", package, version, dest));
    return true;
}

/// `[[ffi.native]]` rows of `root`'s coil.toml (none without one).
fn manifest_natives(string root) -> Result<Vec<string>, string> {
    let path = join2(root, "coil.toml");
    if path_exists(path) == false {
        let empty: Vec<string> = Vec::new();
        return empty;
    }
    return ffi_natives_parse(manifest_body(path)?)?;
}

/// Whether `filename` is the platform library file for stem `name`.
fn lib_file_of(string filename, string name) -> bool {
    let exts = [".so", ".dylib", ".dll"];
    let i = 0;
    while i < exts.len() {
        let ext = exts[i];
        if filename == "lib" + name + ext {
            return true;
        }
        if filename == name + ext {
            return true;
        }
        i = i + 1;
    }
    return false;
}

/// The `[[ffi.native]]` row for a dump row: same package and version, and
/// (when several rows share those) the row whose stem names `filename`.
/// Empty when none matches.
fn manifest_row_for(Vec<string> rows, string package, string version, string filename) -> string {
    let found = "";
    let hits = 0;
    let i = 0;
    while i < rows.len() {
        let r = rows[i];
        i = i + 1;
        if native_package(r) != package || native_version(r) != version {
            continue;
        }
        if lib_file_of(filename, native_name(r)) {
            return r;
        }
        found = r;
        hits = hits + 1;
    }
    if hits == 1 {
        return found;
    }
    return "";
}

/// The `[[ffi.native]] url` for a dump row (see `manifest_row_for`).
fn url_for(Vec<string> rows, string package, string version, string filename) -> string {
    let r = manifest_row_for(rows, package, version, filename);
    if r.len() == 0 {
        return "";
    }
    return native_url(r);
}

/// Download natives for a packaged exe (`exe` non-empty) or the project.
/// URLs come from `project_root`'s `[[ffi.native]]`; a row with none is
/// skipped (the app also finds a library beside the exe or in its `lib/`).
fn download_natives(string coil, string project_root, string exe) -> Result<int, string> {
    let rows = manifest_natives(project_root)?;
    let a: Vec<string> = Vec::new();
    a.push(project_root);
    a.push(coil);
    a.push("natives");
    a.push("dump");
    a.push("--tsv");
    if exe.len() > 0 {
        a.push(exe);
    } else {
        let flags = ffi_native_flags(project_root)?;
        let f = 0;
        while f < flags.len() {
            a.push(flags[f]);
            f = f + 1;
        }
    }
    let res = sh_capture("cd \"$1\" || exit 125; shift; \"$@\"", a)?;
    let (code, tsv) = res;
    if code != 0 {
        if exe.len() > 0 {
            raise format("coil natives dump failed for %s", exe);
        }
        raise "coil natives dump failed (project mode)";
    }
    let root = natives_root()?;
    let os = host_os();
    let arch = host_arch();
    let lock_os = "";
    let lock_arch = "";
    let installed = 0;
    let skipped = 0;
    let no_url = 0;
    let lines = lines_of(tsv);
    let i = 0;
    while i < lines.len() {
        let line = lines[i];
        i = i + 1;
        if line.starts_with("# os=") {
            lock_os = after_prefix(line, "# os=");
            continue;
        }
        if line.starts_with("# arch=") {
            lock_arch = after_prefix(line, "# arch=");
            continue;
        }
        if line.starts_with("#") {
            continue;
        }
        if lock_os.len() > 0 && lock_os != os {
            raise format("native lock os=%s but host is %s", lock_os, os);
        }
        if lock_arch.len() > 0 && lock_arch != arch {
            raise format("native lock arch=%s but host is %s", lock_arch, arch);
        }
        let package = tsv_field(line, 0);
        if package.len() == 0 {
            continue;
        }
        let version = tsv_field(line, 1);
        let filename = tsv_field(line, 2);
        let url = url_for(rows, package, version, filename);
        if url.len() == 0 {
            println(
                format(
                    "spool download: no [[ffi.native]] url for %s %s (%s); skipped",
                    package,
                    version,
                    filename,
                ),
            );
            no_url = no_url + 1;
            continue;
        }
        let fetched = false;
        if tsv_field(line, 5) == "missing" {
            if exe.len() > 0 {
                raise format("native lock in %s has no sha256 for %s", exe, package);
            }
            let r = manifest_row_for(rows, package, version, filename);
            fetched = fetch_missing(
                abs_under(project_root, native_path(r)),
                native_name(r),
                package,
                version,
                filename,
                url,
                native_sha256(r),
            )?;
        } else {
            fetched = fetch_one(
                root,
                package,
                version,
                filename,
                url,
                tsv_field(line, 3),
                tsv_field(line, 4),
            )?;
        }
        if fetched {
            installed = installed + 1;
        } else {
            skipped = skipped + 1;
        }
    }
    if installed == 0 && skipped == 0 && no_url == 0 {
        println("spool download: nothing to download");
    } else {
        println(
            format(
                "spool download: ok (%i installed, %i skipped, %i without url)",
                installed,
                skipped,
                no_url,
            ),
        );
    }
    return 0;
}

/// The row (package_native_rows: absolute paths) a dump line came from.
fn row_for(Vec<string> rows, string package, string version, string filename) -> string {
    let i = 0;
    while i < rows.len() {
        let r = rows[i];
        i = i + 1;
        if native_package(r) == package &&
           native_version(r) == version &&
           lib_file_of(filename, native_name(r)) {
            return r;
        }
    }
    return "";
}

/// After `spool build`: copy each native the packaged `exe` pins from the
/// local file it was packaged from (`rows`, the `--ffi-native` rows) into the
/// natives cache, where the exe looks first, so it runs on this machine with
/// no `spool download` and no URL. A cache entry with the right sha256 is
/// left alone; a local file that no longer matches the pin is an error.
fn cache_packaged_natives(
    string coil,
    string project_root,
    string exe,
    Vec<string> rows,
) -> Result<int, string> {
    if rows.len() == 0 {
        return 0;
    }
    let a: Vec<string> = Vec::new();
    a.push(project_root);
    a.push(coil);
    a.push(exe);
    let res = sh_capture("cd \"$1\" || exit 125; \"$2\" natives dump --tsv \"$3\" 2>&1", a)?;
    let (code, tsv) = res;
    if code != 0 {
        // No library the program loads needed a row: nothing to cache.
        if tsv.contains("no embedded native lock") {
            return 0;
        }
        raise format("coil natives dump failed for %s: %s", exe, first_line(tsv));
    }
    let root = natives_root()?;
    let lines = lines_of(tsv);
    let i = 0;
    while i < lines.len() {
        let line = lines[i];
        i = i + 1;
        if line.starts_with("#") {
            continue;
        }
        let package = tsv_field(line, 0);
        let version = tsv_field(line, 1);
        let filename = tsv_field(line, 2);
        let sha = tsv_field(line, 3);
        if package.len() == 0 || sha.len() < 16 {
            continue;
        }
        let r = row_for(rows, package, version, filename);
        if r.len() == 0 {
            continue;
        }
        safe_segment("package", package)?;
        safe_segment("version", version)?;
        safe_segment("filename", filename)?;
        let hash16 = match sha.slice(0, 16) {
            Result::Ok(x) => x,
            Result::Err(_) => sha,
        };
        let dest_dir = cache_dir_for(root, package, version, hash16);
        let dest = join2(dest_dir, filename);
        if path_exists(dest) {
            if sha256_of(dest)? == sha {
                continue;
            }
            drop_file(dest);
        }
        let src = join2(native_path(r), filename);
        if sha256_of(src)? != sha {
            raise format("%s changed while packaging %s; build again", src, exe);
        }
        ensure_dir(dest_dir)?;
        let part = dest + ".part";
        drop_file(part);
        let c: Vec<string> = Vec::new();
        c.push(src);
        c.push(part);
        if sh_run("cp -- \"$1\" \"$2\"", c)? != 0 {
            drop_file(part);
            raise format("cannot copy %s into the natives cache", src);
        }
        match rename(part, dest) {
            Result::Ok(_) => 0,
            Result::Err(_) => raise format("cannot move %s into place", dest),
        }
        eprintln(format("spool: cached native %s %s (%s) -> %s", package, version, filename, dest));
    }
    return 0;
}
