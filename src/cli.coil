// Tiny argv parser. Parsed items are tab records:
//   "o\t--flag\tvalue"   option with a value
//   "b\t--flag"          boolean flag
//   "p\tvalue"           positional
//   "r\tvalue"           raw argument after `--`
use string::{format};
use text::{Searchable};
use util::{tsv_field, vec_has};

fn parse_args(Vec<string> args, Vec<string> valued, Vec<string> bools) -> Result<Vec<string>, string> {
    let out: Vec<string> = Vec::new();
    let i = 0;
    let raw = false;
    while i < args.len() {
        let a = args[i];
        i = i + 1;
        if raw {
            out.push("r\t" + a);
            continue;
        }
        if a == "--" {
            raw = true;
            continue;
        }
        if a.starts_with("-") && a != "-" {
            let key = a;
            let inline = "";
            let has_inline = false;
            if a.starts_with("--") && a.contains("=") {
                let kv = match a.split_once("=") { Option::Some(p) => p, Option::None => raise "separator not found" };
                let (k, v) = kv;
                key = k;
                inline = v;
                has_inline = true;
            }
            if vec_has(valued, key) {
                if has_inline {
                    out.push("o\t" + key + "\t" + inline);
                    continue;
                }
                if i >= args.len() {
                    raise format("%s needs a value", key);
                }
                out.push("o\t" + key + "\t" + args[i]);
                i = i + 1;
                continue;
            }
            if vec_has(bools, key) && has_inline == false {
                out.push("b\t" + key);
                continue;
            }
            raise format("unknown flag %s", a);
        }
        out.push("p\t" + a);
    }
    return out;
}

fn opt(Vec<string> parsed, string key) -> string {
    let v = "";
    let i = 0;
    while i < parsed.len() {
        if tsv_field(parsed[i], 0) == "o" && tsv_field(parsed[i], 1) == key {
            v = tsv_field(parsed[i], 2);
        }
        i = i + 1;
    }
    return v;
}

fn has(Vec<string> parsed, string key) -> bool {
    let i = 0;
    while i < parsed.len() {
        if tsv_field(parsed[i], 0) == "b" && tsv_field(parsed[i], 1) == key {
            return true;
        }
        i = i + 1;
    }
    return false;
}

fn items_of(Vec<string> parsed, string kind) -> Vec<string> {
    let out: Vec<string> = Vec::new();
    let i = 0;
    while i < parsed.len() {
        if tsv_field(parsed[i], 0) == kind {
            out.push(tsv_field(parsed[i], 1));
        }
        i = i + 1;
    }
    return out;
}

fn positionals(Vec<string> parsed) -> Vec<string> {
    return items_of(parsed, "p");
}

fn raw_args(Vec<string> parsed) -> Vec<string> {
    return items_of(parsed, "r");
}

fn at_most(Vec<string> pos, int n, string usage) -> Result<int, string> {
    if pos.len() > n {
        raise format("unexpected argument %s\nusage: %s", pos[n], usage);
    }
    return 0;
}

fn strs(string a) -> Vec<string> {
    let out: Vec<string> = Vec::new();
    out.push(a);
    return out;
}

fn strs2(string a, string b) -> Vec<string> {
    let out = strs(a);
    out.push(b);
    return out;
}

fn strs3(string a, string b, string c) -> Vec<string> {
    let out = strs2(a, b);
    out.push(c);
    return out;
}

fn strs4(string a, string b, string c, string d) -> Vec<string> {
    let out = strs3(a, b, c);
    out.push(d);
    return out;
}

fn no_strs() -> Vec<string> {
    let out: Vec<string> = Vec::new();
    return out;
}
