// Child processes. Values never enter a shell script: every script here is a
// constant and data is passed as positional arguments ("$1", "$2", …).
use env::{exec};
use io::file::{read_text};
use io::fs::{remove_file};
use clock::{wall_nanos};
use string::{format};
use text::{split};
use util::{join2, ensure_dir, home_dir, trim_or};

fn spawn(string program, Vec<string> argv) -> Result<int, string> {
    return match exec(program, argv) {
        Result::Ok(code) => code,
        Result::Err(_) => raise format("failed to start %s", program),
    };
}

/// `sh -c <script> spool <args…>` — args are "$1".."$n" inside the script.
fn sh_run(string script, Vec<string> args) -> Result<int, string> {
    let argv: Vec<string> = Vec::new();
    argv.push("-c");
    argv.push(script);
    argv.push("spool");
    let i = 0;
    while i < len(args) {
        argv.push(args[i]);
        i = i + 1;
    }
    return spawn("sh", argv)?;
}

/// Run `program args…` with cwd `dir`; returns the exit code.
fn run_in(string dir, string program, Vec<string> args) -> Result<int, string> {
    let a: Vec<string> = Vec::new();
    a.push(dir);
    a.push(program);
    let i = 0;
    while i < len(args) {
        a.push(args[i]);
        i = i + 1;
    }
    return sh_run("cd \"$1\" || exit 125; shift; exec \"$@\"", a)?;
}

fn scratch_file(string tag) -> Result<string, string> {
    let base = "";
    match home_dir() {
        Result::Ok(h) => {
            base = join2(h, ".cache/spool/tmp");
        },
        Result::Err(_) => {
            base = "/tmp/spool";
        },
    };
    ensure_dir(base)?;
    return join2(base, format("%s-%i", tag, wall_nanos()));
}

/// Run a constant script with positional args and capture its stdout.
/// Returns (exit code, stdout). stderr is inherited.
fn sh_capture(string script, Vec<string> args) -> Result<(int, string), string> {
    let out = scratch_file("out")?;
    let a: Vec<string> = Vec::new();
    a.push(out);
    a.push(script);
    let i = 0;
    while i < len(args) {
        a.push(args[i]);
        i = i + 1;
    }
    let code = sh_run("o=\"$1\"; s=\"$2\"; shift 2; sh -c \"$s\" spool \"$@\" > \"$o\"", a)?;
    let body = match read_text(out) {
        Result::Ok(s) => s,
        Result::Err(_) => "",
    };
    match remove_file(out) {
        Result::Ok(_) => 0,
        Result::Err(_) => 0,
    };
    return (code, body);
}

/// Like sh_capture but a non-zero exit is an error carrying `what`.
fn sh_output(string script, Vec<string> args, string what) -> Result<string, string> {
    let res = sh_capture(script, args)?;
    let (code, body) = res;
    if code != 0 {
        raise format("%s (exit %i)", what, code);
    }
    return body;
}

fn first_line(string s) -> string {
    let parts = match split(s, "\n") {
        Result::Ok(v) => v,
        Result::Err(_) => {
            return trim_or(s);
        },
    };
    if len(parts) == 0 {
        return "";
    }
    return trim_or(parts[0]);
}

/// Absolute path of `program` on PATH, or "".
fn which(string program) -> string {
    let a: Vec<string> = Vec::new();
    a.push(program);
    return match sh_capture("command -v \"$1\" 2>/dev/null", a) {
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
