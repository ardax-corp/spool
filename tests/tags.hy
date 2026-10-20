use tests::assert;
use tags::{parse_ls_remote, ls_remote_tag_names, ls_remote_sha, ls_remote_head_sha, ls_remote_ref_sha};

test("parse_ls_remote prefers peeled annotated tag") {
    let body = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa	refs/tags/v1.0.0
bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb	refs/tags/v1.0.0^{}
cccccccccccccccccccccccccccccccccccccccc	refs/tags/v1.1.0
";
    let rows = parse_ls_remote(body)?;
    assert!(rows.len() == 2);
    let names = ls_remote_tag_names(rows);
    assert!(names[0] == "v1.0.0");
    assert!(ls_remote_sha(rows, "v1.0.0")? == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    assert!(ls_remote_sha(rows, "v1.1.0")? == "cccccccccccccccccccccccccccccccccccccccc");
}

test("parse_ls_remote accepts space-separated lines") {
    let body = "dddddddddddddddddddddddddddddddddddddddd refs/tags/v0.1.0
";
    let rows = parse_ls_remote(body)?;
    assert!(rows.len() == 1);
    assert!(ls_remote_sha(rows, "v0.1.0")? == "dddddddddddddddddddddddddddddddddddddddd");
}

test("ls_remote_head_sha reads the HEAD line only (#32)") {
    let body = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee	HEAD
ffffffffffffffffffffffffffffffffffffffff	refs/heads/feature/HEAD
";
    assert!(ls_remote_head_sha(body)? == "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee");
    let only_other = "ffffffffffffffffffffffffffffffffffffffff	refs/heads/feature/HEAD
";
    let missing = match ls_remote_head_sha(only_other) {
        Result::Ok(_) => false,
        Result::Err(_) => true,
    };
    assert!(missing);
    let empty = match ls_remote_head_sha("") {
        Result::Ok(_) => false,
        Result::Err(_) => true,
    };
    assert!(empty);
}

fn ref_missing(string body, string rev) -> bool {
    return match ls_remote_ref_sha(body, rev) {
        Result::Ok(_) => false,
        Result::Err(_) => true,
    };
}

test("ls_remote_ref_sha matches HEAD exactly, not refs ending in /HEAD (#41)") {
    let body = "1111111111111111111111111111111111111111	refs/remotes/origin/HEAD
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee	HEAD
";
    assert!(ls_remote_ref_sha(body, "HEAD")? == "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee");
    assert!(ref_missing("1111111111111111111111111111111111111111	refs/remotes/origin/HEAD\n", "HEAD"));
}

test("ls_remote_ref_sha matches a branch exactly, not a longer ref ending in it (#41)") {
    let body = "1111111111111111111111111111111111111111	refs/heads/feature/main
2222222222222222222222222222222222222222	refs/heads/main
3333333333333333333333333333333333333333	refs/remotes/origin/main
";
    assert!(ls_remote_ref_sha(body, "main")? == "2222222222222222222222222222222222222222");
    assert!(ls_remote_ref_sha(body, "refs/heads/main")? == "2222222222222222222222222222222222222222");
    assert!(ref_missing("1111111111111111111111111111111111111111	refs/heads/feature/main\n", "main"));
}

test("ls_remote_ref_sha prefers the peeled commit of an annotated tag (#41)") {
    let body = "1111111111111111111111111111111111111111	refs/tags/old/v1.0^{}
2222222222222222222222222222222222222222	refs/tags/v1.0
3333333333333333333333333333333333333333	refs/tags/v1.0^{}
";
    assert!(ls_remote_ref_sha(body, "v1.0")? == "3333333333333333333333333333333333333333");
    let light = "2222222222222222222222222222222222222222	refs/tags/v1.0
";
    assert!(ls_remote_ref_sha(light, "v1.0")? == "2222222222222222222222222222222222222222");
}

test("ls_remote_ref_sha takes a branch over a lightweight tag of the same name (#41)") {
    let body = "2222222222222222222222222222222222222222	refs/heads/v1
3333333333333333333333333333333333333333	refs/tags/v1
";
    assert!(ls_remote_ref_sha(body, "v1")? == "2222222222222222222222222222222222222222");
    assert!(ref_missing("", "v1"));
}
