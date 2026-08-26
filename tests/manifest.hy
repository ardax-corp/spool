use manifest::{
    deps_parse, dep_kind, dep_name, dep_git, dep_version, dep_path, deps_insert_line,
    make_git_dep, format_dep_line, deps_has_name, package_name_parse, package_coil_parse,
};
use text::{contains};

test("parse git dependency inline table") {
    let body = "[dependencies]
http = { git = \"https://github.com/a/b.git\", version = \"^0.2\" }
";
    let deps = deps_parse(body)?;
    assert(len(deps) == 1)?;
    assert(dep_kind(deps[0]) == "g")?;
    assert(dep_name(deps[0]) == "http")?;
    assert(dep_git(deps[0]) == "https://github.com/a/b.git")?;
    assert(dep_version(deps[0]) == "^0.2")?;
}

test("parse path dependency") {
    let body = "[package]
name = \"app\"
version = \"0.1.0\"

[dependencies]
local_http = { path = \"../local-http\" }
";
    let deps = deps_parse(body)?;
    assert(len(deps) == 1)?;
    assert(dep_kind(deps[0]) == "p")?;
    assert(dep_name(deps[0]) == "local_http")?;
    assert(dep_path(deps[0]) == "../local-http")?;
}

test("insert creates dependencies section") {
    let body = "[package]
name = \"app\"
version = \"0.1.0\"
";
    let line = format_dep_line(make_git_dep("http", "https://x/y.git", "^1.0"))?;
    let out = deps_insert_line(body, line)?;
    assert(contains(out, "[dependencies]"))?;
    assert(contains(out, "http = { git = \"https://x/y.git\", version = \"^1.0\" }"))?;
}

test("deps_has_name finds existing") {
    let body = "[dependencies]
http = { git = \"https://x\", version = \"*\" }
";
    let deps = deps_parse(body)?;
    assert(deps_has_name(deps, "http"))?;
    assert(deps_has_name(deps, "missing") == false)?;
}

test("package_name_parse reads [package] name") {
    let body = "[package]
name = \"app\"
version = \"0.1.0\"
";
    assert(package_name_parse(body) == "app")?;
}

test("package_coil_parse reads engine range") {
    let body = "[package]
name = \"app\"
version = \"0.1.0\"
coil = \">=0.1.0\"
";
    assert(package_coil_parse(body) == ">=0.1.0")?;
}

test("package_coil_parse omitted is empty") {
    let body = "[package]
name = \"app\"
version = \"0.1.0\"
";
    assert(package_coil_parse(body) == "")?;
}
