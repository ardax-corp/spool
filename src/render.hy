// Render `coil test --json` / `coil mutate --json` NDJSON events (stdin) as a
// short report. Runs as `spool __render <test|infect> <color|plain>` at the
// end of a pipe, so results show up while coil is still running.
use io::{stdin, read, wait_readable, from_bytes as io_from_bytes};
use term::{print, println};
use string::{format};
use text::{split};
use json::{Json, JsonValue};

fn emit_raw(string s) {
    print(s);
}

fn emit(string s) {
    println(s);
}

/// Next line from `s` without its LF; `None` at EOF. A read that fails
/// while coil has not written yet is a would-block: wait and retry
/// (io::sync::read_line returns that error instead, dropping the partial
/// line). Three failures in a row after waiting end the input.
fn next_line(Stream s) -> Option<string> {
    let acc: Vec<byte> = Vec::new();
    let one: Vec<byte> = Vec::new();
    one.push(0);
    let lf: byte = "\n";
    let fails = 0;
    let eof = false;
    while eof == false {
        let n = match read(s, one) {
            Result::Ok(got) => match got {
                Option::Some(k) => k,
                Option::None => -1,
            },
            Result::Err(_) => 0,
        };
        if n < 0 {
            eof = true;
            continue;
        }
        if n == 0 {
            fails = fails + 1;
            if fails > 2 {
                eof = true;
                continue;
            }
            match wait_readable(s) {
                Result::Ok(_) => 0,
                Result::Err(_) => 0,
            };
            continue;
        }
        fails = 0;
        if one[0] == lf {
            return Option::Some(match io_from_bytes(acc) {
                Result::Ok(t) => t,
                Result::Err(_) => "",
            });
        }
        acc.push(one[0]);
    }
    if len(acc) == 0 {
        return Option::None;
    }
    return Option::Some(match io_from_bytes(acc) {
        Result::Ok(t) => t,
        Result::Err(_) => "",
    });
}

// ---- styling ----------------------------------------------------------------

fn paint(bool color, string code, string s) -> string {
    if color == false || len(s) == 0 {
        return s;
    }
    return "\x1b[" + code + "m" + s + "\x1b[0m";
}

fn green(bool c, string s) -> string {
    return paint(c, "32", s);
}

fn red(bool c, string s) -> string {
    return paint(c, "31", s);
}

fn yellow(bool c, string s) -> string {
    return paint(c, "33", s);
}

fn dim(bool c, string s) -> string {
    return paint(c, "2", s);
}

fn bold(bool c, string s) -> string {
    return paint(c, "1", s);
}

/// Pass / fail marker, uncolored: symbols in color mode, words otherwise.
fn sym(bool c, bool ok) -> string {
    if c {
        if ok {
            return "✓";
        }
        return "✗";
    }
    if ok {
        return "ok  ";
    }
    return "FAIL";
}

/// `sym` in green or red.
fn mark(bool c, bool ok) -> string {
    if ok {
        return green(c, sym(c, ok));
    }
    return red(c, sym(c, ok));
}

fn plural(int n, string word) -> string {
    if n == 1 {
        return format("%i %s", n, word);
    }
    return format("%i %ss", n, word);
}

/// "87.5%" with one decimal, from integer counts ("-" when total is 0).
fn percent(int hit, int total) -> string {
    if total == 0 {
        return "-";
    }
    // Two statements: coil groups `a * b / c` as `a * (b / c)`.
    let scaled = hit * 1000;
    let tenths = scaled / total;
    return format("%i.%i", tenths / 10, tenths % 10) + "%";
}

/// Green at 80% and up, yellow from 50%, red below.
fn graded(bool c, int hit, int total) -> string {
    let p = percent(hit, total);
    if total == 0 {
        return dim(c, p);
    }
    if hit * 100 >= total * 80 {
        return green(c, p);
    }
    if hit * 100 >= total * 50 {
        return yellow(c, p);
    }
    return red(c, p);
}

fn pad_left(string s, int width) -> string {
    let out = s;
    while len(out) < width {
        out = " " + out;
    }
    return out;
}

/// Each line of `text` behind `prefix` (a trailing newline adds no line).
fn print_block(bool c, string prefix, string text) {
    let lines = match split(text, "\n") {
        Result::Ok(v) => v,
        Result::Err(_) => {
            emit(prefix + text);
            return;
        },
    };
    let n = len(lines);
    if n > 0 && lines[n - 1] == "" {
        n = n - 1;
    }
    let i = 0;
    while i < n {
        emit(dim(c, prefix) + lines[i]);
        i = i + 1;
    }
}

// ---- event fields (absent or mistyped fields read as empty) ----------------

fn str_at(JsonValue v, string key) -> string {
    return match v.get(key) {
        Option::Some(x) => match x.as_str() {
            Option::Some(s) => s,
            Option::None => "",
        },
        Option::None => "",
    };
}

fn int_at(JsonValue v, string key) -> int {
    return match v.get(key) {
        Option::Some(x) => match x.as_int() {
            Option::Some(n) => n,
            Option::None => 0,
        },
        Option::None => 0,
    };
}

