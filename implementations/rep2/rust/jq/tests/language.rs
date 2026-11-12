//! Behavioural tests of the filter language through the library API.

use jq_subset::{Filter, Value};

/// Runs `filter` on `doc`; returns the compact output lines, with a final
/// `"error"` entry if evaluation failed.
fn run(filter: &str, doc: &str) -> Vec<String> {
    let f = Filter::parse(filter).unwrap_or_else(|e| panic!("parse {filter:?}: {e}"));
    let v = Value::parse_json(doc).unwrap();
    let mut out = Vec::new();
    let r = f.run(&v, |x| out.push(x.to_json()));
    if r.is_err() {
        out.push("error".into());
    }
    out
}

fn check(filter: &str, doc: &str, expected: &[&str]) {
    assert_eq!(run(filter, doc), expected, "filter: {filter}  input: {doc}");
}

#[test]
fn paths() {
    check(".a.b", r#"{"a":{"b":7}}"#, &["7"]);
    check(".a.b.c", r#"{"a":null}"#, &["null"]);
    check(r#"."a b""#, r#"{"a b":1}"#, &["1"]);
    check(".[-1], .[5]", "[1,2,3]", &["3", "null"]);
    check(".[1:], .[:-1], .[-2:5]", "[1,2,3]", &["[2,3]", "[1,2]", "[2,3]"]);
    check(".[1:3]", r#""héllo""#, &[r#""él""#]);
    check(".[]", r#"{"b":1,"a":2}"#, &["1", "2"]);
    check(".[0]", "null", &["null"]);
    check(".[null]", "null", &["error"]);
    check(".[]", "null", &["error"]);
    check("([1,2],[3,4])[(0,1)]", "null", &["1", "3", "2", "4"]);
}

#[test]
fn generators_and_order() {
    check("[(1,2) + (10,20)]", "null", &["[11,12,21,22]"]);
    check("{a:(1,2), b:(3,4)}", "null", &[r#"{"a":1,"b":3}"#, r#"{"a":1,"b":4}"#, r#"{"a":2,"b":3}"#, r#"{"a":2,"b":4}"#]);
    check("1, 2 | . * 10", "null", &["10", "20"]);
    check("false and error, true or error", "null", &["false", "true"]);
    check("(true,false) and (true,false)", "null", &["true", "false", "false"]);
}

#[test]
fn optional_operator() {
    check("[.[] | .a?]", r#"[{"a":1},5,null]"#, &["[1,null]"]);
    check(".a.b?", "5", &["error"]);
    check(".a?", "5", &[]);
    check("[([1],2,[3])[0]?]", "null", &["[1,3]"]);
    check("[(1,[2],3)[]?]", "null", &["[2]"]);
    check("[(1,2,error,3)?]", "null", &["[1,2]"]);
    check("(1,2)? | error", "null", &["error"]);
    check("[.[] | tonumber?]", r#"["1","x","2.5"]"#, &["[1,2.5]"]);
    check("(.a.b)?", "5", &[]);
}

#[test]
fn bindings_and_reduce() {
    check(".[] as $x | $x * 2", "[1,2]", &["2", "4"]);
    check(". as $x | [1,2] | map(. + $x)", "10", &["[11,12]"]);
    check("1 as $x | 2 as $x | $x", "null", &["2"]);
    check("reduce .[] as $o ({}; . + {($o.k): $o.v})", r#"[{"k":"b","v":1},{"k":"a","v":2},{"k":"b","v":3}]"#, &[r#"{"b":3,"a":2}"#]);
    check("reduce .[] as $x (0; . + $x)", "[1,2,3]", &["6"]);
    check("reduce empty as $x (0; . + 1)", "null", &["0"]);
    check("reduce .[] as $x (0; empty)", "[1]", &["null"]);
    check("reduce .[] as $x ([]; . + [$x * 2])", "[1,2]", &["[2,4]"]);
}

#[test]
fn objects_and_key_order() {
    check("{a:1,b:2,a:3}", "null", &[r#"{"a":3,"b":2}"#]);
    check(r#"{"z":1,"a":2} + {"m":3,"z":9}"#, "null", &[r#"{"z":9,"a":2,"m":3}"#]);
    check(r#"{"a":{"x":1,"y":2},"b":1} * {"a":{"y":3,"z":4},"b":{"c":1}}"#, "null", &[r#"{"a":{"x":1,"y":3,"z":4},"b":{"c":1}}"#]);
    check("{a,b}", r#"{"b":2,"a":1}"#, &[r#"{"a":1,"b":2}"#]);
    check(r#"{"a b"}"#, r#"{"a b":1}"#, &[r#"{"a b":1}"#]);
    check("1 as $x | {$x}", "null", &[r#"{"x":1}"#]);
    check("{(1):2}", "null", &["error"]);
    check("keys", r#"{"b":1,"a":2,"é":3,"Z":4}"#, &[r#"["Z","a","b","é"]"#]);
    check(". == {\"b\":2,\"a\":1}", r#"{"a":1,"b":2}"#, &["true"]);
    check("{a: .x | tostring}", r#"{"x":1}"#, &[r#"{"a":"1"}"#]);
}

#[test]
fn arithmetic() {
    check("-7 % 3, 7 % -3, 5.5 % 2", "null", &["-1", "1", "1"]);
    check("5 % 0.5", "null", &["error"]);
    check("1 / 0", "null", &["error"]);
    check(r#""a,b,,c" / ",", "" / ",", "abc" / """#, "null", &[r#"["a","b","","c"]"#, "[]", r#"["a","b","c"]"#]);
    check(r#""ab" * 3, 0 * "x", "x" * -1"#, "null", &[r#""ababab""#, r#""""#, "null"]);
    check("[1,2,3,2] - [2]", "null", &["[1,3]"]);
    check("null + 1, 1 + null, null + null", "null", &["1", "1", "null"]);
    check("1 - -1, 2 * -3, -(1 + 2), -.a", r#"{"a":4}"#, &["2", "-6", "-3", "-4"]);
    check("1 == (1.5 - 0.5)", "null", &["true"]);
    check(r#""a" + 1"#, "null", &["error"]);
    check("1 -1", "null", &["0"]);
    check("0.1 + 0.2 == 0.3, 3086419725308.5 * 1", "null", &["false", "3086419725308.5"]);
}

#[test]
fn ordering() {
    check("sort", r#"[{"a":1},[2],"b",1,true,false,null,"a",[1,2],[]]"#, &[r#"[null,false,true,1,"a","b",[],[1,2],[2],{"a":1}]"#]);
    check("sort", r#"["z","é","Z","a",""]"#, &[r#"["","Z","a","z","é"]"#]);
    check("sort", r#"[{"b":1},{"a":2},{"a":1,"b":0},{"a":1}]"#, &[r#"[{"a":1},{"a":2},{"a":1,"b":0},{"b":1}]"#]);
    check("[1 < 2, \"a\" < 1, null < false, [] > {}, {} > []]", "null", &["[true,false,true,false,true]"]);
}

#[test]
fn builtins() {
    check("length", r#"[null,-3,"héé",[1,2],{"a":1}]"#, &["5"]);
    check(".[] | length", r#"[null,-3,"héé",[1,2],{"a":1}]"#, &["0", "3", "3", "2", "1"]);
    check("true | length", "null", &["error"]);
    check("has(\"a\"), has(\"z\")", r#"{"a":1}"#, &["true", "false"]);
    check("has(1.5), has(-1), has(2)", "[1,2]", &["true", "false", "false"]);
    check("has(\"a\")", "null", &["false"]);
    check("has(0)", r#"{"a":1}"#, &["error"]);
    check("map(type)", r#"[null,true,1,"a",[],{}]"#, &[r#"["null","boolean","number","string","array","object"]"#]);
    check("add", "[1,2,3]", &["6"]);
    check("add", r#"["a","b"]"#, &[r#""ab""#]);
    check("add", "[[1],[2,3]]", &["[1,2,3]"]);
    check("add", "[]", &["null"]);
    check("add", r#"{"a":1,"b":2}"#, &["3"]);
    check("add", r#"[1,"a"]"#, &["error"]);
    check("add", "[null,1,null]", &["1"]);
    check("map(select(. > 1))", "[1,2,3]", &["[2,3]"]);
    check("map(. * 2)", r#"{"a":1,"b":2}"#, &["[2,4]"]);
    check("sort_by(.a, .b)", r#"[{"a":2,"b":1},{"a":1,"b":2},{"a":1,"b":1}]"#, &[r#"[{"a":1,"b":1},{"a":1,"b":2},{"a":2,"b":1}]"#]);
    check("sort_by(-.n)", r#"[{"n":0},{"n":2},{"n":1}]"#, &[r#"[{"n":2},{"n":1},{"n":0}]"#]);
    check("group_by(.k) | map(length)", r#"[{"k":"b"},{"k":"a"},{"k":"b"}]"#, &["[1,2]"]);
    check("unique", "[3,1,3,2,1]", &["[1,2,3]"]);
    check("reverse", "[1,2]", &["[2,1]"]);
    check("reverse", "null", &["[]"]);
    check("reverse", r#""ab""#, &["error"]);
    check("min, max", "[2,1,3]", &["1", "3"]);
    check("min, max", "[]", &["null", "null"]);
    check("tostring", "[1,\"a\"]", &[r#""[1,\"a\"]""#]);
    check("tostring", r#""x""#, &[r#""x""#]);
    check("tonumber", r#""-2.5""#, &["-2.5"]);
    check("tonumber", r#""abc""#, &["error"]);
    check("tonumber", r#""""#, &["error"]);
    check("tonumber", r#""nan""#, &["error"]);
    check("error(null)", "null", &["error"]);
    check("error(empty), 1", "null", &["1"]);
    check("empty", "1", &[]);
    check("1, error, 2", "null", &["1", "error"]);
    check("not", "0", &["false"]);
    check("if . then 1 elif . == null then 2 else 3 end", "null", &["2"]);
    check("if . > 1 then \"big\" end", "1", &["1"]);
    check("if (true, false) then 1 else 2 end", "null", &["1", "2"]);
}

#[test]
fn min_max_ties() {
    // Equal-but-differently-ordered objects: min keeps the first, max the last.
    check("min", r#"[{"a":1,"b":2},{"b":2,"a":1}]"#, &[r#"{"a":1,"b":2}"#]);
    check("max", r#"[{"a":1,"b":2},{"b":2,"a":1}]"#, &[r#"{"b":2,"a":1}"#]);
}

#[test]
fn parse_errors_are_reported() {
    assert!(Filter::parse("1 +").is_err());
    assert!(Filter::parse("(1").is_err());
    assert!(Filter::parse("nosuchfunction").is_err());
    assert!(Filter::parse("if 1 then 2").is_err());
}

#[test]
fn library_api() {
    let f = Filter::parse(".[] | select(. > 1)").unwrap();
    let doc = Value::parse_json("[1,2,3]").unwrap();
    let out = f.collect(&doc).unwrap();
    assert_eq!(out, vec![Value::from(2i64), Value::from(3i64)]);
    // Partial results are delivered before an error.
    let f = Filter::parse("1, error, 2").unwrap();
    let mut seen = Vec::new();
    assert!(f.run(&Value::Null, |v| seen.push(v)).is_err());
    assert_eq!(seen.len(), 1);
}

#[test]
fn deep_nesting_and_large_input() {
    let mut doc = String::new();
    for _ in 0..64 {
        doc.push_str("{\"a\":[");
    }
    doc.push('1');
    for _ in 0..64 {
        doc.push_str("]}");
    }
    let path: String = ".a[0]".repeat(64);
    check(&path, &doc, &["1"]);

    let big: String = format!("[{}]", (0..20000).map(|i| i.to_string()).collect::<Vec<_>>().join(","));
    check("add", &big, &["199990000"]);
    check("reduce .[] as $x ({}; . + {($x|tostring): $x}) | length", &big, &["20000"]);
}
