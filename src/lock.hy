// coil.lock read/write - deterministic spool lockfile format.
// Packages are carried as tab-separated records:
//   name \t git \t tag \t rev \t content_hash \t hook_path \t hook_hash
// Optional [hooks] allow_include is a consumer allowlist (not a git identity).
// Consumer [scripts] hashes live in a lock [scripts] table, not a [[package]] row.
use text::{trim, starts_with, split, contains, ends_with, slice, join as text_join};
use io::file::{read_text, write_text};
use io::fs::{exists};
use string::{format, to_bytes};

fn make_git_pkg_hook(
    string name,
    string git,
    string tag,
    string rev,
    string hash,
    string hook_path,
    string hook_hash,
) -> string {
    return name + "\t" + git + "\t" + tag + "\t" + rev + "\t" + hash + "\t" + hook_path + "\t" + hook_hash;
}

fn make_git_pkg(string name, string git, string tag, string rev, string hash) -> string {
    return make_git_pkg_hook(name, git, tag, rev, hash, "", "");
}

fn field_at(string p, int idx) -> string {
    let parts = match split(p, "\t") {
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

fn lock_pkg_name(string p) -> string {
    return field_at(p, 0);
}

fn lock_pkg_git(string p) -> string {
    return field_at(p, 1);
}

fn lock_pkg_tag(string p) -> string {
    return field_at(p, 2);
}

fn lock_pkg_rev(string p) -> string {
    return field_at(p, 3);
}

fn lock_pkg_hash(string p) -> string {
    return field_at(p, 4);
}

fn lock_git_url(string p) -> string {
    return lock_pkg_git(p);
}

fn lock_git_rev(string p) -> string {
    return lock_pkg_rev(p);
}

fn lock_git_hash(string p) -> string {
    return lock_pkg_hash(p);
}

fn lock_pkg_hook_path(string p) -> string {
    return field_at(p, 5);
}

fn lock_pkg_hook_hash(string p) -> string {
    return field_at(p, 6);
}

fn lock_pkg_with_hook(string p, string hook_path, string hook_hash) -> string {
    return make_git_pkg_hook(
        lock_pkg_name(p),
        lock_pkg_git(p),
        lock_pkg_tag(p),
        lock_pkg_rev(p),
        lock_pkg_hash(p),
        hook_path,
        hook_hash,
    );
}

fn make_lock_script(string slot, string path, string hash) -> string {
    return slot + "\t" + path + "\t" + hash;
}

fn lock_script_slot(string p) -> string {
    return field_at(p, 0);
}

fn lock_script_path(string p) -> string {
    return field_at(p, 1);
}

fn lock_script_hash(string p) -> string {
    return field_at(p, 2);
}

fn lock_find_script(Vec<string> scripts, string slot) -> string {
    let i = 0;
    while i < len(scripts) {
        if lock_script_slot(scripts[i]) == slot {
            return scripts[i];
        }
        i = i + 1;
    }
    return "";
}

fn lock_upsert_script(Vec<string> scripts, string rec) -> Vec<string> {
    let slot = lock_script_slot(rec);
    let out: Vec<string> = Vec::new();
    let i = 0;
    while i < len(scripts) {
        if lock_script_slot(scripts[i]) != slot {
            out.push(scripts[i]);
        }
        i = i + 1;
    }
    out.push(rec);
    return out;
}

fn script_slot_known_lock(string k) -> bool {
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

fn script_hash_key_slot(string k) -> string {
    if k == "pre_install_hash" {
        return "pre_install";
    }
    if k == "post_install_hash" {
        return "post_install";
    }
    if k == "pre_update_hash" {
        return "pre_update";
    }
    if k == "post_update_hash" {
        return "post_update";
    }
    return "";
}

fn script_slot_list() -> Vec<string> {
    let out: Vec<string> = Vec::new();
    out.push("pre_install");
    out.push("post_install");
    out.push("pre_update");
    out.push("post_update");
    return out;
}

fn quote(string s) -> string {
    return "'" + s + "'";
}

fn strip_quotes(string s) -> string {
    let t = match trim(s) {
        Result::Ok(x) => x,
        Result::Err(_) => s,
    };
    if len(t) >= 2 {
        if starts_with(t, "'") {
            if ends_with(t, "'") {
                return match slice(t, 1, len(t) - 1) {
                    Result::Ok(inner) => inner,
                    Result::Err(_) => t,
                };
            }
        }
        if starts_with(t, "\"") {
            if ends_with(t, "\"") {
                return match slice(t, 1, len(t) - 1) {
                    Result::Ok(inner) => inner,
                    Result::Err(_) => t,
                };
            }
        }
    }
    return t;
}

fn parse_kv_line(string line) -> Result<(string, string), string> {
    if contains(line, "=") == false {
        raise "expected key = value";
    }
    let parts = match split(line, "=") {
        Result::Ok(p) => p,
        Result::Err(_) => raise "split failed",
    };
    if len(parts) < 2 {
        raise "expected key = value";
    }
    let key = match trim(parts[0]) {
        Result::Ok(t) => t,
        Result::Err(_) => parts[0],
    };
    let rhs = parts[1];
    let i = 2;
    while i < len(parts) {
        rhs = rhs + "=" + parts[i];
        i = i + 1;
    }
    return (key, strip_quotes(rhs));
}

fn cmp_str(string a, string b) -> int {
    if a == b {
        return 0;
    }
    let ab = to_bytes(a);
    let bb = to_bytes(b);
    let i = 0;
    let lim = len(ab);
    if len(bb) < lim {
        lim = len(bb);
    }
    while i < lim {
        if ab[i] < bb[i] {
            return 0 - 1;
        }
        if ab[i] > bb[i] {
            return 1;
        }
        i = i + 1;
    }
    if len(ab) < len(bb) {
        return 0 - 1;
    }
    if len(ab) > len(bb) {
        return 1;
    }
    return 0;
}

fn sort_packages(Vec<string> packages) -> Vec<string> {
    let out: Vec<string> = Vec::new();
    let i = 0;
    while i < len(packages) {
        out.push(packages[i]);
        i = i + 1;
    }
    let n = len(out);
    let a = 1;
    while a < n {
        let j = a;
        while j > 0 {
            if cmp_str(lock_pkg_name(out[j - 1]), lock_pkg_name(out[j])) <= 0 {
                break;
            }
            let tmp = out[j - 1];
            out[j - 1] = out[j];
            out[j] = tmp;
            j = j - 1;
        }
        a = a + 1;
    }
    return out;
}

fn sort_names(Vec<string> names) -> Vec<string> {
    let out: Vec<string> = Vec::new();
    let i = 0;
    while i < len(names) {
        out.push(names[i]);
        i = i + 1;
    }
    let n = len(out);
    let a = 1;
    while a < n {
        let j = a;
        while j > 0 {
            if cmp_str(out[j - 1], out[j]) <= 0 {
                break;
            }
            let tmp = out[j - 1];
            out[j - 1] = out[j];
            out[j] = tmp;
            j = j - 1;
        }
        a = a + 1;
    }
    return out;
}

fn format_allow_include(Vec<string> names) -> string {
    let sorted = sort_names(names);
    if len(sorted) == 0 {
        return "[]";
    }
    let out = "[";
    let i = 0;
    while i < len(sorted) {
        if i > 0 {
            out = out + ", ";
        }
        out = out + quote(sorted[i]);
        i = i + 1;
    }
    return out + "]";
}

fn parse_string_array(string value) -> Result<Vec<string>, string> {
    let t = match trim(value) {
        Result::Ok(x) => x,
        Result::Err(_) => value,
    };
    if starts_with(t, "[") == false {
        raise "corrupt coil.lock: expected allow_include array";
    }
    if ends_with(t, "]") == false {
        raise "corrupt coil.lock: expected allow_include array";
    }
    let inner = slice(t, 1, len(t) - 1)?;
    let pieces = match split(inner, ",") {
        Result::Ok(p) => p,
        Result::Err(_) => raise "split allow_include failed",
    };
    let out: Vec<string> = Vec::new();
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
        let name = strip_quotes(piece);
        if len(name) == 0 {
            continue;
        }
        let seen = false;
        let j = 0;
        while j < len(out) {
            if out[j] == name {
                seen = true;
            }
            j = j + 1;
        }
        if seen == false {
            out.push(name);
        }
    }
    return out;
}

fn lock_set_script_path(Vec<string> scripts, string slot, string path) -> Vec<string> {
    let old = lock_find_script(scripts, slot);
    let h = "";
    if len(old) > 0 {
        h = lock_script_hash(old);
    }
    return lock_upsert_script(scripts, make_lock_script(slot, path, h));
}

fn lock_set_script_hash(Vec<string> scripts, string slot, string hash) -> Vec<string> {
    let old = lock_find_script(scripts, slot);
    let p = "";
    if len(old) > 0 {
        p = lock_script_path(old);
    }
    return lock_upsert_script(scripts, make_lock_script(slot, p, hash));
}

fn scripts_have_any(Vec<string> scripts) -> bool {
    let i = 0;
    while i < len(scripts) {
        if len(lock_script_path(scripts[i])) > 0 {
            return true;
        }
        if len(lock_script_hash(scripts[i])) > 0 {
            return true;
        }
        i = i + 1;
    }
    return false;
}

fn lock_serialize_all(
    Vec<string> packages,
    Vec<string> allow_include,
    Vec<string> scripts,
) -> string {
    let sorted = sort_packages(packages);
    let out = "# spool lockfile v1
# This file is generated by spool. Do not edit packages by hand.
# [hooks] allow_include is the consumer allowlist for include-hooks.
# [scripts] stores current-project lifecycle path/hash (not a [[package]] row).

";
    if len(allow_include) > 0 {
        out = out + "[hooks]
";
        out = out + "allow_include = " + format_allow_include(allow_include) + "

";
    }
    if scripts_have_any(scripts) {
        out = out + "[scripts]
";
        let slots = script_slot_list();
        let si = 0;
        while si < len(slots) {
            let slot = slots[si];
            si = si + 1;
            let rec = lock_find_script(scripts, slot);
            if len(rec) == 0 {
                continue;
            }
            let p = lock_script_path(rec);
            let h = lock_script_hash(rec);
            if len(p) > 0 {
                out = out + slot + " = " + quote(p) + "
";
            }
            if len(h) > 0 {
                out = out + slot + "_hash = " + quote(h) + "
";
            }
        }
        out = out + "
";
    }
    let i = 0;
    while i < len(sorted) {
        let p = sorted[i];
        i = i + 1;
        out = out + "[[package]]
";
        out = out + "name = " + quote(lock_pkg_name(p)) + "
";
        out = out + "git = " + quote(lock_pkg_git(p)) + "
";
        out = out + "tag = " + quote(lock_pkg_tag(p)) + "
";
        out = out + "rev = " + quote(lock_pkg_rev(p)) + "
";
        out = out + "content_hash = " + quote(lock_pkg_hash(p)) + "
";
        let hp = lock_pkg_hook_path(p);
        let hh = lock_pkg_hook_hash(p);
        if len(hp) > 0 {
            out = out + "hook_path = " + quote(hp) + "
";
        }
        if len(hh) > 0 {
            out = out + "hook_hash = " + quote(hh) + "
";
        }
        out = out + "
";
    }
    return out;
}

fn lock_serialize_full(Vec<string> packages, Vec<string> allow_include) -> string {
    let empty: Vec<string> = Vec::new();
    return lock_serialize_all(packages, allow_include, empty);
}

fn lock_serialize(Vec<string> packages) -> string {
    let empty: Vec<string> = Vec::new();
    return lock_serialize_full(packages, empty);
}

fn finish_pkg(
    string name,
    string git,
    string tag,
    string rev,
    string hash,
    string hook_path,
    string hook_hash,
) -> Result<string, string> {
    if len(name) == 0 {
        raise "corrupt coil.lock: package missing name";
    }
    if len(git) == 0 {
        raise "corrupt coil.lock: package missing git";
    }
    if len(rev) == 0 {
        raise "corrupt coil.lock: package missing rev";
    }
    if len(hash) == 0 {
        raise "corrupt coil.lock: package missing content_hash";
    }
    return make_git_pkg_hook(name, git, tag, rev, hash, hook_path, hook_hash);
}

fn lock_parse_all(string source) -> Result<(Vec<string>, Vec<string>, Vec<string>), string> {
    let lines = match split(source, "\n") {
        Result::Ok(ls) => ls,
        Result::Err(_) => raise "split lock failed",
    };
    let out: Vec<string> = Vec::new();
    let allow: Vec<string> = Vec::new();
    let scripts: Vec<string> = Vec::new();
    let in_pkg = false;
    let in_hooks = false;
    let in_scripts = false;
    let name = "";
    let git = "";
    let tag = "";
    let rev = "";
    let hash = "";
    let hook_path = "";
    let hook_hash = "";
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
        if line == "[hooks]" {
            if in_pkg {
                let pkg = finish_pkg(name, git, tag, rev, hash, hook_path, hook_hash)?;
                out.push(pkg);
            }
            in_pkg = false;
            in_hooks = true;
            in_scripts = false;
            continue;
        }
        if line == "[scripts]" {
            if in_pkg {
                let pkg = finish_pkg(name, git, tag, rev, hash, hook_path, hook_hash)?;
                out.push(pkg);
            }
            in_pkg = false;
            in_hooks = false;
            in_scripts = true;
            continue;
        }
        if line == "[[package]]" {
            if in_pkg {
                let pkg = finish_pkg(name, git, tag, rev, hash, hook_path, hook_hash)?;
                out.push(pkg);
            }
            in_pkg = true;
            in_hooks = false;
            in_scripts = false;
            name = "";
            git = "";
            tag = "";
            rev = "";
            hash = "";
            hook_path = "";
            hook_hash = "";
            continue;
        }
        if in_hooks {
            let kv = parse_kv_line(line)?;
            let (k, v) = kv;
            if k == "allow_include" {
                allow = parse_string_array(v)?;
            } else {
                raise format("corrupt coil.lock: unknown key %s", k);
            }
            continue;
        }
        if in_scripts {
            let kv = parse_kv_line(line)?;
            let (k, v) = kv;
            if script_slot_known_lock(k) {
                scripts = lock_set_script_path(scripts, k, v);
            } else {
                let slot = script_hash_key_slot(k);
                if len(slot) == 0 {
                    raise format("corrupt coil.lock: unknown key %s", k);
                }
                scripts = lock_set_script_hash(scripts, slot, v);
            }
            continue;
        }
        if in_pkg == false {
            raise format("corrupt coil.lock: unexpected line: %s", line);
        }
        let kv = parse_kv_line(line)?;
        let (k, v) = kv;
        if k == "name" {
            name = v;
        } else {
            if k == "git" {
                git = v;
            } else {
                if k == "tag" {
                    tag = v;
                } else {
                    if k == "rev" {
                        rev = v;
                    } else {
                        if k == "content_hash" {
                            hash = v;
                        } else {
                            if k == "hook_path" {
                                hook_path = v;
                            } else {
                                if k == "hook_hash" {
                                    hook_hash = v;
                                } else {
                                    raise format("corrupt coil.lock: unknown key %s", k);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    if in_pkg {
        let pkg = finish_pkg(name, git, tag, rev, hash, hook_path, hook_hash)?;
        out.push(pkg);
    }
    return (out, allow, scripts);
}

fn lock_parse(string source) -> Result<Vec<string>, string> {
    let parsed = lock_parse_all(source)?;
    let (packages, allow, scripts) = parsed;
    if len(allow) == 0 {
        if len(scripts) == 0 {
            return packages;
        }
        return packages;
    }
    return packages;
}

fn lock_parse_allow(string source) -> Result<Vec<string>, string> {
    let parsed = lock_parse_all(source)?;
    let (packages, allow, scripts) = parsed;
    if len(packages) == 0 {
        if len(scripts) == 0 {
            return allow;
        }
        return allow;
    }
    return allow;
}

fn lock_parse_scripts(string source) -> Result<Vec<string>, string> {
    let parsed = lock_parse_all(source)?;
    let (packages, allow, scripts) = parsed;
    if len(packages) == 0 {
        if len(allow) == 0 {
            return scripts;
        }
        return scripts;
    }
    return scripts;
}

fn lock_write_all(
    string path,
    Vec<string> packages,
    Vec<string> allow_include,
    Vec<string> scripts,
) -> Result<int, string> {
    let body = lock_serialize_all(packages, allow_include, scripts);
    return match write_text(path, body) {
        Result::Ok(_) => 0,
        Result::Err(_) => raise format("failed to write %s", path),
    };
}

fn lock_read_scripts_or_empty(string path) -> Result<Vec<string>, string> {
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
        Result::Err(_) => raise format("missing coil.lock: failed to read %s", path),
    };
    return lock_parse_scripts(body)?;
}

fn lock_write_full(string path, Vec<string> packages, Vec<string> allow_include) -> Result<int, string> {
    let scripts = lock_read_scripts_or_empty(path)?;
    return lock_write_all(path, packages, allow_include, scripts)?;
}

fn lock_read_allow_or_empty(string path) -> Result<Vec<string>, string> {
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
        Result::Err(_) => raise format("missing coil.lock: failed to read %s", path),
    };
    return lock_parse_allow(body)?;
}

fn lock_write(string path, Vec<string> packages) -> Result<int, string> {
    let allow = lock_read_allow_or_empty(path)?;
    return lock_write_full(path, packages, allow)?;
}

fn lock_read(string path) -> Result<Vec<string>, string> {
    let body = match read_text(path) {
        Result::Ok(s) => s,
        Result::Err(_) => raise format("missing coil.lock: failed to read %s", path),
    };
    return lock_parse(body)?;
}

fn lock_find(Vec<string> packages, string name) -> string {
    let i = 0;
    while i < len(packages) {
        if lock_pkg_name(packages[i]) == name {
            return packages[i];
        }
        i = i + 1;
    }
    return "";
}

fn lock_read_or_empty(string path) -> Result<Vec<string>, string> {
    let present = match exists(path) {
        Result::Ok(v) => v,
        Result::Err(_) => false,
    };
    if present == false {
        let empty: Vec<string> = Vec::new();
        return empty;
    }
    return lock_read(path)?;
}

fn lock_write_scripts(string path, Vec<string> scripts) -> Result<int, string> {
    let packages = lock_read_or_empty(path)?;
    let allow = lock_read_allow_or_empty(path)?;
    return lock_write_all(path, packages, allow, scripts)?;
}

fn lock_add_allow_include(string path, string pkg) -> Result<int, string> {
    if len(pkg) == 0 {
        raise "missing package name";
    }
    let packages = lock_read_or_empty(path)?;
    let allow = lock_read_allow_or_empty(path)?;
    let seen = false;
    let i = 0;
    while i < len(allow) {
        if allow[i] == pkg {
            seen = true;
        }
        i = i + 1;
    }
    if seen == false {
        allow.push(pkg);
    }
    return lock_write_full(path, packages, allow)?;
}

fn lock_upsert(Vec<string> packages, string pkg) -> Vec<string> {
    let name = lock_pkg_name(pkg);
    let old = lock_find(packages, name);
    if len(old) > 0 {
        if len(lock_pkg_hook_path(pkg)) == 0 {
            if len(lock_pkg_hook_hash(pkg)) == 0 {
                pkg = lock_pkg_with_hook(pkg, lock_pkg_hook_path(old), lock_pkg_hook_hash(old));
            }
        }
    }
    let out: Vec<string> = Vec::new();
    let i = 0;
    while i < len(packages) {
        if lock_pkg_name(packages[i]) != name {
            out.push(packages[i]);
        }
        i = i + 1;
    }
    out.push(pkg);
    return out;
}

fn lock_hashes_match(Vec<string> packages, Vec<(string, string)> expected) -> bool {
    let i = 0;
    while i < len(packages) {
        let p = packages[i];
        i = i + 1;
        let n = lock_pkg_name(p);
        let h = lock_pkg_hash(p);
        let found = false;
        let j = 0;
        while j < len(expected) {
            let (en, eh) = expected[j];
            if en == n {
                found = true;
                if eh != h {
                    return false;
                }
            }
            j = j + 1;
        }
        if found == false {
            return false;
        }
    }
    return true;
}
