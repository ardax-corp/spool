// stdout / stderr writes that end the process when the reader is gone.
// io::sync's println/eprintln retry every write error as WouldBlock (coil
// matches the first `IoError::` arm for any error, ardax-corp/coil-lang#579),
// so a closed pipe (`spool tree | head`) would spin them forever.
use io::{stdout, stderr, write_from, await_writable};
use env::{exit};
use string::{to_bytes};

/// Write all of `text` to `s`. A write that still fails after waiting for
/// the stream means nobody is reading: exit 1. The error kind is not
/// inspected (see above).
fn write_text(Stream s, string text) -> int {
    let buf = to_bytes(text);
    let off = 0;
    let fails = 0;
    while off < len(buf) {
        let n = match write_from(s, buf, off) {
            Result::Ok(k) => k,
            Result::Err(_) => 0,
        };
        if n > 0 {
            off = off + n;
            fails = 0;
            continue;
        }
        fails = fails + 1;
        if fails > 2 {
            exit(1);
        }
        match await_writable(s) {
            Result::Ok(_) => 0,
            Result::Err(_) => 0,
        };
    }
    return 0;
}

/// `text` on stdout, no newline.
fn print(string text) -> int {
    return write_text(stdout(), text);
}

fn println(string text) -> int {
    return write_text(stdout(), text + "\n");
}

fn eprintln(string text) -> int {
    return write_text(stderr(), text + "\n");
}
