// Pure git-URL → cache key helpers (no env::exec — safe for coil test).
use text::{split, starts_with, contains, trim};
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
    if len(parts) < 2 {
        return s;
    }
    let out = parts[0] + "/" + parts[1];
    let i = 2;
    while i < len(parts) {
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
        if len(parts) >= 2 {
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
        if len(parts) >= 2 {
            return parts[1];
        }
        return u;
    }
    if starts_with(u, "git@") {
        let parts = match split(u, "git@") {
            Result::Ok(p) => p,
            Result::Err(_) => {
                let empty: Vec<string> = Vec::new();
                empty
            },
        };
        if len(parts) >= 2 {
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
        if len(parts) >= 2 {
            return parts[1];
        }
        return u;
    }
    return u;
}

fn strip_git_suffix(string s) -> string {
    let parts = match split(s, ".git") {
        Result::Ok(p) => p,
        Result::Err(_) => {
            let empty: Vec<string> = Vec::new();
            empty
        },
    };
    if len(parts) >= 1 {
        return parts[0];
    }
    return s;
}

/// Returns (host, owner, repo) for a remote URL.
/// For path-like URLs (`file://…` or bare paths), uses the last three
/// non-empty path segments so local fixtures can live under
/// `…/github.com/acme/widgets`.
fn url_cache_key(string url) -> Result<(string, string, string), string> {
    let rest = strip_scheme(url);
    if contains(rest, ".git") {
        rest = strip_git_suffix(rest);
    }
    let parts = match split(rest, "/") {
        Result::Ok(p) => p,
        Result::Err(_) => raise "bad url path",
    };
    let segs: Vec<string> = Vec::new();
    let i = 0;
    while i < len(parts) {
        if len(parts[i]) > 0 {
            segs.push(parts[i]);
        }
        i = i + 1;
    }
    if len(segs) < 3 {
        raise format("cannot parse git url: %s", url);
    }
    let n = len(segs);
    return (segs[n - 3], segs[n - 2], segs[n - 1]);
}
