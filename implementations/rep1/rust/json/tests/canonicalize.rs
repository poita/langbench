//! Integration tests for the public library API.

use json_canon::{canonicalize, parse, ErrorKind, Value, MAX_DEPTH};

fn ok(input: &str) -> String {
    canonicalize(input.as_bytes()).unwrap_or_else(|e| panic!("{input:?} rejected: {e}"))
}

fn bad(input: &[u8]) {
    assert!(canonicalize(input).is_err(), "{:?} accepted", String::from_utf8_lossy(input));
}

#[test]
fn worked_examples() {
    assert_eq!(ok(r#"{ "b": [1, 2.50, 1E+3], "a": "héllo\/", "b": null }"#), r#"{"a":"héllo/","b":null}"#);
    assert_eq!(
        ok(r#"["😀", -0, 1e-007, 0.0, 1e-0, "tab\tquote\"nul\u0000 A\u0041"]"#),
        r#"["😀",-0,1e-7,0.0,1e0,"tab\tquote\"nul\u0000 AA"]"#
    );
    assert_eq!(ok(r#""\u007f\/\u2028\uD83D\uDE00""#), "\"\u{7f}/\u{2028}😀\"");
    assert_eq!(
        ok("{\"\\uE000\":1,\"😀\":2,\"\\uFFFF\":3,\"Z\":4}"),
        "{\"Z\":4,\"😀\":2,\"\u{E000}\":1,\"\u{FFFF}\":3}"
    );
}

#[test]
fn number_normalization() {
    for (i, o) in [
        ("1E5", "1e5"), ("1e+05", "1e5"), ("1e-007", "1e-7"), ("1e-0", "1e0"),
        ("1E+00", "1e0"), ("-0.0", "-0.0"), ("0e0", "0e0"), ("2.5E-000789", "2.5e-789"),
        ("1.50", "1.50"), ("-0", "-0"),
        ("123456789012345678901234567890", "123456789012345678901234567890"),
    ] {
        assert_eq!(ok(i), o);
    }
}

#[test]
fn invalid_numbers() {
    for s in ["01", "+1", "-", "1.", ".5", "1e", "1e+", "1E+-5", "1e5e5", "0x1", "- 1", "1 .5", "-01", "\u{662}", "NaN", "Infinity", "-Infinity"] {
        bad(s.as_bytes());
    }
}

#[test]
fn invalid_structure() {
    for s in ["", "  ", "[1,]", "{\"a\":1,}", "[,1]", "[1 2]", "{\"a\" 1}", "{a:1}", "{1:2}", "'a'", "True", "nul", "[1] x", "[1]\0", "\u{c}1", "\u{a0}1", "/*c*/1", "[", "{", "{\"a\"", "{\"a\":", "tru"] {
        bad(s.as_bytes());
    }
}

#[test]
fn strings() {
    for s in [r#""\x""#, r#""\u12""#, r#""\ud800""#, r#""\ud800\u0041""#, r#""\ud800\ue000""#, r#""\ud800\udbff""#, r#""\udc00""#, "\"a\tb\"", "\"a\nb\"", "[\"\\", r#""\u00G0""#, "\"\u{ff11}\"x"] {
        bad(s.as_bytes());
    }
    assert_eq!(ok(r#""\u00e9\u00E9""#), "\"éé\"");
    assert_eq!(ok("\"\\u001F\\u0000\""), "\"\\u001f\\u0000\"");
    bad(r#""\uFF11""#.replace("FF11", "\u{ff11}000").as_bytes());
}

#[test]
fn utf8_and_bom() {
    bad(b"\xEF\xBB\xBF[]");
    bad(b"\"\xC0\x80\"");
    bad(b"\"\xED\xA0\x80\"");
    bad(b"\"\xF4\x90\x80\x80\"");
    bad(b"\"\xE2\x82\"");
    bad(b"[1]\xFF");
    assert_eq!(canonicalize(b" \t\r\n[ ]\n").unwrap(), "[]");
}

#[test]
fn duplicates_validated_and_last_wins() {
    assert_eq!(ok(r#"{"a":1,"b":2,"a":3,"\u0061":4}"#), r#"{"a":4,"b":2}"#);
    bad(br#"{"a":"\uD800","a":1}"#);
    bad(br#"{"a":[1,],"a":1}"#);
}

#[test]
fn depth_limit() {
    let nest = |n: usize| format!("{}{}", "[".repeat(n), "]".repeat(n));
    assert_eq!(ok(&nest(MAX_DEPTH)), nest(MAX_DEPTH));
    let e = canonicalize(nest(MAX_DEPTH + 1).as_bytes()).unwrap_err();
    assert_eq!(e.kind, ErrorKind::TooDeep);
    bad(format!("{}{{}}{}", "[".repeat(MAX_DEPTH), "]".repeat(MAX_DEPTH)).as_bytes());
    bad("[".repeat(100_000).as_bytes());
    // Over-deep value under a repeated key is still invalid.
    bad(format!("{{\"a\":{},\"a\":1}}", nest(MAX_DEPTH + 1)).as_bytes());
}

#[test]
fn parse_tree() {
    assert_eq!(
        parse(b"{\"a\":[null,true,1e+2,\"x\"],\"a\":0}").unwrap(),
        Value::Object(vec![
            ("a".into(), Value::Array(vec![Value::Null, Value::Bool(true), Value::Number("1e2".into()), Value::String("x".into())])),
            ("a".into(), Value::Number("0".into())),
        ])
    );
}
