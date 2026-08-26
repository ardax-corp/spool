// Parse and update coil.toml [dependencies] (git / path inline tables).
use text::{trim, starts_with, ends_with, split, join as text_join, slice, contains};
use io::file::{read_text, write_text};
use io::fs::{exists};
use string::{format};
use lock::{strip_quotes, parse_kv_line};

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

fn parse_inline_table(string value) -> Result<Vec<(string, string)>, string> {
    let t = match trim(value) {
        Result::Ok(x) => x,
        Result::Err(_) => value,
    };
    if starts_with(t, "{") == false {
        raise "expected inline table";
    }
    if ends_with(t, "}") == false {
        raise "expected inline table";
    }
    let inner = slice(t, 1, len(t) - 1)?;
    let pieces = match split(inner, ",") {
        Result::Ok(p) => p,
        Result::Err(_) => raise "split inline table failed",
    };
    let out: Vec<(string, string)> = Vec::new();
    let i = 0;
    while i < len(pieces) {
        let piece = match trim(pieces[i]) {
            Result::Ok(x) => x,
            Result::Err(_) => pieces[i],
        };
        i = i + 1;
        if len(piece) == 0 {
            continue;
        }
        let kv = parse_kv_line(piece)?;
        out.push(kv);
    }
    return out;
}

fn parse_dep_spec(string name, string value) -> Result<string, string> {
    let entries = parse_inline_table(value)?;
    let git = "";
    let version = "";
    let path = "";
    let i = 0;
    while i < len(entries) {
        let (k, v) = entries[i];
        i = i + 1;
        if k == "git" {
            git = v;
        } else {
            if k == "version" {
                version = v;
            } else {
                if k == "path" {
                    path = v;
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
    let lines = match split(body, "\n") {
        Result::Ok(ls) => ls,
        Result::Err(_) => raise "split manifest failed",
    };
    let out: Vec<string> = Vec::new();
    let in_deps = false;
    let i = 0;
    while i < len(lines) {
        let line = match trim(lines[i]) {
            Result::Ok(t) => t,
            Result::Err(_) => lines[i],
        };
        i = i + 1;
        if len(line) == 0 {
            continue;
        }
        if starts_with(line, "#") {
            continue;
        }
        if starts_with(line, "[") {
            in_deps = line == "[dependencies]";
            continue;
        }
        if in_deps == false {
            continue;
        }
        let kv = parse_kv_line(line)?;
        let (name, value) = kv;
        let j = 0;
        while j < len(out) {
            if dep_name(out[j]) == name {
                raise format("duplicate dependency %s", name);
            }
            j = j + 1;
        }
        let dep = parse_dep_spec(name, value)?;
        out.push(dep);
    }
    return out;
}

fn package_field_parse(string body, string key) -> string {
    let lines = match split(body, "\n") {
        Result::Ok(ls) => ls,
        Result::Err(_) => {
            return "";
        },
    };
    let in_pkg = false;
    let i = 0;
    while i < len(lines) {
        let line = match trim(lines[i]) {
            Result::Ok(t) => t,
            Result::Err(_) => lines[i],
        };
        i = i + 1;
        if len(line) == 0 {
            continue;
        }
        if starts_with(line, "#") {
            continue;
        }
        if starts_with(line, "[") {
            in_pkg = line == "[package]";
            continue;
        }
        if in_pkg == false {
            continue;
        }
        if contains(line, "=") == false {
            continue;
        }
        let kv_res = parse_kv_line(line);
        match kv_res {
            Result::Ok(kv) => {
                let (k, v) = kv;
                if k == key {
                    return v;
                }
            },
            Result::Err(_) => {},
        };
    }
    return "";
}

fn package_name_parse(string body) -> string {
    return package_field_parse(body, "name");
}

fn package_coil_parse(string body) -> string {
    return package_field_parse(body, "coil");
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
