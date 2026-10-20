use tests::assert;
use resolve::{make_con, pin_of, locked_ok, latest_ref};
use lock::{make_git_pkg, make_git_pkg_ref};
use text::{contains};

fn one(string a) -> Vec<string> {
    let v: Vec<string> = Vec::new();
    v.push(a);
    return v;
}

fn two(string a, string b) -> Vec<string> {
    let v = one(a);
    v.push(b);
    return v;
}

fn pin_err(Vec<string> reqs, Vec<string> cons) -> string {
    return match pin_of("c", reqs, cons) {
        Result::Ok(p) => "ok:" + p,
        Result::Err(e) => e,
    };
}

test("latest resolves through the HEAD pin (#32)") {
    assert!(latest_ref() == "HEAD");
    let cons = one(make_con("c", "https://x/c.git", "latest", "app"));
    assert!(pin_of("c", one("latest"), cons)? == "HEAD");
}

test("latest from two requesters agrees (#32)") {
    let cons = two(
        make_con("c", "https://x/c.git", "latest", "a"),
        make_con("c", "https://x/c.git", "latest", "b"),
    );
    assert!(pin_of("c", one("latest"), cons)? == "HEAD");
}

test("latest combined with a range is a diamond conflict (#32)") {
    let cons = two(
        make_con("c", "https://x/c.git", "latest", "a"),
        make_con("c", "https://x/c.git", "^1.0", "b"),
    );
    let e = pin_err(two("latest", "^1.0"), cons);
    assert!(contains(e, "diamond conflict for c"));
    assert!(contains(e, "a requires latest"));
    assert!(contains(e, "b requires ^1.0"));
    // Order does not matter.
    let e2 = pin_err(two("^1.0", "latest"), cons);
    assert!(contains(e2, "diamond conflict for c"));
}

test("latest combined with a branch pin is a diamond conflict (#32)") {
    let cons = two(
        make_con("c", "https://x/c.git", "latest", "a"),
        make_con("c", "https://x/c.git", "@main", "b"),
    );
    let e = pin_err(two("latest", "@main"), cons);
    assert!(contains(e, "diamond conflict for c"));
}

test("a ref = HEAD lock row satisfies latest until update (#32)") {
    let row = make_git_pkg_ref("c", "https://x/c.git", "", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "t1", "", "", "HEAD");
    assert!(locked_ok(row, "https://x/c.git", one("latest"), "HEAD"));
    // Another url, a tag lock, or a branch lock do not.
    assert!(locked_ok(row, "https://y/c.git", one("latest"), "HEAD") == false);
    let tagged = make_git_pkg("c", "https://x/c.git", "v1.0.0", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "t2");
    assert!(locked_ok(tagged, "https://x/c.git", one("latest"), "HEAD") == false);
    let branch = make_git_pkg_ref("c", "https://x/c.git", "", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "t1", "", "", "main");
    assert!(locked_ok(branch, "https://x/c.git", one("latest"), "HEAD") == false);
    // A latest lock row does not satisfy a range.
    assert!(locked_ok(row, "https://x/c.git", one("^1.0"), "") == false);
}
