// Parse and update coil.toml [dependencies] (git / path inline tables).
// Manifest decode uses coil-toml; deps_insert_line still edits text to preserve comments.
use text::{Joined, Searchable, Text};
use io::file::read_text;
use io::file::write_text;
use io::fs::exists;
use string::format;
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
    let parts = d.split("\t");
    if idx < parts.len() {
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

/// Constraint string for a git dep: `@<rev>` when pinned, else the range
/// (or `latest`, the default-branch tip).
fn dep_req(string d) -> string {
    let r = dep_rev(d);
    if r.len() > 0 {
        return "@" + r;
    }
    return dep_version(d);
}

fn toml_err(TomlError e) -> string {
    match e {
        TomlError::Invalid { line, column } => {
            return format("invalid toml at %i:%i", line, column);
        },
        TomlError::Utf8 { line, column } => {
            return format("toml utf8 at %i:%i", line, column);
        },
        TomlError::Number { line, column } => {
            return format("toml number at %i:%i", line, column);
        },
    }
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
    }
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
    if git.len() > 0 {
        if path.len() > 0 {
            raise "git and path cannot be combined";
        }
        if version.len() == 0 && rev.len() == 0 {
            raise format("git dependency %s needs version or rev", name);
        }
        if version.len() > 0 && rev.len() > 0 {
            raise format(
                "git dependency %s: version = \"%s\" cannot be combined with rev",
                name,
                version,
            );
        }
        return make_git_rev_dep(name, git, version, rev);
    }
    if path.len() > 0 {
        if version.len() > 0 || rev.len() > 0 {
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
                while j < out.len() {
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
    }
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
            }
        },
        Result::Err(_) => {
            return "";
        },
    }
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
    if p.len() == 0 {
        return false;
    }
    if p.starts_with("/") {
        return false;
    }
    let parts = p.split("/");
    let i = 0;
    while i < parts.len() {
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
    if rel.len() == 0 {
        return "";
    }
    if script_rel_ok(rel) == false {
        raise format("include path must be relative to the package checkout: %s", rel);
    }
    return rel;
}

fn scripts_field(string rec, int idx) -> string {
    let parts = rec.split("\t");
    if idx < parts.len() {
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
    while i < recs.len() {
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
                if path.len() == 0 {
                    continue;
                }
                if script_rel_ok(path) == false {
                    raise format("script path must be relative to the project root: %s", path);
                }
                let j = 0;
                while j < out.len() {
                    if scripts_slot(out[j]) == k {
                        raise format("duplicate scripts key %s", k);
                    }
                    j = j + 1;
                }
                out.push(k + "\t" + path);
            }
            return out;
        },
    }
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
        if dep_version(dep).len() > 0 {
            line = line + ", version = \"" + dep_version(dep) + "\"";
        }
        if dep_rev(dep).len() > 0 {
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
    while out.len() > 0 && out[out.len() - 1].len() == 0 {
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
    let lines = body.split("\n");
    let out: Vec<string> = Vec::new();
    let i = 0;
    let in_deps = false;
    let inserted = false;
    let saw_deps = false;
    while i < lines.len() {
        let raw = lines[i];
        let trimmed = raw.trim();
        i = i + 1;
        if trimmed.starts_with("[") {
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
        while out.len() > 0 && out[out.len() - 1].len() == 0 {
            out.pop();
        }
        out.push("");
        out.push("[dependencies]");
        out.push(line);
    }
    let joined = out.join("\n");
    if joined.ends_with("\n") == false {
        joined = joined + "\n";
    }
    return joined;
}

fn deps_has_name(Vec<string> deps, string name) -> bool {
    let i = 0;
    while i < deps.len() {
        if dep_name(deps[i]) == name {
            return true;
        }
        i = i + 1;
    }
    return false;
}

fn find_dep(Vec<string> deps, string name) -> Result<string, string> {
    let i = 0;
    while i < deps.len() {
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
    }
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
    }
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
    }
}

