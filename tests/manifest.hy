use manifest::{
    deps_parse, dep_kind, dep_name, dep_git, dep_version, dep_path, deps_insert_line,
    make_git_dep, format_dep_line, deps_has_name, package_name_parse, package_coil_parse,
    package_include_parse, scripts_parse, scripts_path_of, script_rel_ok,
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

test("package_coil_parse ignores include and scripts") {
    let body = "[package]
name = \"app\"
version = \"0.1.0\"
coil = \">=0.1.0\"
include = \"./hooks/include.sh\"

[scripts]
preinstall = \"./hooks/preinstall.sh\"
";
    assert(package_coil_parse(body) == ">=0.1.0")?;
}

test("package_include_parse reads include-hook path") {
    let body = "[package]
name = \"http\"
version = \"0.1.0\"
include = \"./hooks/include.sh\"
";
    assert(package_include_parse(body) == "./hooks/include.sh")?;
}

test("package_include_parse omitted is empty") {
    let body = "[package]
name = \"http\"
version = \"0.1.0\"
";
    assert(package_include_parse(body) == "")?;
}

test("include-hook path is read without a [hooks] table") {
    let body = "[package]
name = \"http\"
version = \"0.1.0\"
include = \"./hooks/include.sh\"

[module]
roots = [\"./src\"]
";
    assert(contains(body, "[hooks]") == false)?;
    assert(package_include_parse(body) == "./hooks/include.sh")?;
}

test("scripts_parse reads current-project lifecycle paths") {
    let body = "[package]
name = \"app\"
version = \"0.0.1\"

[scripts]
pre_install = \"./scripts/pre-install.sh\"
post_install = \"./scripts/post-install.sh\"
pre_update = \"./scripts/pre-update.sh\"
post_update = \"./scripts/post-update.sh\"
";
    let recs = scripts_parse(body)?;
    assert(scripts_path_of(recs, "pre_install") == "./scripts/pre-install.sh")?;
    assert(scripts_path_of(recs, "post_install") == "./scripts/post-install.sh")?;
    assert(scripts_path_of(recs, "pre_update") == "./scripts/pre-update.sh")?;
    assert(scripts_path_of(recs, "post_update") == "./scripts/post-update.sh")?;
}

test("scripts_parse missing keys are omitted") {
    let body = "[scripts]
pre_install = \"./scripts/pre-install.sh\"
";
    let recs = scripts_parse(body)?;
    assert(len(recs) == 1)?;
    assert(scripts_path_of(recs, "post_install") == "")?;
}

test("scripts_parse unknown key hard-errors") {
    let r = scripts_parse("[scripts]
preinstall = \"./hooks/preinstall.sh\"
");
    match r {
        Result::Ok(_) => {
            assert(false)?;
        },
        Result::Err(e) => {
            assert(contains(e, "unknown scripts key"))?;
        },
    };
}

test("script paths stay in the project tree") {
    assert(script_rel_ok("./scripts/pre-install.sh"))?;
    assert(script_rel_ok("../evil.sh") == false)?;
    assert(script_rel_ok("/tmp/x.sh") == false)?;
}
