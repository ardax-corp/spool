use semver::{parse_semver, satisfies_caret, satisfies_range, select_tag, select_tag_all, cmp_semver, SemVer};

test("parse_semver accepts v prefix") {
    let a = parse_semver("v1.2.3")?;
    let b = parse_semver("1.2.3")?;
    assert(cmp_semver(a, b) == 0)?;
}

test("caret on 0.x stays within minor") {
    let v = parse_semver("0.2.5")?;
    assert(satisfies_caret("^0.2", v)?)?;
    assert(satisfies_caret("^0.2", parse_semver("0.3.0")?)? == false)?;
    assert(satisfies_caret("^0.2", parse_semver("0.1.0")?)? == false)?;
}

test("caret on 1.x stays within major") {
    let v = parse_semver("1.9.0")?;
    assert(satisfies_caret("^1.2.3", v)?)?;
    assert(satisfies_caret("^1.2.3", parse_semver("2.0.0")?)? == false)?;
}

test("select_tag picks highest matching") {
    let tags: Vec<string> = Vec::new();
    tags.push("v0.1.0");
    tags.push("v0.2.0");
    tags.push("v0.2.1");
    tags.push("v0.3.0");
    let got = select_tag("^0.2", tags)?;
    assert(got == "v0.2.1")?;
}

test("star matches any semver tag") {
    let v = parse_semver("2.0.0")?;
    assert(satisfies_caret("*", v)?)?;
    let tags: Vec<string> = Vec::new();
    tags.push("v0.1.0");
    tags.push("v2.0.0");
    let got = select_tag("*", tags)?;
    assert(got == "v2.0.0")?;
}

test("select_tag_all unifies compatible carets") {
    let tags: Vec<string> = Vec::new();
    tags.push("v1.0.0");
    tags.push("v1.2.0");
    tags.push("v1.5.0");
    tags.push("v2.0.0");
    let reqs: Vec<string> = Vec::new();
    reqs.push("^1.0");
    reqs.push("^1.2");
    let got = select_tag_all(reqs, tags)?;
    assert(got == "v1.5.0")?;
}

test("select_tag_all rejects incompatible carets") {
    let tags: Vec<string> = Vec::new();
    tags.push("v1.0.0");
    tags.push("v2.0.0");
    let reqs: Vec<string> = Vec::new();
    reqs.push("^1.0");
    reqs.push("^2.0");
    let r = select_tag_all(reqs, tags);
    match r {
        Result::Ok(_) => {
            assert(false)?;
        },
        Result::Err(_) => {
            assert(true)?;
        },
    };
}

test("comparison operators match git-dep range language") {
    let v = parse_semver("0.1.0")?;
    assert(satisfies_range(">=0.1.0", v)?)?;
    assert(satisfies_range(">=0.1", v)?)?;
    assert(satisfies_range(">0.0.9", v)?)?;
    assert(satisfies_range(">=0.2.0", v)? == false)?;
    assert(satisfies_range(">0.1.0", v)? == false)?;
    assert(satisfies_range("<=0.1.0", v)?)?;
    assert(satisfies_range("<0.1.1", v)?)?;
    assert(satisfies_range("<0.1.0", v)? == false)?;
    assert(satisfies_range("=0.1.0", v)?)?;
    assert(satisfies_range("=0.2.0", v)? == false)?;
}
