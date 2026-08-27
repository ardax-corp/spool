// Parse and update coil.toml [dependencies] (git / path inline tables).
// Manifest decode uses coil-toml; deps_insert_line still edits text to preserve comments.
use text::{trim, starts_with, split, join as text_join};
use io::file::{read_text, write_text};
use io::fs::{exists};
use string::{format};
use toml::{Toml, TomlValue, TomlError};

fn make_git_dep(string name, string git, string version) -> string {
    return "g\t" + name + "\t" + git + "\t" + version;
}

fn make_path_dep(string name, string path) -> string {
    return "p\t" + name + "\t" + path;
}

fn dep_field(string d, int idx) -> string {
    let parts = match split(d, "\t") {
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

fn dep_kind(string d) -> string {
    return dep_field(d, 0);
}

fn dep_name(string d) -> string {
    return dep_field(d, 1);
}

fn dep_git(string d) -> string {
    if dep_kind(d) != "g" {
        return "";
    }
    return dep_field(d, 2);
}

fn dep_version(string d) -> string {
    if dep_kind(d) != "g" {
        return "";
    }
    return dep_field(d, 3);
}

fn dep_path(string d) -> string {
    if dep_kind(d) != "p" {
        return "";
    }
    return dep_field(d, 2);
}

fn toml_err(TomlError e) -> string {
    match e {
        TomlError::Invalid { line, column } => {
            return format("invalid toml at %i:%i", line, column);
        },
        TomlError::Io { line, column } => {
            return format("toml io at %i:%i", line, column);
        },
        TomlError::Utf8 { line, column } => {
            return format("toml utf8 at %i:%i", line, column);
        },
        TomlError::Number { line, column } => {
            return format("toml number at %i:%i", line, column);
        },
    };
}

fn decode_manifest(string body) -> Result<TomlValue, string> {
    match Toml::v1().decode_str(body) {
        Result::Ok(v) => {
            return v;
        },
        Result::Err(e) => {
            raise toml_err(e);
        },
    };
}

fn table_get(TomlValue root, string key) -> Option<TomlValue> {
    if root.is_table() == false {
        return Option::None;
    }
    if root.has(key) == false {
        return Option::None;
    }
    let v = root.get(key);
    if v.is_table() {
        return Option::Some(v);
    }
    return Option::None;
}

fn table_string(TomlValue tab, string key) -> string {
    if tab.has(key) == false {
        return "";
    }
    let v = tab.get(key);
    if v.is_string() {
        return v.s;
    }
    return "";
}

fn parse_dep_spec_value(string name, TomlValue value) -> Result<string, string> {
    if value.is_table() == false {
        raise "expected inline table";
    }
    let git = "";
    let version = "";
    let path = "";
    let i = 0;
    let n = value.table_len();
    while i < n {
        let k = value.key_at(i);
        let v = value.child(i);
        i = i + 1;
        if v.is_string() == false {
            raise format("dependency %s key %s must be a string", name, k);
        }
        if k == "git" {
            git = v.s;
        } else {
            if k == "version" {
                version = v.s;
            } else {
                if k == "path" {
                    path = v.s;
                } else {
                    raise format("unknown dependency key %s", k);
                }
            }
        }
    }
    if len(git) > 0 {
        if len(path) > 0 {
            raise "git and path cannot be combined";
        }
        if len(version) == 0 {
            raise "git dependency missing version";
        }
        return make_git_dep(name, git, version);
    }
    if len(path) > 0 {
        if len(version) > 0 {
            raise "path dependency cannot set version";
        }
        return make_path_dep(name, path);
    }
    raise "dependency needs git+version or path";
}

fn deps_parse(string body) -> Result<Vec<string>, string> {
    let root = decode_manifest(body)?;
    let out: Vec<string> = Vec::new();
    match table_get(root, "dependencies") {
        Option::None => {
            return out;
        },
        Option::Some(tab) => {
            let i = 0;
            let n = tab.table_len();
            while i < n {
                let name = tab.key_at(i);
                let j = 0;
                while j < len(out) {
                    if dep_name(out[j]) == name {
                        raise format("duplicate dependency %s", name);
                    }
                    j = j + 1;
                }
                let dep = parse_dep_spec_value(name, tab.child(i))?;
                out.push(dep);
                i = i + 1;
            }
            return out;
        },
    };
}

fn package_field_parse(string body, string key) -> string {
    match decode_manifest(body) {
        Result::Ok(root) => {
            match table_get(root, "package") {
                Option::None => {
                    return "";
                },
                Option::Some(pkg) => {
                    return table_string(pkg, key);
                },
            };
        },
        Result::Err(_) => {
            return "";
        },
    };
}

fn package_name_parse(string body) -> string {
    return package_field_parse(body, "name");
}

fn package_coil_parse(string body) -> string {
    return package_field_parse(body, "coil");
}

fn package_include_parse(string body) -> string {
    return package_field_parse(body, "include");
}

fn script_slot_known(string k) -> bool {
    if k == "pre_install" {
        return true;
    }
    if k == "post_install" {
        return true;
    }
    if k == "pre_update" {
        return true;
    }
    if k == "post_update" {
        return true;
    }
    return false;
}

fn script_rel_ok(string p) -> bool {
    if len(p) == 0 {
        return false;
    }
    if starts_with(p, "/") {
        return false;
    }
    let parts = match split(p, "/") {
        Result::Ok(v) => v,
        Result::Err(_) => {
            return false;
        },
    };
    let i = 0;
    while i < len(parts) {
        if parts[i] == ".." {
            return false;
        }
        i = i + 1;
    }
    return true;
}

fn package_include_read(string path) -> Result<string, string> {
    let present = match exists(path) {
        Result::Ok(v) => v,
        Result::Err(_) => false,
    };
    if present == false {
        return "";
    }
    let body = match read_text(path) {
        Result::Ok(s) => s,
        Result::Err(_) => raise format("failed to read %s", path),
    };
    let rel = package_include_parse(body);
    if len(rel) == 0 {
        return "";
    }
    if script_rel_ok(rel) == false {
        raise format("include path must be relative to the package checkout: %s", rel);
    }
    return rel;
}

fn scripts_field(string rec, int idx) -> string {
    let parts = match split(rec, "\t") {
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

fn scripts_slot(string rec) -> string {
    return scripts_field(rec, 0);
}

fn scripts_rel(string rec) -> string {
    return scripts_field(rec, 1);
}

fn scripts_path_of(Vec<string> recs, string slot) -> string {
    let i = 0;
    while i < len(recs) {
        if scripts_slot(recs[i]) == slot {
            return scripts_rel(recs[i]);
        }
        i = i + 1;
    }
    return "";
}

/// Current-project `[scripts]` only. Unknown keys hard-error. Missing keys omitted.
fn scripts_parse(string body) -> Result<Vec<string>, string> {
    let root = decode_manifest(body)?;
    let out: Vec<string> = Vec::new();
    match table_get(root, "scripts") {
        Option::None => {
            return out;
        },
        Option::Some(tab) => {
            let i = 0;
            let n = tab.table_len();
            while i < n {
                let k = tab.key_at(i);
                let v = tab.child(i);
                i = i + 1;
                if script_slot_known(k) == false {
                    raise format("unknown scripts key %s", k);
                }
                if v.is_string() == false {
                    raise format("scripts key %s must be a string", k);
                }
                let path = v.s;
                if len(path) == 0 {
                    continue;
                }
                if script_rel_ok(path) == false {
                    raise format("script path must be relative to the project root: %s", path);
                }
                let j = 0;
                while j < len(out) {
                    if scripts_slot(out[j]) == k {
                        raise format("duplicate scripts key %s", k);
                    }
                    j = j + 1;
                }
                out.push(k + "\t" + path);
            }
            return out;
        },
    };
}

fn scripts_read(string path) -> Result<Vec<string>, string> {
    let present = match exists(path) {
        Result::Ok(v) => v,
        Result::Err(_) => false,
    };
    if present == false {
        let empty: Vec<string> = Vec::new();
        return empty;
    }
    let body = match read_text(path) {
        Result::Ok(s) => s,
        Result::Err(_) => raise format("failed to read %s", path),
    };
    return scripts_parse(body)?;
}

fn package_name_read(string path) -> string {
    let present = match exists(path) {
        Result::Ok(v) => v,
        Result::Err(_) => false,
    };
    if present == false {
        return "";
    }
    let body = match read_text(path) {
        Result::Ok(s) => s,
        Result::Err(_) => {
            return "";
        },
    };
    return package_name_parse(body);
}

fn deps_read(string path) -> Result<Vec<string>, string> {
    let present = match exists(path) {
        Result::Ok(v) => v,
        Result::Err(_) => false,
    };
    if present == false {
        raise format("failed to read %s", path);
    }
    let body = match read_text(path) {
        Result::Ok(s) => s,
        Result::Err(_) => raise format("failed to read %s", path),
    };
    return deps_parse(body)?;
}

fn format_dep_line(string dep) -> Result<string, string> {
    let name = dep_name(dep);
    if dep_kind(dep) == "g" {
        return name + " = { git = \"" + dep_git(dep) + "\", version = \"" + dep_version(dep) + "\" }";
    }
    if dep_kind(dep) == "p" {
        return name + " = { path = \"" + dep_path(dep) + "\" }";
    }
    raise "bad dependency record";
}

fn deps_insert_line(string body, string line) -> Result<string, string> {
    let lines = match split(body, "\n") {
        Result::Ok(ls) => ls,
        Result::Err(_) => raise "split failed",
    };
    let out: Vec<string> = Vec::new();
    let i = 0;
    let in_deps = false;
    let inserted = false;
    let saw_deps = false;
    while i < len(lines) {
        let raw = lines[i];
        let trimmed = match trim(raw) {
            Result::Ok(t) => t,
            Result::Err(_) => raw,
        };
        i = i + 1;
        if starts_with(trimmed, "[") {
            if in_deps {
                if inserted == false {
                    out.push(line);
                    inserted = true;
                }
                in_deps = false;
            }
            if trimmed == "[dependencies]" {
                saw_deps = true;
                in_deps = true;
            }
        }
        out.push(raw);
    }
    if in_deps {
        if inserted == false {
            out.push(line);
            inserted = true;
        }
    }
    if saw_deps == false {
        out.push("");
        out.push("[dependencies]");
        out.push(line);
    }
    return text_join(out, "\n");
}

fn deps_has_name(Vec<string> deps, string name) -> bool {
    let i = 0;
    while i < len(deps) {
        if dep_name(deps[i]) == name {
            return true;
        }
        i = i + 1;
    }
    return false;
}

fn find_dep(Vec<string> deps, string name) -> Result<string, string> {
    let i = 0;
    while i < len(deps) {
        if dep_name(deps[i]) == name {
            return deps[i];
        }
        i = i + 1;
    }
    raise format("dependency %s not declared", name);
}

fn deps_append(string path, string dep) -> Result<int, string> {
    let body = match read_text(path) {
        Result::Ok(s) => s,
        Result::Err(_) => raise format("failed to read %s", path),
    };
    let existing = deps_parse(body)?;
    let name = dep_name(dep);
    if deps_has_name(existing, name) {
        raise format("dependency %s is already declared", name);
    }
    let line = format_dep_line(dep)?;
    let updated = deps_insert_line(body, line)?;
    return match write_text(path, updated) {
        Result::Ok(_) => 0,
        Result::Err(_) => raise format("failed to write %s", path),
    };
}