/// Keys spool knows in a coil.toml section; "" for an unknown section.
/// `[dependencies]` and `[scripts]` entries are checked by their parsers.
fn manifest_section_keys(string section) -> string {
    if section == "package" {
        return ",name,version,coil,include,";
    }
    if section == "module" {
        return ",roots,";
    }
    if section == "entry" {
        return ",file,";
    }
    if section == "permissions" {
        return ",read,write,net,env,exec,exit,attach,all,";
    }
    if section == "env" {
        return ",allow_exit,allow_ffi_exec,";
    }
    if section == "ffi" {
        return ",search_paths,allow,allow_attach,native,";
    }
    if section == "comptime" {
        return ",read,write,env,net,cache,";
    }
    return "";
}

/// Reject unknown sections and keys in a project coil.toml, so a typo
/// (`[permisions]`, `allow_exce`) fails instead of silently granting nothing.
fn manifest_validate(string body) -> Result<int, string> {
    let root = decode_manifest(body)?;
    let i = 0;
    let n = root.table_len();
    while i < n {
        let section = root.key_at(i);
        let tab = root.child(i);
        i = i + 1;
        if section == "dependencies" || section == "scripts" {
            if tab.is_table() == false {
                raise format("[%s] must be a table", section);
            }
            continue;
        }
        let keys = manifest_section_keys(section);
        if keys.len() == 0 {
            if tab.is_table() {
                raise format("unknown section [%s]", section);
            }
            raise format("unknown key %s (keys belong under a [section])", section);
        }
        if tab.is_table() == false {
            raise format("[%s] must be a table", section);
        }
        let j = 0;
        let m = tab.table_len();
        while j < m {
            let k = tab.key_at(j);
            j = j + 1;
            if keys.contains("," + k + ",") == false {
                if k == "exec" || k == "allow_exec" {
                    raise format(
                        "%s.%s was removed: running programs is granted by [permissions] exec",
                        section,
                        k,
                    );
                }
                raise format("unknown key %s.%s", section, k);
            }
        }
    }
    deps_parse(body)?;
    scripts_parse(body)?;
    ffi_natives_parse(body)?;
    return 0;
}

