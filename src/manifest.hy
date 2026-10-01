// Parse and update coil.toml [dependencies] (git / path inline tables).
// Manifest decode uses coil-toml; deps_insert_line still edits text to preserve comments.
use text::{trim, starts_with, ends_with, split, contains, slice, join as text_join};
use io::file::{read_text, write_text};
use io::fs::{exists};
use string::{format};
use toml::{Toml, TomlValue, TomlError};

fn make_git_rev_dep(string name, string git, string version, string rev) -> string {
    return "g\t" + name + "\t" + git + "\t" + version + "\t" + rev;
}

fn make_git_dep(string name, string git, string version) -> string {
    return make_git_rev_dep(name, git, version, "");
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

/// Git `rev` pin (branch, tag or sha) or "".
fn dep_rev(string d) -> string {
    if dep_kind(d) != "g" {
        return "";
    }
    return dep_field(d, 4);
}

/// Constraint string for a git dep: `@<rev>` when pinned, else the range.
fn dep_req(string d) -> string {
    let r = dep_rev(d);
    if len(r) > 0 {
        return "@" + r;
    }
    return dep_version(d);
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
    // coil-toml indexes past the end when a document stops right after a
    // value with no newline; a trailing newline is always valid TOML.
    match Toml::v1().decode_str(body + "\n") {
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
    let rev = "";
    let i = 0;
    let n = value.table_len();
    while i < n {
        let k = value.key_at(i);
        let v = value.child(i);
        i = i + 1;
        if k == "trusted" {
            if v.is_bool() == false {
                raise format("dependency %s key trusted must be a bool", name);
            }
            continue;
        }
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
                    if k == "rev" {
                        rev = v.s;
                    } else {
                        raise format("unknown dependency key %s", k);
                    }
                }
            }
        }
    }
    if len(git) > 0 {
        if len(path) > 0 {
            raise "git and path cannot be combined";
        }
        if len(version) == 0 && len(rev) == 0 {
            raise format("git dependency %s needs version or rev", name);
        }
        return make_git_rev_dep(name, git, version, rev);
    }
    if len(path) > 0 {
        if len(version) > 0 || len(rev) > 0 {
            raise "path dependency cannot set version or rev";
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
        let line = name + " = { git = \"" + dep_git(dep) + "\"";
        if len(dep_version(dep)) > 0 {
            line = line + ", version = \"" + dep_version(dep) + "\"";
        }
        if len(dep_rev(dep)) > 0 {
            line = line + ", rev = \"" + dep_rev(dep) + "\"";
        }
        return line + " }";
    }
    if dep_kind(dep) == "p" {
        return name + " = { path = \"" + dep_path(dep) + "\" }";
    }
    raise "bad dependency record";
}

/// Push `line` before any trailing blank lines already in `out`.
fn push_before_blanks(Vec<string> out, string line) -> Vec<string> {
    let blanks = 0;
    while len(out) > 0 && len(out[len(out) - 1]) == 0 {
        out.pop();
        blanks = blanks + 1;
    }
    out.push(line);
    while blanks > 0 {
        out.push("");
        blanks = blanks - 1;
    }
    return out;
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
            if in_deps && inserted == false {
                out = push_before_blanks(out, line);
                inserted = true;
            }
            in_deps = trimmed == "[dependencies]";
            if in_deps {
                saw_deps = true;
            }
        }
        out.push(raw);
    }
    if in_deps && inserted == false {
        out = push_before_blanks(out, line);
        inserted = true;
    }
    if saw_deps == false {
        while len(out) > 0 && len(out[len(out) - 1]) == 0 {
            out.pop();
        }
        out.push("");
        out.push("[dependencies]");
        out.push(line);
    }
    let joined = text_join(out, "\n");
    if ends_with(joined, "\n") == false {
        joined = joined + "\n";
    }
    return joined;
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

