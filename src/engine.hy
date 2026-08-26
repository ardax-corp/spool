// Coil engine-range check helpers (no filesystem, no path).
use text::{trim, starts_with, slice, split};
use semver::{parse_semver, satisfies_range};

fn parse_coil_version_output(string raw) -> Result<string, string> {
    let s = match trim(raw) {
        Result::Ok(t) => t,
        Result::Err(_) => raw,
    };
    if starts_with(s, "coil") == false {
        raise "unrecognized coil --version output";
    }
    let rest = match slice(s, 4, len(s)) {
        Result::Ok(r) => r,
        Result::Err(_) => raise "unrecognized coil --version output",
    };
    rest = match trim(rest) {
        Result::Ok(t) => t,
        Result::Err(_) => rest,
    };
    if len(rest) == 0 {
        raise "unrecognized coil --version output";
    }
    let parts = match split(rest, " ") {
        Result::Ok(p) => p,
        Result::Err(_) => raise "unrecognized coil --version output",
    };
    if len(parts) < 1 {
        raise "unrecognized coil --version output";
    }
    if len(parts[0]) == 0 {
        raise "unrecognized coil --version output";
    }
    return parts[0];
}

fn enforce_engine(string pkg, string range, string running) -> Result<int, string> {
    let req = match trim(range) {
        Result::Ok(t) => t,
        Result::Err(_) => range,
    };
    if len(req) == 0 {
        return 0;
    }
    let label = running;
    if len(label) == 0 {
        label = "unknown";
    }
    let msg = "package " + pkg + " requires coil " + req + ", running " + label;
    if len(running) == 0 {
        raise msg;
    }
    let ver_res = parse_semver(running);
    match ver_res {
        Result::Ok(ver) => {
            let ok_res = satisfies_range(req, ver);
            match ok_res {
                Result::Ok(ok) => {
                    if ok == false {
                        raise msg;
                    }
                    return 0;
                },
                Result::Err(_) => {
                    raise msg;
                },
            };
        },
        Result::Err(_) => {
            raise msg;
        },
    };
}
