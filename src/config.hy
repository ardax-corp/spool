// Resolve shared cache root and global config.
// Helpers first — coil has no forward references within a module.
use env::var;
use io::fs::exists;
use io::file::read_text;
use text::{Searchable, Text};
use util::{home_dir, join2};

fn trim_str(string s) -> string {
    return s.trim();
}

fn strip_quotes(string s) -> string {
    if s.len() < 2 {
        return s;
    }
    if s.starts_with("\"") == false {
        return s;
    }
    if s.ends_with("\"") == false {
        return s;
    }
    return match s.slice(1, s.len() - 1) {
        Result::Ok(inner) => inner,
        Result::Err(_) => s,
    };
}

fn config_path() -> Result<string, string> {
    match var("XDG_CONFIG_HOME") {
        Result::Ok(xdg) => {
            let t = trim_str(xdg);
            if t.len() > 0 {
                return join2(t, "coil/config.toml");
            }
        },
        Result::Err(_) => 0,
    }
    let home = home_dir()?;
    return join2(home, ".config/coil/config.toml");
}

/// Minimal parse of `[cache] dir = "…"`.
fn read_cache_dir_from_config() -> Result<string, string> {
    let path = config_path()?;
    let present = match exists(path) {
        Result::Ok(v) => v,
        Result::Err(_) => false,
    };
    if present == false {
        raise "no config";
    }
    let body = match read_text(path) {
        Result::Ok(s) => s,
        Result::Err(_) => raise "read config failed",
    };
    let lines = body.split("\n");
    let in_cache = false;
    let i = 0;
    while i < lines.len() {
        let line = trim_str(lines[i]);
        i = i + 1;
        if line.len() == 0 {
            continue;
        }
        if line.starts_with("#") {
            continue;
        }
        if line == "[cache]" {
            in_cache = true;
            continue;
        }
        if line.starts_with("[") {
            in_cache = false;
            continue;
        }
        if in_cache {
            if line.starts_with("dir") {
                if line.contains("=") {
                    let parts = line.split("=");
                    if parts.len() >= 2 {
                        return strip_quotes(trim_str(parts[1]));
                    }
                }
            }
        }
    }
    raise "cache.dir not set";
}

/// Cache root: config.toml `[cache].dir` > `$XDG_CACHE_HOME/coil` >
/// `~/.cache/coil`.
fn cache_root() -> Result<string, string> {
    match read_cache_dir_from_config() {
        Result::Ok(p) => {
            return p;
        },
        Result::Err(_) => 0,
    }

    match var("XDG_CACHE_HOME") {
        Result::Ok(xdg) => {
            let t = trim_str(xdg);
            if t.len() > 0 {
                return join2(t, "coil");
            }
        },
        Result::Err(_) => 0,
    }

    let home = home_dir()?;
    return join2(home, ".cache/coil");
}
