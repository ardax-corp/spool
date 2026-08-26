use resolve::{parse_coil_version_output, enforce_engine};
use text::{contains};

test("parse_coil_version_output reads coil --version") {
    assert(parse_coil_version_output("coil 0.1.0")? == "0.1.0")?;
    assert(parse_coil_version_output("coil 0.1.0\n")? == "0.1.0")?;
}

test("enforce_engine omitted range is a no-op") {
    let n = enforce_engine("app", "", "0.1.0")?;
    assert(n == 0)?;
}

test("enforce_engine accepts in-range") {
    let n = enforce_engine("app", ">=0.1.0", "0.1.0")?;
    assert(n == 0)?;
    n = enforce_engine("app", "^0.1", "0.1.0")?;
    assert(n == 0)?;
    n = enforce_engine("app", "*", "0.1.0")?;
    assert(n == 0)?;
}

test("enforce_engine refuses too-old toolchain") {
    let r = enforce_engine("http", ">=99.0.0", "0.1.0");
    match r {
        Result::Ok(_) => {
            assert(false)?;
        },
        Result::Err(e) => {
            assert(contains(e, "http"))?;
            assert(contains(e, ">=99.0.0"))?;
            assert(contains(e, "0.1.0"))?;
        },
    };
}
