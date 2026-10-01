// `spool download`: fetch direct FFI natives into
// ~/.coil/natives/cache/<package>/<version>/<sha256_16>/<filename>
// (root overridable with COIL_NATIVES_DIR). Input is `coil natives dump --tsv`.
use term::{println};
use io::fs::{rename, remove_file};
use text::{starts_with, slice, contains, to_lower};
use string::{format};
use util::{join2, ensure_dir, path_exists, home_dir, lines_of, trim_or, tsv_field};
use proc::{sh_capture, sh_run, first_line};
use toolchain::{env_or};

fn natives_root() -> Result<string, string> {
    let r = env_or("COIL_NATIVES_DIR", "");
    if len(r) > 0 {
        return r;
    }
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
    let os = match to_lower(cmd_line("uname -s")) {
        Result::Ok(s) => s,
        Result::Err(_) => "",
    };
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
    return match slice(s, len(prefix), len(s)) {
        Result::Ok(x) => trim_or(x),
        Result::Err(_) => "",
    };
}

fn drop_file(string p) {
    match remove_file(p) {
        Result::Ok(_) => 0,
        Result::Err(_) => 0,
    };
}

/// Lock fields become path segments; keep them to one plain segment.
fn safe_segment(string what, string s) -> Result<int, string> {
    if len(s) == 0 || s == "." || s == ".." || contains(s, "/") || contains(s, "\\") {
        raise format("native lock has an unsafe %s: %s", what, s);
    }
    return 0;
}

fn fetch_one(string root, string package, string version, string filename, string url, string sha, string size) -> Result<bool, string> {
    if starts_with(url, "https://") == false {
        raise format("%s: native url must be https://, got %s", package, url);
    }
    safe_segment("package", package)?;
    safe_segment("version", version)?;
    safe_segment("filename", filename)?;
    if len(sha) < 16 {
        raise format("%s: native lock has no sha256", package);
    }
    let hash16 = match slice(sha, 0, 16) {
        Result::Ok(x) => x,
        Result::Err(_) => sha,
    };
    let dest_dir = join2(join2(join2(join2(root, "cache"), package), version), hash16);
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
    drop_file(part);
    let a: Vec<string> = Vec::new();
    a.push(part);
    a.push(url);
    let code = sh_run("curl -fsSL --proto '=https' --proto-redir '=https' -o \"$1\" \"$2\"", a)?;
    if code != 0 {
        drop_file(part);
        raise format("failed to fetch %s", url);
    }
    let got = sha256_of(part)?;
    if got != sha {
        drop_file(part);
        raise format("sha256 mismatch for %s: expected %s, got %s", package, sha, got);
    }
    if len(size) > 0 && size != "0" {
        let got_size = size_of(part);
        if got_size != size {
            drop_file(part);
            raise format("size mismatch for %s: expected %s, got %s", package, size, got_size);
        }
    }
    match rename(part, dest) {
        Result::Ok(_) => 0,
        Result::Err(_) => raise format("cannot move %s into place", dest),
    };
    println(format("spool download: installed %s %s -> %s", package, version, dest));
    return true;
}

/// Download natives for a packaged exe (`exe` non-empty) or the project.
fn download_natives(string coil, string project_root, string exe) -> Result<int, string> {
    let a: Vec<string> = Vec::new();
    a.push(project_root);
    a.push(coil);
    let script = "cd \"$1\" || exit 125; \"$2\" natives dump --tsv";
    if len(exe) > 0 {
        a.push(exe);
        script = "cd \"$1\" || exit 125; \"$2\" natives dump --tsv \"$3\"";
    }
    let res = sh_capture(script, a)?;
    let (code, tsv) = res;
    if code != 0 {
        if len(exe) > 0 {
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
    let rows = lines_of(tsv);
    let i = 0;
    while i < len(rows) {
        let line = rows[i];
        i = i + 1;
        if starts_with(line, "# os=") {
            lock_os = after_prefix(line, "# os=");
            continue;
        }
        if starts_with(line, "# arch=") {
            lock_arch = after_prefix(line, "# arch=");
            continue;
        }
        if starts_with(line, "#") {
            continue;
        }
        if len(lock_os) > 0 && lock_os != os {
            raise format("native lock os=%s but host is %s", lock_os, os);
        }
        if len(lock_arch) > 0 && lock_arch != arch {
            raise format("native lock arch=%s but host is %s", lock_arch, arch);
        }
        let package = tsv_field(line, 0);
        if len(package) == 0 {
            continue;
        }
        let fetched = fetch_one(
            root,
            package,
            tsv_field(line, 1),
            tsv_field(line, 2),
            tsv_field(line, 3),
            tsv_field(line, 4),
            tsv_field(line, 5),
        )?;
        if fetched {
            installed = installed + 1;
        } else {
            skipped = skipped + 1;
        }
    }
    if installed == 0 && skipped == 0 {
        println("spool download: nothing to download");
    } else {
        println(format("spool download: ok (%i installed, %i skipped)", installed, skipped));
    }
    return 0;
}