fn bool_at(JsonValue v, string key) -> bool {
    return match v.get(key) {
        Option::Some(x) => match x.as_bool() {
            Option::Some(b) => b,
            Option::None => false,
        },
        Option::None => false,
    };
}

/// A number as text (`min_score` may be an int or a float).
fn num_text(JsonValue v, string key) -> string {
    return match v.get(key) {
        Option::Some(x) => match x.as_int() {
            Option::Some(n) => format("%i", n),
            Option::None => match x.as_float() {
                Option::Some(f) => format("%f", f),
                Option::None => "",
            },
        },
        Option::None => "",
    };
}

// Render state, shared by the event handlers (a Vec so updates stick).
fn st_exit() -> int {
    return 0;
}

fn st_events() -> int {
    return 1;
}

fn st_planned() -> int {
    return 2;
}

fn st_done() -> int {
    return 3;
}

fn st_progress() -> int {
    return 4;
}

// ---- shared events ---------------------------------------------------------

/// Erase the live progress line before printing a normal line.
fn clear_progress(Vec<int> st) {
    if st[st_progress()] == 1 {
        emit_raw("\r\x1b[2K");
        st[st_progress()] = 0;
    }
}

fn on_error(bool c, Vec<int> st, JsonValue v) {
    clear_progress(st);
    emit(red(c, "error: ") + str_at(v, "message"));
    st[st_exit()] = 1;
}

// ---- coil test -------------------------------------------------------------

fn on_test_start(bool c, JsonValue v) {
    let seed = str_at(v, "seed");
    let order = "sorted order";
    if len(seed) > 0 {
        order = "seed " + seed;
    }
    emit(dim(c, format("running %s · %s · %s", plural(int_at(v, "files"), "file"), order,
        plural(int_at(v, "jobs"), "job"))));
}

fn on_test_case(bool c, JsonValue k) {
    let ok = bool_at(k, "ok");
    let output = str_at(k, "output");
    if ok && len(output) == 0 {
        return;
    }
    let line = "      " + mark(c, ok) + " " + str_at(k, "name");
    if bool_at(k, "timed_out") {
        line = line + yellow(c, " (timed out)");
    }
    emit(line);
    let reason = str_at(k, "reason");
    if len(reason) > 0 {
        print_block(c, "        ", red(c, reason));
    }
    if len(output) > 0 {
        print_block(c, "        │ ", output);
    }
}

fn on_test_file(bool c, JsonValue v) {
    let ok = bool_at(v, "ok");
    let passed = int_at(v, "passed");
    let failed = int_at(v, "failed");
    let file = str_at(v, "file");
    if ok {
        emit("  " + mark(c, true) + " " + file + dim(c, format(" (%i)", passed)));
    } else {
        emit("  " + mark(c, false) + " " + bold(c, file)
            + red(c, format(" (%i of %i failed)", failed, passed + failed)));
    }
    let message = str_at(v, "message");
    if len(message) > 0 {
        print_block(c, "      ", message);
    }
    let diagnostics = str_at(v, "diagnostics");
    if len(diagnostics) > 0 {
        print_block(c, "      ", diagnostics);
    }
    let cases = match v.get("cases") {
        Option::Some(x) => x,
        Option::None => {
            return;
        },
    };
    let i = 0;
    let more = true;
    while more {
        match cases.at(i) {
            Option::Some(k) => {
                on_test_case(c, k);
            },
            Option::None => {
                more = false;
            },
        };
        i = i + 1;
    }
}

fn on_test_coverage(bool c, JsonValue cov) {
    let hit = int_at(cov, "hit");
    let total = int_at(cov, "total");
    let lcov = str_at(cov, "lcov");
    let line = "coverage " + graded(c, hit, total) + dim(c, format(" (%i/%i lines)", hit, total));
    if len(lcov) > 0 {
        line = line + dim(c, " → " + lcov);
    }
    emit("");
    emit(line);
    let files = match cov.get("files") {
        Option::Some(x) => x,
        Option::None => {
            return;
        },
    };
    let i = 0;
    let more = true;
    while more {
        match files.at(i) {
            Option::Some(f) => {
                let h = int_at(f, "hit");
                let t = int_at(f, "total");
                let pct = graded(c, h, t);
                let pad = pad_left("", 7 - len(percent(h, t)));
                emit("  " + pad + pct + "  " + str_at(f, "file") + dim(c, format("  %i/%i", h, t)));
            },
            Option::None => {
                more = false;
            },
        };
        i = i + 1;
    }
}

fn on_test_summary(bool c, Vec<int> st, JsonValue v) {
    let passed = int_at(v, "passed");
    let failed = int_at(v, "failed");
    let total = int_at(v, "total");
    let seed = str_at(v, "seed");
    emit("");
    if bool_at(v, "ok") {
        let line = green(c, sym(c, true) + " " + plural(total, "test") + " passed");
        if len(seed) > 0 {
            line = line + dim(c, " · seed " + seed);
        }
        emit(line);
    } else {
        emit(red(c, sym(c, false) + format(" %i of %s failed", failed, plural(total, "test")))
            + dim(c, format(" · %i passed", passed)));
        if len(seed) > 0 {
            emit(dim(c, "  rerun in this order: spool test --seed " + seed));
        }
        st[st_exit()] = 1;
    }
    match v.get("coverage") {
        Option::Some(cov) => {
            if cov.is_object() {
                on_test_coverage(c, cov);
            }
        },
        Option::None => {},
    };
}

