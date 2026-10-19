// Pure git-URL → cache key helpers (no env::exec — safe for coil test).
use text::{split, starts_with, ends_with, contains, trim, slice, find};
use string::{format};

fn replace_first_colon(string s) -> string {
    if contains(s, ":") == false {
        return s;
    }
    let parts = match split(s, ":") {
        Result::Ok(p) => p,
        Result::Err(_) => {
            let empty: Vec<string> = Vec::new();
            empty
        },
    };
    if parts.len() < 2 {
        return s;
    }
    let out = parts[0] + "/" + parts[1];
    let i = 2;
    while i < parts.len() {
        out = out + ":" + parts[i];
        i = i + 1;
    }
    return out;
}

fn strip_scheme(string url) -> string {
    let u = match trim(url) {
        Result::Ok(t) => t,
        Result::Err(_) => url,
    };
    if starts_with(u, "https://") {
        let parts = match split(u, "https://") {
            Result::Ok(p) => p,
            Result::Err(_) => {
                let empty: Vec<string> = Vec::new();
                empty
            },
        };
        if parts.len() >= 2 {
            return parts[1];
        }
        return u;
    }
    if starts_with(u, "http://") {
        let parts = match split(u, "http://") {
            Result::Ok(p) => p,
            Result::Err(_) => {
                let empty: Vec<string> = Vec::new();
                empty
            },
        };
        if parts.len() >= 2 {
            return parts[1];
        }
        return u;
    }
    if starts_with(u, "ssh://") || starts_with(u, "git://") {
        let after = match slice(u, 6, u.len()) {
            Result::Ok(x) => x,
            Result::Err(_) => u,
        };
        let at = find(after, "@");
        let slash = find(after, "/");
        if at >= 0 && (slash < 0 || at < slash) {
            return match slice(after, at + 1, after.len()) {
                Result::Ok(x) => x,
                Result::Err(_) => after,
            };
        }
        return after;
    }
    if starts_with(u, "git@") {
        let parts = match split(u, "git@") {
            Result::Ok(p) => p,
            Result::Err(_) => {
                let empty: Vec<string> = Vec::new();
                empty
            },
        };
        if parts.len() >= 2 {
            return replace_first_colon(parts[1]);
        }
        return u;
    }
    if starts_with(u, "file://") {
        let parts = match split(u, "file://") {
            Result::Ok(p) => p,
            Result::Err(_) => {
                let empty: Vec<string> = Vec::new();
                empty
            },
        };
        if parts.len() >= 2 {
            return parts[1];
        }
        return u;
    }
    return u;
}

/// Drop one trailing `.git` (and trailing slashes). Only the suffix counts:
/// `my.gitea.io/o/r.git` keeps its host.
fn strip_git_suffix(string s) -> string {
    let t = s;
    while ends_with(t, "/") && t.len() > 1 {
        t = match slice(t, 0, t.len() - 1) {
            Result::Ok(x) => x,
            Result::Err(_) => t,
        };
    }
    if ends_with(t, ".git") && t.len() > 4 {
        return match slice(t, 0, t.len() - 4) {
            Result::Ok(x) => x,
            Result::Err(_) => t,
        };
    }
    return t;
}

/// Returns (host, owner, repo) for a remote URL.
/// For path-like URLs (`file://…` or bare paths), uses the last three
/// non-empty path segments so local fixtures can live under
/// `…/github.com/acme/widgets`.
fn url_cache_key(string url) -> Result<(string, string, string), string> {
    let rest = strip_git_suffix(strip_scheme(url));
    let parts = match split(rest, "/") {
        Result::Ok(p) => p,
        Result::Err(_) => raise "bad url path",
    };
    let segs: Vec<string> = Vec::new();
    let i = 0;
    while i < parts.len() {
        if parts[i].len() > 0 {
            segs.push(parts[i]);
        }
        i = i + 1;
    }
    if segs.len() < 3 {
        raise format("cannot parse git url: %s", url);
    }
    let n = segs.len();
    return (segs[n - 3], segs[n - 2], segs[n - 1]);
}
