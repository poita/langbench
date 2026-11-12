//! Decoder behaviour: valid documents, structure rules and rejections.

use tomlcodec::{parse, tagged_json, ParseError};

fn json(src: &str) -> String {
    tagged_json::to_string(&parse(src).unwrap_or_else(|e| panic!("{src:?}: {e}")))
}

fn invalid(src: &str) -> ParseError {
    parse(src).expect_err(src)
}

#[test]
fn worked_example() {
    let src = "name = \"Tom\"\ndob = 1979-05-27T07:32:00-08:00\n\n[db]\nports = [ 8001, 8002 ]\nenabled = true\n\n[[fruit]]\nname = \"apple\"\n\n[[fruit]]\nname = \"banana\"\n";
    assert_eq!(
        json(src),
        concat!(
            r#"{"db":{"enabled":{"type":"bool","value":"true"},"ports":[{"type":"integer","value":"8001"},{"type":"integer","value":"8002"}]},"#,
            r#""dob":{"type":"datetime","value":"1979-05-27T07:32:00-08:00"},"#,
            r#""fruit":[{"name":{"type":"string","value":"apple"}},{"name":{"type":"string","value":"banana"}}],"#,
            r#""name":{"type":"string","value":"Tom"}}"#
        )
    );
}

#[test]
fn empty_document() {
    assert_eq!(json(""), "{}");
    assert_eq!(json("# only a comment"), "{}");
}

