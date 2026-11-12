//! Behavioural tests of the filter language through the public library API.

use jqlite::{run_str, Filter, Value};

/// Runs `filter` on `doc`; returns the output lines, with a trailing "error" line if evaluation failed.
fn run(filter: &str, doc: &str) -> Vec<String> {
    let (mut lines, err) = run_str(filter, doc).expect("filter and document should parse");
    if err.is_some() {
        lines.push("error".to_string());
    }
    lines
}

fn one(filter: &str, doc: &str) -> String {
    let r = run(filter, doc);
    assert_eq!(r.len(), 1, "expected one output for {filter}: {r:?}");
    r.into_iter().next().unwrap()
}

#[test]
fn identity_and_paths() {
    assert_eq!(one(".", r#"{"b":1,"a":[1,2.5]}"#), r#"{"b":1,"a":[1,2.5]}"#);
    assert_eq!(one(".a.b", r#"{"a":{"b":7}}"#), "7");
    assert_eq!(one(".a.b.c", r#"{"a":null}"#), "null");
    assert_eq!(one(r#"."a b""#, r#"{"a b":1}"#), "1");
    assert_eq!(one(".[-1]", "[1,2,3]"), "3");
    assert_eq!(one(".[5]", "[1,2,3]"), "null");
    assert_eq!(one(".[1:]", "[1,2,3]"), "[2,3]");
    assert_eq!(one(".[:-1]", "[1,2,3]"), "[1,2]");
    assert_eq!(one(".[1:2]", r#""héllo""#), r#""é""#);
}

#[test]
fn generator_order() {
    assert_eq!(one("[(1,2) + (10,20)]", "null"), "[11,12,21,22]");
    assert_eq!(run("{a:(1,2), b:(3,4)}", "null"), [
        r#"{"a":1,"b":3}"#, r#"{"a":1,"b":4}"#, r#"{"a":2,"b":3}"#, r#"{"a":2,"b":4}"#
    ]);
    assert_eq!(run("([1,2],[3,4])[(0,1)]", "null"), ["1", "3", "2", "4"]);
    assert_eq!(run("1, 2 | . * 10", "null"), ["10", "20"]);
}

#[test]
fn optional_has_two_meanings() {
    let doc = r#"[{"a":{"b":1}},{"a":5},3]"#;
    assert_eq!(one("[.[] | .a?]", doc), r#"[{"b":1},5]"#);
    assert_eq!(run(".[] | .a.b?", doc), ["1", "error"]);
    assert_eq!(one("[(1,2,error,3)?]", "null"), "[1,2]");
    assert_eq!(run("(1,2)? | error", "null"), ["error"]);
    assert_eq!(one("[([1],2,[3])[0]?]", "null"), "[1,3]");
    assert_eq!(one("[(1,[2],3)[]?]", "null"), "[2]");
    assert_eq!(one("[.a??]", "[]"), "[]");
}

#[test]
fn errors_stop_evaluation_after_partial_output() {
    assert_eq!(run("1, error, 2", "null"), ["1", "error"]);
    assert_eq!(run("error(null)", "null"), ["error"]);
    assert_eq!(run("error(empty)", "null"), Vec::<String>::new());
    assert_eq!(run(".[0]", r#"{"a":1}"#), ["error"]);
    assert_eq!(run(".[]", "null"), ["error"]);
    assert_eq!(run("1 / 0", "null"), ["error"]);
    assert_eq!(run("5 % 0.5", "null"), ["error"]);
    assert_eq!(run("-.", r#""x""#), ["error"]);
}

#[test]
fn arithmetic() {
    assert_eq!(one("null + 1", "null"), "1");
    assert_eq!(one(r#""a" + "b""#, "null"), r#""ab""#);
    assert_eq!(one("[1,2,1,3] - [1]", "null"), "[2,3]");
    assert_eq!(one(r#""ab" * 3"#, "null"), r#""ababab""#);
    assert_eq!(one(r#"0 * "ab""#, "null"), r#""""#);
    assert_eq!(one(r#""ab" * -1"#, "null"), "null");
    assert_eq!(one(r#""a,b,,c" / ",""#, "null"), r#"["a","b","","c"]"#);
    assert_eq!(one(r#""" / ",""#, "null"), "[]");
    assert_eq!(one(r#""abc" / """#, "null"), r#"["a","b","c"]"#);
    assert_eq!(one("-7 % 3", "null"), "-1");
    assert_eq!(one("7 % -3", "null"), "1");
    assert_eq!(one("5.5 % 2", "null"), "1");
    assert_eq!(one("1 - -1", "null"), "2");
    assert_eq!(one("1 -1", "null"), "0");
    assert_eq!(one("1 == (1.5 - 0.5)", "null"), "true");
    assert_eq!(one("3 / 4", "null"), "0.75");
}

#[test]
fn object_key_order() {
    assert_eq!(one("{a:1,b:2,a:3}", "null"), r#"{"a":3,"b":2}"#);
    assert_eq!(one(r#"{"z":1,"a":2} + {"m":3,"z":9}"#, "null"), r#"{"z":9,"a":2,"m":3}"#);
    assert_eq!(
        one(r#"{"a":{"x":1,"y":2},"b":1} * {"a":{"y":3,"z":4},"b":{"c":1}}"#, "null"),
        r#"{"a":{"x":1,"y":3,"z":4},"b":{"c":1}}"#
    );
    assert_eq!(one("keys", r#"{"b":1,"a":2,"é":3,"Z":4}"#), r#"["Z","a","b","é"]"#);
    assert_eq!(one("9 as $v | {a, $v, (\"k\"+\"2\"): 1}", r#"{"a":5}"#), r#"{"a":5,"v":9,"k2":1}"#);
    assert_eq!(run("{(1): 2}", "null"), ["error"]);
}

#[test]
fn bindings_and_reduce() {
    assert_eq!(run(".[] as $x | $x * 2", "[1,2]"), ["2", "4"]);
    assert_eq!(one("1 as $x | 2 as $x | $x", "null"), "2");
    assert_eq!(one("(1 + 2) as $x | $x", "null"), "3");
    assert_eq!(one("reduce .[] as $x (0; . + $x)", "[1,2,3]"), "6");
    assert_eq!(one("reduce empty as $x (5; . + 1)", "null"), "5");
    assert_eq!(one("reduce .[] as $x (0; empty)", "[1]"), "null");
    assert_eq!(
        one("reduce .[] as $o ({}; . + {($o.k): $o.v})", r#"[{"k":"b","v":1},{"k":"a","v":2},{"k":"b","v":3}]"#),
        r#"{"b":3,"a":2}"#
    );
}

#[test]
fn conditionals_and_logic() {
    assert_eq!(run("if . then 1 else 2 end", "null"), ["2"]);
    assert_eq!(run("if . == 1 then \"a\" elif . == 2 then \"b\" else \"c\" end", "2"), [r#""b""#]);
    assert_eq!(run("if false then 1 end", "7"), ["7"]);
    assert_eq!(run("if (true,false) then 1 else 2 end", "null"), ["1", "2"]);
    assert_eq!(one("false and error", "null"), "false");
    assert_eq!(one("true or error", "null"), "true");
    assert_eq!(run("(true,false) and (true,false)", "null"), ["true", "false", "false"]);
    assert_eq!(one("[0, \"\", [], {}] | map(not)", "null"), "[false,false,false,false]");
}

#[test]
fn ordering_and_sorting() {
    assert_eq!(
        one("sort", r#"[{"a":1},[1],"b","a",2,1,true,false,null]"#),
        r#"[null,false,true,1,2,"a","b",[1],{"a":1}]"#
    );
    assert_eq!(one("sort_by(.a, .b)", r#"[{"a":2,"b":1},{"a":1,"b":2},{"a":1,"b":1}]"#),
        r#"[{"a":1,"b":1},{"a":1,"b":2},{"a":2,"b":1}]"#);
    assert_eq!(one("group_by(.k) | map([.[0].k, length])", r#"[{"k":"b"},{"k":"a"},{"k":"b"}]"#), r#"[["a",1],["b",2]]"#);
    assert_eq!(one("unique", "[3,1,3,2,1]"), "[1,2,3]");
    assert_eq!(one("[min, max]", "[3,1,2]"), "[1,3]");
    assert_eq!(one("[min, max]", "[]"), "[null,null]");
    assert_eq!(one("min", r#"[{"a":1,"b":2},{"b":2,"a":1}]"#), r#"{"a":1,"b":2}"#);
    assert_eq!(one("max", r#"[{"a":1,"b":2},{"b":2,"a":1}]"#), r#"{"b":2,"a":1}"#);
    assert_eq!(one("{\"a\":1,\"b\":2} == {\"b\":2,\"a\":1}", "null"), "true");
    assert_eq!(one("{\"a\":1} < {\"a\":2}", "null"), "true");
    assert_eq!(one("{\"a\":2} < {\"b\":1}", "null"), "true");
}

#[test]
fn builtins() {
    assert_eq!(one("map(length)", r#"["ab",[1],{"a":1},null,-3]"#), "[2,1,1,0,3]");
    assert_eq!(one("[has(\"a\"), has(\"z\")]", r#"{"a":null}"#), "[true,false]");
    assert_eq!(one("[has(0), has(2), has(-1), has(1.5)]", "[1,2]"), "[true,false,false,true]");
    assert_eq!(one("has(\"a\")", "null"), "false");
    assert_eq!(one("map(type)", r#"[null,true,1,"s",[],{}]"#), r#"["null","boolean","number","string","array","object"]"#);
    assert_eq!(one("add", r#"[[1],[2]]"#), "[1,2]");
    assert_eq!(one("add", r#"["a","b"]"#), r#""ab""#);
    assert_eq!(one("add", "[]"), "null");
    assert_eq!(one("add", r#"{"a":1,"b":2}"#), "3");
    assert_eq!(run("add", "[1,\"a\"]"), ["error"]);
    assert_eq!(one("map(tostring)", r#"["a",1,[1,"x"],null]"#), r#"["a","1","[1,\"x\"]","null"]"#);
    assert_eq!(one("map(tonumber)", r#"["12","-2.5",3]"#), "[12,-2.5,3]");
    assert_eq!(one("[.[] | tonumber?]", r#"["1","x",""]"#), "[1]");
    assert_eq!(one("reverse", "null"), "[]");
    assert_eq!(one("map(select(. > 1))", "[1,2,3]"), "[2,3]");
    assert_eq!(one("map(.+1)", r#"{"a":1,"b":2}"#), "[2,3]");
    assert_eq!(run("length", "true"), ["error"]);
    assert_eq!(run("keys", "null"), ["error"]);
}

#[test]
fn output_formatting() {
    assert_eq!(one(".", r#""a\u0001\u007f\n\"\\/é😀""#), r#""a\u0001\u007f\n\"\\/é😀""#);
    assert_eq!(one(".", r#""😀""#), r#""😀""#);
    assert_eq!(one(".", "[0.1,1000000000000,-12,0.125,3086419725308.5]"), "[0.1,1000000000000,-12,0.125,3086419725308.5]");
}

#[test]
fn library_api() {
    let f = Filter::parse(".[] | select(. > 1)").unwrap();
    let doc = Value::from_json("[1,2,3]").unwrap();
    let mut seen = Vec::new();
    f.run(&doc, |v| seen.push(v.to_string())).unwrap();
    assert_eq!(seen, ["2", "3"]);
    assert!(Filter::parse("1 +").is_err());
    assert!(Filter::parse("nosuchfunction").is_err());
    assert!(Value::from_json("[1,").is_err());
}

#[test]
fn deep_and_large_inputs() {
    let depth = 60;
    let doc = format!("{}1{}", "[".repeat(depth), "]".repeat(depth));
    assert_eq!(one(&format!("{}", ".[0]".repeat(depth)), &doc), "1");
    let items: Vec<String> = (0..20000).map(|i| i.to_string()).collect();
    let doc = format!("[{}]", items.join(","));
    assert_eq!(one("add", &doc), "199990000");
    assert_eq!(one("reduce .[] as $x ([]; . + [$x]) | length", &doc), "20000");
}
