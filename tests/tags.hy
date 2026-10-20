use tests::assert;
use tags::{parse_ls_remote, ls_remote_tag_names, ls_remote_sha, ls_remote_head_sha};

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
