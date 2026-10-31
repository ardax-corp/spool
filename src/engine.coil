// Coil engine-range check helpers (no filesystem, no path).
use text::{Searchable, Text};
use semver::{parse_semver, satisfies_range};

fn parse_coil_version_output(string raw) -> Result<string, string> {
    let s = raw.trim();
    if s.starts_with("coil") == false {
        raise "unrecognized coil --version output";
    }
    let rest = match s.slice(4, s.len()) {
        Result::Ok(r) => r,
        Result::Err(_) => raise "unrecognized coil --version output",
    };
    rest = rest.trim();
    if rest.len() == 0 {
        raise "unrecognized coil --version output";
    }
    let parts = rest.split(" ");
    if parts.len() < 1 {
        raise "unrecognized coil --version output";
    }
    if parts[0].len() == 0 {
        raise "unrecognized coil --version output";
    }
    return parts[0];
}

fn enforce_engine(string pkg, string range, string running) -> Result<int, string> {
    let req = range.trim();
    if req.len() == 0 {
        return 0;
    }
    let label = running;
    if label.len() == 0 {
        label = "unknown";
    }
    let msg = "package " + pkg + " requires coil " + req + ", running " + label;
    if running.len() == 0 {
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
            }
        },
        Result::Err(_) => {
            raise msg;
        },
    }
}