fn manifest_body(string path) -> Result<string, string> {
    let present = match exists(path) {
        Result::Ok(v) => v,
        Result::Err(_) => false,
    };
    if present == false {
        raise format("%s not found", path);
    }
    return match read_text(path) {
        Result::Ok(s) => s,
        Result::Err(_) => raise format("failed to read %s", path),
    };
}

fn section_string(string body, string section, string key) -> Result<string, string> {
    let root = decode_manifest(body)?;
    match table_get(root, section) {
        Option::None => {
            return "";
        },
        Option::Some(tab) => {
            return table_string(tab, key);
        },
    };
}

fn section_bool(string body, string section, string key) -> Result<bool, string> {
    let root = decode_manifest(body)?;
    match table_get(root, section) {
        Option::None => {
            return false;
        },
        Option::Some(tab) => {
            if tab.has(key) == false {
                return false;
            }
            let v = tab.get(key);
            if v.is_bool() == false {
                raise format("[%s] %s must be a bool", section, key);
            }
            return v.flag;
        },
    };
}

fn section_strings(string body, string section, string key) -> Result<Vec<string>, string> {
    let root = decode_manifest(body)?;
    let out: Vec<string> = Vec::new();
    match table_get(root, section) {
        Option::None => {
            return out;
        },
        Option::Some(tab) => {
            if tab.has(key) == false {
                return out;
            }
            let v = tab.get(key);
            if v.is_array() == false {
                raise format("[%s] %s must be an array of strings", section, key);
            }
            let i = 0;
            let n = v.array_len();
            while i < n {
                let item = v.child(i);
                i = i + 1;
                if item.is_string() == false {
                    raise format("[%s] %s must be an array of strings", section, key);
                }
                out.push(item.s);
            }
            return out;
        },
    };
}

/// `[module].roots`, or `["./src"]` when absent.
fn module_roots_parse(string body) -> Result<Vec<string>, string> {
    let roots = section_strings(body, "module", "roots")?;
    if len(roots) == 0 {
        roots.push("./src");
    }
    return roots;
}

fn package_version_parse(string body) -> string {
    return package_field_parse(body, "version");
}

/// Drop the `[dependencies]` line for `name`. Only single-line entries
/// (`name = { … }`, as `spool add` writes them) are supported.
fn deps_remove_line(string body, string name) -> Result<string, string> {
    let lines = match split(body, "\n") {
        Result::Ok(ls) => ls,
        Result::Err(_) => raise "split failed",
    };
    let out: Vec<string> = Vec::new();
    let in_deps = false;
    let removed = false;
    let i = 0;
    while i < len(lines) {
        let raw = lines[i];
        i = i + 1;
        let t = match trim(raw) {
            Result::Ok(x) => x,
            Result::Err(_) => raw,
        };
        if starts_with(t, "[") {
            in_deps = t == "[dependencies]";
            out.push(raw);
            continue;
        }
        if in_deps && removed == false {
            if starts_with(t, name) {
                let tail = match slice(t, len(name), len(t)) {
                    Result::Ok(x) => x,
                    Result::Err(_) => "",
                };
                let rest = match trim(tail) {
                    Result::Ok(x) => x,
                    Result::Err(_) => tail,
                };
                if starts_with(rest, "=") {
                    if contains(rest, "}") == false {
                        raise format("dependency %s spans several lines; remove it by hand", name);
                    }
                    removed = true;
                    continue;
                }
            }
        }
        out.push(raw);
    }
    if removed == false {
        raise format("dependency %s is not declared in coil.toml", name);
    }
    return text_join(out, "\n");
}

fn deps_remove(string path, string name) -> Result<int, string> {
    let body = manifest_body(path)?;
    let updated = deps_remove_line(body, name)?;
    // Re-parse so a bad edit never lands on disk.
    deps_parse(updated)?;
    return match write_text(path, updated) {
        Result::Ok(_) => 0,
        Result::Err(_) => raise format("failed to write %s", path),
    };
}
