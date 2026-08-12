// Path helpers shared by roots/cache/config (no env::exec).
use io::fs::{exists, create_dir_all};
use io::file::{write_text};
use env::{var};
use string::{format};
use path::{join as path_join};

fn join2(string a, string b) -> string {
    return match path_join(a, b) {
        Result::Ok(p) => p,
        Result::Err(_) => a + "/" + b,
    };
}

fn join3(string a, string b, string c) -> string {
    return join2(join2(a, b), c);
}

fn join4(string a, string b, string c, string d) -> string {
    return join2(join3(a, b, c), d);
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

fn write_status(string root, string msg) -> Result<int, string> {
    ensure_dir(join2(root, ".spool"))?;
    return match write_text(join2(root, ".spool/status"), msg) {
        Result::Ok(_) => 0,
        Result::Err(_) => raise "write status failed",
    };
}
