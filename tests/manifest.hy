use manifest::{
    deps_parse, dep_kind, dep_name, dep_git, dep_version, dep_path, deps_insert_line,
    make_git_dep, format_dep_line, deps_has_name, package_name_parse, package_coil_parse,
    package_include_parse, scripts_parse, scripts_path_of, script_rel_ok, dep_rev, dep_req,
    deps_remove_line, manifest_validate,
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

test("deps_insert_line keeps entries together and ends with a newline") {
    let body = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[dependencies]\na = { path = \"../a\" }\n\n";
    let out = deps_insert_line(body, "b = { path = \"../b\" }")?;
    assert(contains(out, "a = { path = \"../a\" }\nb = { path = \"../b\" }\n"))?;
    let deps = deps_parse(out)?;
    assert(len(deps) == 2)?;
}

test("deps_insert_line output without trailing newline still decodes") {
    let body = "[package]\nname = \"app\"\nversion = \"0.1.0\"";
    let out = deps_insert_line(body, "b = { path = \"../b\" }")?;
    let deps = deps_parse(out)?;
    assert(len(deps) == 1)?;
}

test("git deps accept rev pins and trusted") {
    let body = "[dependencies]\ntoml = { git = \"https://example.com/a/toml.git\", rev = \"main\", trusted = true }\n";
    let deps = deps_parse(body)?;
    assert(dep_rev(deps[0]) == "main")?;
    assert(dep_req(deps[0]) == "@main")?;
}

test("deps_remove_line drops only the named entry") {
    let body = "[dependencies]\nab = { path = \"../ab\" }\na = { path = \"../a\" }\n";
    let out = deps_remove_line(body, "a")?;
    let deps = deps_parse(out)?;
    assert(len(deps) == 1)?;
    assert(dep_name(deps[0]) == "ab")?;
}

fn validate_err(string body) -> string {
    return match manifest_validate(body) {
        Result::Ok(_) => "",
        Result::Err(e) => e,
    };
}

test("manifest_validate accepts every known section and key") {
    let body = "[package]
name = \"app\"
version = \"0.1.0\"
coil = \">=0.1.0\"
include = \"./hooks/include.sh\"

[module]
roots = [\"./src\"]

[entry]
file = \"./src/main.hy\"

[permissions]
read = true
all = false

[env]
allow_exec = true
allow_exit = true
allow_ffi_exec = false

[ffi]
search_paths = [\"./native\"]
allow = [\"plugin\"]
allow_attach = true

[[ffi.native]]
name = \"regex\"
version = \"0.3.0\"
path = \"./native\"

[scripts]
pre_install = \"./scripts/pre.sh\"

[dependencies]
http = { git = \"https://x/http.git\", version = \"^0.2\", trusted = true }
";
    assert(validate_err(body) == "")?;
    assert(validate_err("") == "")?;
}

test("manifest_validate rejects unknown sections and keys") {
    assert(contains(validate_err("[permisions]
read = true
"), "unknown section [permisions]"))?;
    assert(contains(validate_err("[env]
allow_exce = true
"), "unknown key env.allow_exce"))?;
    assert(contains(validate_err("[package]
name = \"a\"
version = \"1\"
authors = [\"x\"]
"), "unknown key package.authors"))?;
    assert(contains(validate_err("[module]
preludes = []
"), "unknown key module.preludes"))?;
    assert(contains(validate_err("name = \"a\"
"), "unknown key name"))?;
    assert(contains(validate_err("[scripts]
pre_build = \"./x.sh\"
"), "unknown scripts key"))?;
    assert(contains(validate_err("[[ffi.native]]
name = \"r\"
version = \"1\"
path = \".\"
url2 = \"x\"
"), "unknown key ffi.native.url2"))?;
}
