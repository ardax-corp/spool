// Semver tag matching for spool (MAJOR.MINOR.PATCH, optional v prefix).
// Ranges: caret (^), comparison (>= > <= < =), exact, or *.
use text::{starts_with, split, trim, slice, contains, find};
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

fn rest_after(string s, string prefix) -> string {
    if starts_with(s, prefix) == false {
        return s;
    }
    let rest = match slice(s, len(prefix), len(s)) {
        Result::Ok(r) => r,
        Result::Err(_) => {
            return s;
        },
    };
    return match trim(rest) {
        Result::Ok(t) => t,
        Result::Err(_) => rest,
    };
}

/// Cut a `-prerelease` / `+build` suffix (`1.2.3-rc.1` → `1.2.3`).
fn strip_pre(string s) -> string {
    let cut = len(s);
    let dash = find(s, "-");
    if dash >= 0 && dash < cut {
        cut = dash;
    }
    let plus = find(s, "+");
    if plus >= 0 && plus < cut {
        cut = plus;
    }
    if cut == len(s) {
        return s;
    }
    return match slice(s, 0, cut) {
        Result::Ok(x) => x,
        Result::Err(_) => s,
    };
}

fn is_prerelease(string raw) -> bool {
    return contains(strip_v(raw), "-");
}

fn parse_semver(string raw) -> Result<SemVer, string> {
    let s = strip_pre(strip_v(raw));
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

fn satisfies_caret_base(SemVer base, SemVer version) -> bool {
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

fn component_count(string raw) -> int {
    let parts = match split(strip_pre(strip_v(raw)), ".") {
        Result::Ok(p) => p,
        Result::Err(_) => {
            return 0;
        },
    };
    return len(parts);
}

/// `~1.2.3` / `~1.2` → same major.minor; `~1` → same major.
fn satisfies_tilde(string raw, SemVer version) -> Result<bool, string> {
    let base = parse_semver(raw)?;
    if cmp_semver(version, base) < 0 {
        return false;
    }
    let n = component_count(raw);
    match base {
        SemVer::Ver(bm, bn, bp) => {
            let base_maj = bm;
            let base_min = bn;
            match version {
                SemVer::Ver(vm, vn, vp) => {
                    let vmaj = vm;
                    let vmin = vn;
                    if n <= 1 {
                        return vmaj == base_maj;
                    }
                    return vmaj == base_maj && vmin == base_min;
                },
            };
        },
    };
}

fn satisfies_range(string requirement, SemVer version) -> Result<bool, string> {
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
    if contains(req, ",") {
        let parts = match split(req, ",") {
            Result::Ok(p) => p,
            Result::Err(_) => raise format("bad requirement %s", req),
        };
        let i = 0;
        while i < len(parts) {
            let ok = satisfies_range(parts[i], version)?;
            if ok == false {
                return false;
            }
            i = i + 1;
        }
        return true;
    }
    if starts_with(req, "~") {
        return satisfies_tilde(rest_after(req, "~"), version)?;
    }
    if starts_with(req, "^") {
        let base = parse_semver(strip_caret(req))?;
        return satisfies_caret_base(base, version);
    }
    if starts_with(req, ">=") {
        let base = parse_semver(rest_after(req, ">="))?;
        if cmp_semver(version, base) < 0 {
            return false;
        }
        return true;
    }
    if starts_with(req, "<=") {
        let base = parse_semver(rest_after(req, "<="))?;
        if cmp_semver(version, base) > 0 {
            return false;
        }
        return true;
    }
    if starts_with(req, ">") {
        let base = parse_semver(rest_after(req, ">"))?;
        return cmp_semver(version, base) > 0;
    }
    if starts_with(req, "<") {
        let base = parse_semver(rest_after(req, "<"))?;
        return cmp_semver(version, base) < 0;
    }
    if starts_with(req, "=") {
        let exact = parse_semver(rest_after(req, "="))?;
        return cmp_semver(exact, version) == 0;
    }
    let exact = parse_semver(req)?;
    return cmp_semver(exact, version) == 0;
}

fn satisfies_caret(string requirement, SemVer version) -> Result<bool, string> {
    return satisfies_range(requirement, version)?;
}

fn select_tag(string requirement, Vec<string> tags) -> Result<string, string> {
    let best_tag = "";
    let has_best = false;
    let best = SemVer::Ver(0, 0, 0);
    let i = 0;
    while i < len(tags) {
        let tag = tags[i];
        i = i + 1;
        if is_prerelease(tag) {
            continue;
        }
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
        if is_prerelease(tag) {
            continue;
        }
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