/// `[module].roots`, or `["./src"]` when absent.
fn module_roots_parse(string body) -> Result<Vec<string>, string> {
    let roots = section_strings(body, "module", "roots")?;
    if roots.len() == 0 {
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
    let lines = body.split("\n");
    let out: Vec<string> = Vec::new();
    let in_deps = false;
    let removed = false;
    let i = 0;
    while i < lines.len() {
        let raw = lines[i];
        i = i + 1;
        let t = raw.trim();
        if t.starts_with("[") {
            in_deps = t == "[dependencies]";
            out.push(raw);
            continue;
        }
        if in_deps && removed == false {
            if t.starts_with(name) {
                let tail = match t.slice(name.len(), t.len()) {
                    Result::Ok(x) => x,
                    Result::Err(_) => "",
                };
                let rest = tail.trim();
                if rest.starts_with("=") {
                    if rest.contains("}") == false {
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
    return out.join("\n");
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

/// `[dependencies]` names whose inline table sets `trusted = true`.
fn trusted_deps_parse(string body) -> Result<Vec<string>, string> {
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
                let spec = tab.child(i);
                i = i + 1;
                if spec.is_table() == false || spec.has("trusted") == false {
                    continue;
                }
                let t = spec.get("trusted");
                if t.is_bool() == false {
                    raise format("dependency %s key trusted must be a bool", name);
                }
                if t.flag {
                    out.push(name);
                }
            }
            return out;
        },
    }
}

// `[[ffi.native]]` rows as tab-separated records:
//   name \t package \t version \t path \t url \t requires (`;`-joined) \t requires_hint \t sha256
// `package` defaults to `name`. `url` and `sha256` (64 hex digits, stored
// lowercase) are optional and only used by `spool download`.

fn native_name(string r) -> string {
    return dep_field(r, 0);
}

fn native_package(string r) -> string {
    return dep_field(r, 1);
}

fn native_version(string r) -> string {
    return dep_field(r, 2);
}

fn native_path(string r) -> string {
    return dep_field(r, 3);
}

fn native_url(string r) -> string {
    return dep_field(r, 4);
}

fn native_requires(string r) -> string {
    return dep_field(r, 5);
}

fn native_requires_hint(string r) -> string {
    return dep_field(r, 6);
}

fn native_sha256(string r) -> string {
    return dep_field(r, 7);
}

/// `s` lowercased when it is 64 hex digits, else an error naming row `name`.
fn native_sha256_value(string name, string s) -> Result<string, string> {
    let low = s.to_lower();
    let ok = low.len() == 64;
    let i = 0;
    while ok && i < 64 {
        let c = low.slice(i, i + 1)?;
        if "0123456789abcdef".contains(c) == false {
            ok = false;
        }
        i = i + 1;
    }
    if ok == false {
        raise format("[[ffi.native]] %s sha256 must be 64 hex digits, got %s", name, s);
    }
    return low;
}

fn ffi_native_row(TomlValue row, int idx) -> Result<string, string> {
    if row.is_table() == false {
        raise format("[[ffi.native]] #%i must be a table", idx);
    }
    let name = "";
    let package = "";
    let version = "";
    let path = "";
    let url = "";
    let sha = "";
    let requires = "";
    let hint = "";
    let i = 0;
    let n = row.table_len();
    while i < n {
        let k = row.key_at(i);
        let v = row.child(i);
        i = i + 1;
        if k == "requires" {
            if v.is_array() == false {
                raise "[[ffi.native]] requires must be an array of strings";
            }
            let j = 0;
            while j < v.array_len() {
                let item = v.child(j);
                j = j + 1;
                if item.is_string() == false {
                    raise "[[ffi.native]] requires must be an array of strings";
                }
                if requires.len() > 0 {
                    requires = requires + ";";
                }
                requires = requires + item.s;
            }
            continue;
        }
        if v.is_string() == false {
            raise format("[[ffi.native]] %s must be a string", k);
        }
        if v.s.contains("\t") {
            raise format("[[ffi.native]] %s cannot contain a tab", k);
        }
        if k == "name" {
            name = v.s;
            continue;
        }
        if k == "package" {
            package = v.s;
            continue;
        }
        if k == "version" {
            version = v.s;
            continue;
        }
        if k == "path" {
            path = v.s;
            continue;
        }
        if k == "url" {
            url = v.s;
            continue;
        }
        if k == "requires_hint" {
            hint = v.s;
            continue;
        }
        if k == "sha256" {
            sha = v.s;
            continue;
        }
        raise format("unknown key ffi.native.%s", k);
    }
    if name.len() == 0 {
        raise "[[ffi.native]] missing required key name";
    }
    if version.len() == 0 {
        raise format("[[ffi.native]] %s missing required key version", name);
    }
    if path.len() == 0 {
        raise format("[[ffi.native]] %s missing required key path", name);
    }
    if package.len() == 0 {
        package = name;
    }
    if sha.len() > 0 {
        sha = native_sha256_value(name, sha)?;
    }
    return name + "\t" + package + "\t" + version + "\t" + path + "\t" + url + "\t" + requires +
           "\t" + hint + "\t" + sha;
}

/// `[[ffi.native]]` rows (see the record layout above). Unknown keys hard-error.
fn ffi_natives_parse(string body) -> Result<Vec<string>, string> {
    let root = decode_manifest(body)?;
    let out: Vec<string> = Vec::new();
    match table_get(root, "ffi") {
        Option::None => {
            return out;
        },
        Option::Some(ffi) => {
            if ffi.has("native") == false {
                return out;
            }
            let rows = ffi.get("native");
            if rows.is_array() == false {
                raise "[ffi] native must be an array of tables ([[ffi.native]])";
            }
            let i = 0;
            while i < rows.array_len() {
                out.push(ffi_native_row(rows.child(i), i + 1)?);
                i = i + 1;
            }
            return out;
        },
    }
}
