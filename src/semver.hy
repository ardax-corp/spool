// Semver tag matching for spool (MAJOR.MINOR.PATCH, optional v prefix).
use text::{starts_with, split, trim};
use conv::{parse_int};
use string::{format};

enum SemVer {
    Ver(int, int, int),
}

fn strip_v(string raw) -> string {
    let s = match trim(raw) {
        Result::Ok(t) => t,
        Result::Err(_) => raw,
    };
    if starts_with(s, "v") == false {
        return s;
    }
    if len(s) <= 1 {
        return s;
    }
    let parts = match split(s, "v") {
        Result::Ok(p) => p,
        Result::Err(_) => {
            let empty: Vec<string> = Vec::new();
            empty
        },
    };
    if len(parts) >= 2 {
        return parts[1];
    }
    return s;
}

fn strip_caret(string req) -> string {
    if starts_with(req, "^") == false {
        return req;
    }
    if len(req) <= 1 {
        return req;
    }
    let parts = match split(req, "^") {
        Result::Ok(p) => p,
        Result::Err(_) => {
            let empty: Vec<string> = Vec::new();
            empty
        },
    };
    if len(parts) >= 2 {
        return parts[1];
    }
    return req;
}

fn parse_semver(string raw) -> Result<SemVer, string> {
    let s = strip_v(raw);
    let parts = match split(s, ".") {
        Result::Ok(p) => p,
        Result::Err(_) => raise "bad semver",
    };
    if len(parts) < 1 {
        raise "bad semver";
    }
    let major = parse_int(parts[0])?;
    let minor = 0;
    let patch = 0;
    if len(parts) > 1 {
        minor = parse_int(parts[1])?;
    }
    if len(parts) > 2 {
        patch = parse_int(parts[2])?;
    }
    return SemVer::Ver(major, minor, patch);
}

fn cmp_semver(SemVer a, SemVer b) -> int {
    match a {
        SemVer::Ver(a0, a1, a2) => {
            let x0 = a0;
            let x1 = a1;
            let x2 = a2;
            match b {
                SemVer::Ver(b0, b1, b2) => {
                    let y0 = b0;
                    let y1 = b1;
                    let y2 = b2;
                    if x0 != y0 {
                        if x0 < y0 {
                            return 0 - 1;
                        }
                        return 1;
                    }
                    if x1 != y1 {
                        if x1 < y1 {
                            return 0 - 1;
                        }
                        return 1;
                    }
                    if x2 != y2 {
                        if x2 < y2 {
                            return 0 - 1;
                        }
                        return 1;
                    }
                    return 0;
                },
            };
        },
    };
}

fn satisfies_caret(string requirement, SemVer version) -> Result<bool, string> {
    let req = match trim(requirement) {
        Result::Ok(t) => t,
        Result::Err(_) => requirement,
    };
    if req == "*" {
        return true;
    }
    if len(req) == 0 {
        return true;
    }
    if starts_with(req, "^") == false {
        let exact = parse_semver(req)?;
        return cmp_semver(exact, version) == 0;
    }
    let base = parse_semver(strip_caret(req))?;
    match base {
        SemVer::Ver(maj, min, pat) => {
            let base_maj = maj;
            let base_min = min;
            let base_pat = pat;
            if cmp_semver(version, base) < 0 {
                return false;
            }
            match version {
                SemVer::Ver(vm, vn, vp) => {
                    let vmaj = vm;
                    let vmin = vn;
                    let vpat = vp;
                    if base_maj > 0 {
                        return vmaj == base_maj;
                    }
                    if base_min > 0 {
                        return vmaj == 0 && vmin == base_min;
                    }
                    return vmaj == 0 && vmin == 0 && vpat == base_pat;
                },
            };
        },
    };
}

fn select_tag(string requirement, Vec<string> tags) -> Result<string, string> {
    let best_tag = "";
    let has_best = false;
    let best = SemVer::Ver(0, 0, 0);
    let i = 0;
    while i < len(tags) {
        let tag = tags[i];
        i = i + 1;
        let parsed = parse_semver(tag);
        match parsed {
            Result::Ok(ver) => {
                let ok = satisfies_caret(requirement, ver)?;
                if ok {
                    if has_best == false {
                        has_best = true;
                        best = ver;
                        best_tag = tag;
                    } else {
                        if cmp_semver(ver, best) > 0 {
                            best = ver;
                            best_tag = tag;
                        }
                    }
                }
            },
            Result::Err(_) => {
            },
        };
    }
    if has_best == false {
        raise format("no tag matches requirement %s", requirement);
    }
    return best_tag;
}

fn tag_satisfies_all(string tag, Vec<string> reqs) -> Result<bool, string> {
    let ver = parse_semver(tag)?;
    let i = 0;
    while i < len(reqs) {
        let ok = satisfies_caret(reqs[i], ver)?;
        if ok == false {
            return false;
        }
        i = i + 1;
    }
    return true;
}

fn select_tag_all(Vec<string> reqs, Vec<string> tags) -> Result<string, string> {
    if len(reqs) == 0 {
        raise "no version requirements";
    }
    let best_tag = "";
    let has_best = false;
    let best = SemVer::Ver(0, 0, 0);
    let i = 0;
    while i < len(tags) {
        let tag = tags[i];
        i = i + 1;
        let parsed = parse_semver(tag);
        match parsed {
            Result::Ok(ver) => {
                let ok = tag_satisfies_all(tag, reqs)?;
                if ok {
                    if has_best == false {
                        has_best = true;
                        best = ver;
                        best_tag = tag;
                    } else {
                        if cmp_semver(ver, best) > 0 {
                            best = ver;
                            best_tag = tag;
                        }
                    }
                }
            },
            Result::Err(_) => {
            },
        };
    }
    if has_best == false {
        raise "no tag matches combined requirements";
    }
    return best_tag;
}