fn on_test_event(bool c, Vec<int> st, string ev, JsonValue v) -> bool {
    if ev == "start" {
        on_test_start(c, v);
        return false;
    }
    if ev == "file" {
        on_test_file(c, v);
        return false;
    }
    if ev == "error" {
        on_error(c, st, v);
        return false;
    }
    if ev == "summary" {
        on_test_summary(c, st, v);
        return true;
    }
    return false;
}

// ---- coil mutate (spool infect) ---------------------------------------------

fn show_progress(bool c, Vec<int> st) {
    if c == false || st[st_planned()] == 0 {
        return;
    }
    emit_raw("\r\x1b[2K" + dim(c, format("  %i/%i mutants", st[st_done()], st[st_planned()])));
    st[st_progress()] = 1;
}

fn on_mutant(bool c, Vec<int> st, JsonValue v) {
    st[st_done()] = st[st_done()] + 1;
    let status = str_at(v, "status");
    let label = "";
    if status == "survived" {
        label = red(c, "survived ");
    }
    if status == "no_coverage" {
        label = yellow(c, "untested ");
    }
    if len(label) == 0 {
        show_progress(c, st);
        return;
    }
    clear_progress(st);
    emit(format("  %s %s  `%s` → `%s`  ", label, bold(c, format("%s:%i", str_at(v, "file"),
        int_at(v, "line"))), str_at(v, "from"), str_at(v, "to"))
        + dim(c, "[" + str_at(v, "operator") + "]"));
    show_progress(c, st);
}

fn on_infect_summary(bool c, Vec<int> st, JsonValue v) {
    clear_progress(st);
    let killed = int_at(v, "killed");
    let timed_out = int_at(v, "timed_out");
    let survived = int_at(v, "survived");
    let untested = int_at(v, "no_coverage");
    let unviable = int_at(v, "unviable");
    let caught = killed + timed_out;
    emit("");
    emit(bold(c, "mutation score ") + graded(c, caught, caught + survived)
        + dim(c, format(" · %i killed · %i timed out · %i survived · %i untested · %i unviable",
            killed, timed_out, survived, untested, unviable)));
    if survived > 0 {
        emit(dim(c, "  survivors are edits no test noticed: tighten the assertions around them"));
    }
    if bool_at(v, "ok") == false {
        emit(red(c, "  score is below --min-score " + num_text(v, "min_score")));
        st[st_exit()] = 1;
    }
}

fn on_infect_event(bool c, Vec<int> st, string ev, JsonValue v) -> bool {
    if ev == "baseline" {
        emit(dim(c, "infect: running the test suite for a baseline…"));
        return false;
    }
    if ev == "plan" {
        st[st_planned()] = int_at(v, "mutants");
        emit(format("infect: %s in %s", plural(int_at(v, "mutants"), "mutant"),
            plural(int_at(v, "files"), "file"))
            + dim(c, format(" · %i covered · %s", int_at(v, "covered"), plural(int_at(v, "jobs"), "job"))));
        return false;
    }
    if ev == "mutant" {
        on_mutant(c, st, v);
        return false;
    }
    if ev == "error" {
        on_error(c, st, v);
        return false;
    }
    if ev == "summary" {
        on_infect_summary(c, st, v);
        return true;
    }
    return false;
}

// ---- driver ----------------------------------------------------------------

/// Read events from stdin until EOF; returns the process exit code.
fn render_events(string kind, bool color) -> Result<int, string> {
    let st: Vec<int> = Vec::new();
    let n = 0;
    while n < 5 {
        st.push(0);
        n = n + 1;
    }
    let codec = Json::strict();
    let input = stdin();
    let summary = false;
    let done = false;
    while done == false {
        match next_line(input) {
            Option::None => {
                done = true;
            },
            Option::Some(line) => {
                match codec.decode_str(line) {
                    Result::Ok(v) => {
                        st[st_events()] = st[st_events()] + 1;
                        let ev = str_at(v, "event");
                        let last = false;
                        if kind == "test" {
                            last = on_test_event(color, st, ev, v);
                        } else {
                            last = on_infect_event(color, st, ev, v);
                        }
                        if last {
                            summary = true;
                        }
                    },
                    Result::Err(_) => {
                        // Not an event (stray stdout from coil): show as is.
                        clear_progress(st);
                        if len(line) > 0 {
                            emit(line);
                        }
                    },
                };
            },
        };
    }
    clear_progress(st);
    if summary == false {
        // An `error` event already said what went wrong.
        if st[st_exit()] != 0 {
            return st[st_exit()];
        }
        if st[st_events()] == 0 {
            raise "coil reported no results (it needs `--json` support; use --plain for its own output)";
        }
        raise "coil stopped before reporting a result";
    }
    return st[st_exit()];
}
