// Path helpers shared by roots/cache/config (no env::exec).
// String joins live here: stdlib `path` is a Path class and shadows join/dirname.
use io::fs::{exists, create_dir_all};
use io::file::{write_text};
use env::{var};
use string::{format};
use text::{starts_with, ends_with, slice, split};

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

fn git_sh_preamble() -> string {
    return "#!/bin/sh\nset -e\nexport GIT_TERMINAL_PROMPT=0\n";
}

fn write_status(string root, string msg) -> Result<int, string> {
    ensure_dir(join2(root, ".spool"))?;
    return match write_text(join2(root, ".spool/status"), msg) {
        Result::Ok(_) => 0,
        Result::Err(_) => raise "write status failed",
    };
}
