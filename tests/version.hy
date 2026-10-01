use version::{spool_version};
use manifest::{package_version_parse};
use io::file::{read_text};

test("spool_version matches coil.toml") {
    let body = match read_text("coil.toml") {
        Result::Ok(s) => s,
        Result::Err(_) => "",
    };
    assert(package_version_parse(body) == spool_version())?;
}
