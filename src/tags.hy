// Parse `git ls-remote --tags` output (prefer peeled annotated-tag SHAs).
use text::{trim, starts_with, split, contains, ends_with, split_once, find};
use string::{format};

fn ls_field(string row, int idx) -> string {
    let parts = match split(row, "\t") {
        Result::Ok(v) => v,
        Result::Err(_) => {
            let empty: Vec<string> = Vec::new();
            empty
        },
    };
    if idx < len(parts) {
        return parts[idx];
    }
    return "";
}

fn split_sha_ref(string line) -> Result<(string, string), string> {
    if contains(line, "\t") {
        return split_once(line, "\t")?;
    }
    if find(line, " ") < 0 {
        raise "expected sha and ref";
    }
    let pair = split_once(line, " ")?;
    let (sha, rest) = pair;
    let refname = match trim(rest) {
        Result::Ok(t) => t,
        Result::Err(_) => rest,
    };
    return (sha, refname);
}

fn parse_tag_ref(string refname) -> Result<(string, bool), string> {
    let r = match trim(refname) {
        Result::Ok(t) => t,
        Result::Err(_) => refname,
    };
    if starts_with(r, "refs/tags/") == false {
        raise "not a tag ref";
    }
    let rest = match split_once(r, "refs/tags/") {
        Result::Ok(p) => {
            let (l, rr) = p;
            rr
        },
        Result::Err(_) => raise "not a tag ref",
    };
    if ends_with(rest, "^{}") {
        let tag = match split_once(rest, "^{}") {
            Result::Ok(p) => {
                let (l, rr) = p;
                l
            },
            Result::Err(_) => rest,
        };
        return (tag, true);
    }
    return (rest, false);
}

fn upsert_tag_sha(Vec<string> rows, string tag, string sha, bool peeled) -> Vec<string> {
    let i = 0;
    while i < len(rows) {
        if ls_field(rows[i], 0) == tag {
            if peeled {
                rows[i] = tag + "\t" + sha;
            }
            return rows;
        }
        i = i + 1;
    }
    rows.push(tag + "\t" + sha);
    return rows;
}

fn parse_ls_remote(string body) -> Result<Vec<string>, string> {
    let lines = match split(body, "\n") {
        Result::Ok(ls) => ls,
        Result::Err(_) => raise "split ls-remote failed",
    };
    let rows: Vec<string> = Vec::new();
    let i = 0;
    while i < len(lines) {
        let line = match trim(lines[i]) {
            Result::Ok(t) => t,
            Result::Err(_) => lines[i],
        };
        i = i + 1;
        if len(line) == 0 {
            continue;
        }
        let pair = split_sha_ref(line)?;
        let (sha, refname) = pair;
        let parsed = parse_tag_ref(refname);
        match parsed {
            Result::Ok(tr) => {
                let (tag, peeled) = tr;
                rows = upsert_tag_sha(rows, tag, sha, peeled);
            },
            Result::Err(_) => {},
        };
    }
    return rows;
}

fn ls_remote_tag_names(Vec<string> rows) -> Vec<string> {
    let out: Vec<string> = Vec::new();
    let i = 0;
    while i < len(rows) {
        out.push(ls_field(rows[i], 0));
        i = i + 1;
    }
    return out;
}

fn ls_remote_sha(Vec<string> rows, string tag) -> Result<string, string> {
    let i = 0;
    while i < len(rows) {
        if ls_field(rows[i], 0) == tag {
            return ls_field(rows[i], 1);
        }
        i = i + 1;
    }
    raise format("no sha for tag %s", tag);
}
