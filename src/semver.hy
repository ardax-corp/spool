// Semver tag matching for spool (MAJOR.MINOR.PATCH, optional v prefix).
// Ranges: caret (^), comparison (>= > <= < =), exact, or *.
use text::{Searchable, Text};
use conv::parse_int;
use string::format;

enum SemVer {
    Ver(int, int, int),
}

fn strip_v(string raw) -> string {
    let s = raw.trim();
    if s.starts_with("v") == false {
        return s;
    }
    if s.len() <= 1 {
        return s;
    }
    let parts = s.split("v");
    if parts.len() >= 2 {
        return parts[1];
    }
    return s;
}

fn strip_caret(string req) -> string {
    if req.starts_with("^") == false {
        return req;
    }
    if req.len() <= 1 {
        return req;
    }
    let parts = req.split("^");
    if parts.len() >= 2 {
        return parts[1];
    }
    return req;
}

fn rest_after(string s, string prefix) -> string {
    if s.starts_with(prefix) == false {
        return s;
    }
    let rest = match s.slice(prefix.len(), s.len()) {
        Result::Ok(r) => r,
        Result::Err(_) => {
            return s;
        },
    };
    return rest.trim();
}

/// Cut a `-prerelease` / `+build` suffix (`1.2.3-rc.1` → `1.2.3`).
fn strip_pre(string s) -> string {
    let cut = s.len();
    let dash = match s.find("-") {
        Option::Some(sp) => sp.start,
        Option::None => -1,
    };
    if dash >= 0 && dash < cut {
        cut = dash;
    }
    let plus = match s.find("+") {
        Option::Some(sp) => sp.start,
        Option::None => -1,
    };
    if plus >= 0 && plus < cut {
        cut = plus;
    }
    if cut == s.len() {
        return s;
    }
    return match s.slice(0, cut) {
        Result::Ok(x) => x,
        Result::Err(_) => s,
    };
}

fn is_prerelease(string raw) -> bool {
    return strip_v(raw).contains("-");
}

fn parse_semver(string raw) -> Result<SemVer, string> {
    let s = strip_pre(strip_v(raw));
    let parts = s.split(".");
    if parts.len() < 1 {
        raise "bad semver";
    }
    let major = parse_int(parts[0])?;
    let minor = 0;
    let patch = 0;
    if parts.len() > 1 {
        minor = parse_int(parts[1])?;
    }
    if parts.len() > 2 {
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
            }
        },
    }
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
            }
        },
    }
}

fn component_count(string raw) -> int {
    let parts = strip_pre(strip_v(raw)).split(".");
    return parts.len();
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
            }
        },
    }
}

fn satisfies_range(string requirement, SemVer version) -> Result<bool, string> {
    let req = requirement.trim();
    if req == "*" {
        return true;
    }
    if req.len() == 0 {
        return true;
    }
    if req.contains(",") {
        let parts = req.split(",");
        let i = 0;
        while i < parts.len() {
            let ok = satisfies_range(parts[i], version)?;
            if ok == false {
                return false;
            }
            i = i + 1;
        }
        return true;
    }
    if req.starts_with("~") {
        return satisfies_tilde(rest_after(req, "~"), version)?;
    }
    if req.starts_with("^") {
        let base = parse_semver(strip_caret(req))?;
        return satisfies_caret_base(base, version);
    }
    if req.starts_with(">=") {
        let base = parse_semver(rest_after(req, ">="))?;
        if cmp_semver(version, base) < 0 {
            return false;
        }
        return true;
    }
    if req.starts_with("<=") {
        let base = parse_semver(rest_after(req, "<="))?;
        if cmp_semver(version, base) > 0 {
            return false;
        }
        return true;
    }
    if req.starts_with(">") {
        let base = parse_semver(rest_after(req, ">"))?;
        return cmp_semver(version, base) > 0;
    }
    if req.starts_with("<") {
        let base = parse_semver(rest_after(req, "<"))?;
        return cmp_semver(version, base) < 0;
    }
    if req.starts_with("=") {
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
    while i < tags.len() {
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
            Result::Err(_) => {},
        }
    }
    if has_best == false {
        raise format("no tag matches requirement %s", requirement);
    }
    return best_tag;
}

fn tag_satisfies_all(string tag, Vec<string> reqs) -> Result<bool, string> {
    let ver = parse_semver(tag)?;
    let i = 0;
    while i < reqs.len() {
        let ok = satisfies_caret(reqs[i], ver)?;
        if ok == false {
            return false;
        }
        i = i + 1;
    }
    return true;
}

fn select_tag_all(Vec<string> reqs, Vec<string> tags) -> Result<string, string> {
    if reqs.len() == 0 {
        raise "no version requirements";
    }
    let best_tag = "";
    let has_best = false;
    let best = SemVer::Ver(0, 0, 0);
    let i = 0;
    while i < tags.len() {
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
            Result::Err(_) => {},
        }
    }
    if has_best == false {
        raise "no tag matches combined requirements";
    }
    return best_tag;
}

/// Does any tag parse as a version (pre-releases included)? A bare
/// `spool add` falls back to `latest` only when none does (#32).
fn has_version_tag(Vec<string> tags) -> bool {
    let i = 0;
    while i < tags.len() {
        let ok = match parse_semver(tags[i]) {
            Result::Ok(_) => true,
            Result::Err(_) => false,
        };
        if ok {
            return true;
        }
        i = i + 1;
    }
    return false;
}
