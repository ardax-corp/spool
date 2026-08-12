use tags::{parse_ls_remote, ls_remote_tag_names, ls_remote_sha};

test("parse_ls_remote prefers peeled annotated tag") {
    let body = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa	refs/tags/v1.0.0
bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb	refs/tags/v1.0.0^{}
cccccccccccccccccccccccccccccccccccccccc	refs/tags/v1.1.0
";
    let rows = parse_ls_remote(body)?;
    assert(len(rows) == 2)?;
    let names = ls_remote_tag_names(rows);
    assert(names[0] == "v1.0.0")?;
    assert(ls_remote_sha(rows, "v1.0.0")? == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")?;
    assert(ls_remote_sha(rows, "v1.1.0")? == "cccccccccccccccccccccccccccccccccccccccc")?;
}

test("parse_ls_remote accepts space-separated lines") {
    let body = "dddddddddddddddddddddddddddddddddddddddd refs/tags/v0.1.0
";
    let rows = parse_ls_remote(body)?;
    assert(len(rows) == 1)?;
    assert(ls_remote_sha(rows, "v0.1.0")? == "dddddddddddddddddddddddddddddddddddddddd")?;
}
