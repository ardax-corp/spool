// Path, text and validation helpers shared across modules (no env::exec).
// String joins live here: stdlib `path` is a Path class and shadows join/dirname.
use io::fs::{exists, create_dir_all};
use io::file::{write_text, read_text};
use env::{var};
use string::{format};
use text::{starts_with, ends_with, slice, split, trim, contains};

fn join2(string a, string b) -> string {
    if len(a) == 0 {
        return b;
    }
    if len(b) == 0 {
        return a;
    }
    if starts_with(b, "/") {
        return b;
    }
    if ends_with(a, "/") {
        return a + b;
    }
    return a + "/" + b;
}

fn join3(string a, string b, string c) -> string {
    return join2(join2(a, b), c);
}

fn join4(string a, string b, string c, string d) -> string {
    return join2(join3(a, b, c), d);
}

fn path_is_absolute(string p) -> bool {
    return starts_with(p, "/");
}

fn path_dirname(string p) -> string {
    if len(p) == 0 {
        return ".";
    }
    let s = p;
    while len(s) > 1 {
        if ends_with(s, "/") == false {
            break;
        }
        let chopped = match slice(s, 0, len(s) - 1) {
            Result::Ok(x) => x,
            Result::Err(_) => s,
        };
        if chopped == s {
            break;
        }
        s = chopped;
    }
    let parts = match split(s, "/") {
        Result::Ok(v) => v,
        Result::Err(_) => {
            return ".";
        },
    };
    if len(parts) <= 1 {
        return ".";
    }
    let last = len(parts) - 1;
    if last == 1 {
        if parts[0] == "" {
            return "/";
        }
        return parts[0];
    }
    let out = parts[0];
    let i = 1;
    while i < last {
        if len(out) == 0 {
            out = "/" + parts[i];
        } else {
            out = out + "/" + parts[i];
        }
        i = i + 1;
    }
    if len(out) == 0 {
        return "/";
    }
    return out;
}

fn home_dir() -> Result<string, string> {
    return match var("HOME") {
        Result::Ok(h) => h,
        Result::Err(_) => raise "HOME is not set",
    };
}

fn ensure_dir(string path) -> Result<int, string> {
    let present = match exists(path) {
        Result::Ok(v) => v,
        Result::Err(_) => false,
    };
    if present {
        return 0;
    }
    return match create_dir_all(path) {
        Result::Ok(_) => 0,
        Result::Err(_) => raise format("mkdir failed: %s", path),
    };
}

fn path_exists(string p) -> bool {
    return match exists(p) {
        Result::Ok(v) => v,
        Result::Err(_) => false,
    };
}

fn read_or_empty(string p) -> string {
    if path_exists(p) == false {
        return "";
    }
    return match read_text(p) {
        Result::Ok(s) => s,
        Result::Err(_) => "",
    };
}

fn trim_or(string s) -> string {
    return match trim(s) {
        Result::Ok(t) => t,
        Result::Err(_) => s,
    };
}

fn lines_of(string body) -> Vec<string> {
    let out: Vec<string> = Vec::new();
    if len(body) == 0 {
        return out;
    }
    let parts = match split(body, "\n") {
        Result::Ok(v) => v,
        Result::Err(_) => {
            return out;
        },
    };
    let i = 0;
    while i < len(parts) {
        let line = trim_or(parts[i]);
        i = i + 1;
        if len(line) > 0 {
            out.push(line);
        }
    }
    return out;
}

fn tsv_field(string row, int idx) -> string {
    let parts = match split(row, "\t") {
        Result::Ok(v) => v,
        Result::Err(_) => {
            let empty: Vec<string> = Vec::new();
            empty
        },
    };
    if idx < len(parts) {
        return parts[idx];
    }
    return "";
}

fn vec_has(Vec<string> xs, string x) -> bool {
    let i = 0;
    while i < len(xs) {
        if xs[i] == x {
            return true;
        }
        i = i + 1;
    }
    return false;
}

fn char_in(string c, string set) -> bool {
    return contains(set, c);
}

/// Package names become paths under `.spool/deps` and cache keys, so they
/// are restricted to `[A-Za-z0-9_-]`, starting with a letter or `_`.
fn valid_pkg_name(string name) -> bool {
    let n = len(name);
    if n == 0 {
        return false;
    }
    if n > 64 {
        return false;
    }
    let lower = "abcdefghijklmnopqrstuvwxyz";
    let upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    let digits = "0123456789";
    let i = 0;
    while i < n {
        let c = match slice(name, i, i + 1) {
            Result::Ok(s) => s,
            Result::Err(_) => {
                return false;
            },
        };
        let ok = char_in(c, lower) || char_in(c, upper) || c == "_";
        if i > 0 {
            ok = ok || char_in(c, digits) || c == "-";
        }
        if ok == false {
            return false;
        }
        i = i + 1;
    }
    return true;
}

fn check_pkg_name(string name) -> Result<int, string> {
    if valid_pkg_name(name) == false {
        raise format("invalid package name `%s` (use letters, digits, `_` or `-`)", name);
    }
    return 0;
}

/// Git remotes spool will hand to `git`. Rejects option-looking values and
/// transports that run commands (`ext::`), whitespace and control bytes.
fn valid_git_url(string url) -> bool {
    if len(url) == 0 {
        return false;
    }
    if starts_with(url, "-") {
        return false;
    }
    if contains(url, " ") || contains(url, "\t") || contains(url, "\n") {
        return false;
    }
    if starts_with(url, "https://") || starts_with(url, "http://") {
        return true;
    }
    if starts_with(url, "ssh://") || starts_with(url, "git://") {
        return true;
    }
    if starts_with(url, "file://") || starts_with(url, "/") {
        return true;
    }
    if starts_with(url, "git@") {
        return true;
    }
    return false;
}

fn check_git_url(string url) -> Result<int, string> {
    if valid_git_url(url) == false {
        raise format("unsupported git url `%s` (use https://, ssh://, git@host:, git:// or file://)", url);
    }
    return 0;
}