#[test]
fn scalars() {
    assert_eq!(json("a = 0xFF"), r#"{"a":{"type":"integer","value":"255"}}"#);
    assert_eq!(json("a = -0"), r#"{"a":{"type":"integer","value":"0"}}"#);
    assert_eq!(json("a = 1_000"), r#"{"a":{"type":"integer","value":"1000"}}"#);
    assert_eq!(json("a = -nan"), r#"{"a":{"type":"float","value":"nan"}}"#);
    assert_eq!(
        json("a = 6.626e-34"),
        r#"{"a":{"type":"float","value":"6.6259999999999998e-34"}}"#
    );
    assert_eq!(
        json("a = 1979-05-27 # c"),
        r#"{"a":{"type":"date-local","value":"1979-05-27"}}"#
    );
    assert_eq!(
        json("a = 1979-05-27 07:32:00.100"),
        r#"{"a":{"type":"datetime-local","value":"1979-05-27T07:32:00.1"}}"#
    );
}

#[test]
fn strings() {
    let v = |src: &str| {
        parse(src).unwrap().get("s").and_then(|v| v.as_str()).unwrap().to_string()
    };
    assert_eq!(v(r#"s = "a\tb\u00e9\U0001F600\\""#), "a\tbé😀\\");
    assert_eq!(v("s = 'C:\\path'"), "C:\\path");
    assert_eq!(v("s = \"\"\"\nline1\r\nline2\"\"\""), "line1\nline2");
    assert_eq!(v("s = \"\"\"a \\\n   b\"\"\""), "a b");
    assert_eq!(v("s = \"\"\"a\"\"\"\"\""), "a\"\"");
    assert_eq!(v("s = '''\n''quoted''''"), "''quoted'");
    assert_eq!(v("s = \"\\u0000\""), "\0");
}

#[test]
fn keys_and_tables() {
    assert_eq!(
        json("a.b = 1\na.c = 2\n[x]\ny.z = 3\n[x.y.w]\nq = 4"),
        concat!(
            r#"{"a":{"b":{"type":"integer","value":"1"},"c":{"type":"integer","value":"2"}},"#,
            r#""x":{"y":{"w":{"q":{"type":"integer","value":"4"}},"z":{"type":"integer","value":"3"}}}}"#
        )
    );
    // Quoted and bare spellings of a key are the same key.
    invalid("\"a\" = 1\na = 2");
    invalid("'a' = 1\n\"a\".b = 2");
    assert_eq!(json("\"\" = 1"), r#"{"":{"type":"integer","value":"1"}}"#);
}

#[test]
fn array_of_tables_attachment() {
    let out = json("[[f]]\nn=1\n[f.p]\nc=2\n[[f.v]]\nm=3\n[[f]]\nn=4");
    assert_eq!(
        out,
        concat!(
            r#"{"f":[{"n":{"type":"integer","value":"1"},"p":{"c":{"type":"integer","value":"2"}},"#,
            r#""v":[{"m":{"type":"integer","value":"3"}}]},{"n":{"type":"integer","value":"4"}}]}"#
        )
    );
}

#[test]
fn inline_tables_and_arrays() {
    assert_eq!(
        json("a = { b = [\n 1, # c\n 2,\n], c.d = {} }"),
        concat!(
            r#"{"a":{"b":[{"type":"integer","value":"1"},{"type":"integer","value":"2"}],"#,
            r#""c":{"d":{}}}}"#
        )
    );
    assert_eq!(json("a = [1, 'x', [true], {}, ]").matches("type").count(), 3);
}

#[test]
fn crlf_line_endings() {
    assert_eq!(json("a = 1\r\n# c\r\n[t]\r\nb = 2\r\n").matches("integer").count(), 2);
}

#[test]
fn rejects_invalid_encoding_and_characters() {
    assert!(tomlcodec::parse_bytes(b"a = \"\xff\"").is_err());
    assert!(tomlcodec::parse_bytes(b"\xef\xbb\xbfa = 1").is_err());
    for src in ["a = 1\rb = 2", "# c\r", "a = \"x\ry\"", "a = \"\u{7f}\"", "# \u{1}", "a = 'x\u{0}'"] {
        invalid(src);
    }
}

#[test]
fn rejects_bad_values() {
    for src in [
        "a =", "a = 01", "a = +0x1", "a = 1__0", "a = 1.", "a = .5", "a = 1e", "a = Inf", "a = True",
        "a = 0xFFFFFFFFFFFFFFFF", "a = 9223372036854775808", "a = 1979-02-30", "a = 1979-5-01",
        "a = 07:32", "a = 24:00:00", "a = 12:00:60", "a = \"\\q\"", "a = \"\\ud800\"", "a = \"\\U00110000\"",
        "a = \"abc", "a = \"\"\"abc", "a = \"\"\"a\"\"\"\"\"\"", "a = 'abc\n'", "a = [1,,2]", "a = [,1]",
        "a = {b=1,}", "a = {b=1\n}", "a = { b = 1 } x", "a = 1 b = 2", "a = \u{0661}",
        "a = 1979-05-27 7:32:00", "= 1", "a b = 1", "a = \"x\" # \u{7f}",
    ] {
        invalid(src);
    }
}

#[test]
fn rejects_table_rule_violations() {
    for src in [
        "a = 1\na = 2",
        "a = 1\n[a]",
        "[a]\n[a]",
        "a.b = 1\n[a]",
        "[a]\nb.c = 1\n[a.b]",
        "a = {b=1}\n[a.c]",
        "a = {b=1}\na.c = 2",
        "a = {b={}}\n[a.b.c]",
        "a = [1]\n[[a]]",
        "a = [{b=1}]\n[a.c]",
        "[[a]]\n[a]",
        "[a]\n[[a]]",
        "[a.b]\n[a]\nb.c = 1\n",
        "[ [a] ]",
        "[[a] ]",
        "[ [a]]",
        "[a] x",
        "[]",
        "[a.]",
        "[a..b]",
    ] {
        invalid(src);
    }
    for src in ["[a.b]\n[a]", "[[a.b]]\n[a.b.c]\n[[a.b]]", "[ a . b ]", "[[ a . b ]]", "[x]\na.b=1\na.c=2"] {
        parse(src).unwrap_or_else(|e| panic!("{src:?}: {e}"));
    }
}

#[test]
fn error_positions() {
    let e = invalid("a = 1\nb = ?");
    assert_eq!(e.line(), 2);
    assert!(e.column() >= 5);
    assert!(!e.to_string().is_empty());
}

#[test]
fn deep_nesting() {
    // Deep documents need more stack than a test thread gets by default.
    std::thread::Builder::new()
        .stack_size(64 * 1024 * 1024)
        .spawn(|| {
            let n = 500;
            let src = format!("a = {}1{}", "[".repeat(n), "]".repeat(n));
            assert!(parse(&src).is_ok());
            let src = format!("[{}]\nx = 1", vec!["k"; n].join("."));
            assert!(parse(&src).is_ok());
            // Absurd depth is an error, not a crash.
            let src = format!("a = {}", "[".repeat(100_000));
            assert!(parse(&src).is_err());
        })
        .unwrap()
        .join()
        .unwrap();
}
