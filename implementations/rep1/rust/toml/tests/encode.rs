//! Encoder and round-trip behaviour.

use tomlcodec::{parse, tagged_json, to_toml};

fn enc(json: &str) -> String {
    to_toml(&tagged_json::from_str(json).unwrap()).unwrap()
}

#[test]
fn worked_example() {
    let json = r#"{"db":{"enabled":{"type":"bool","value":"true"},"ports":[{"type":"integer","value":"8001"},{"type":"integer","value":"8002"}]},"dob":{"type":"datetime","value":"1979-05-27T07:32:00-08:00"},"fruit":[{"name":{"type":"string","value":"apple"}},{"name":{"type":"string","value":"banana"}}],"name":{"type":"string","value":"Tom"}}"#;
    assert_eq!(
        enc(json),
        "dob = 1979-05-27T07:32:00-08:00\nname = \"Tom\"\n\n[db]\nenabled = true\nports = [8001, 8002]\n\n[[fruit]]\nname = \"apple\"\n\n[[fruit]]\nname = \"banana\"\n"
    );
}

#[test]
fn key_order_is_code_point_order() {
    let json = r#"{"é":{"type":"integer","value":"3"},"a":{"type":"integer","value":"2"},"A":{"type":"integer","value":"1"},"":{"type":"integer","value":"0"}}"#;
    assert_eq!(enc(json), "\"\" = 0\nA = 1\na = 2\n\"é\" = 3\n");
}

#[test]
fn scalar_text_is_verbatim() {
    let json = r#"{"f":{"type":"float","value":"1.0000000000000000e+00"},"n":{"type":"float","value":"nan"},"t":{"type":"time-local","value":"07:32:00.5"}}"#;
    assert_eq!(enc(json), "f = 1.0000000000000000e+00\nn = nan\nt = 07:32:00.5\n");
}

#[test]
fn mixed_arrays_stay_inline() {
    let json = r#"{"a":[{"x":{"type":"integer","value":"1"}},{"type":"integer","value":"2"}],"b":[[],[{"y":{"type":"bool","value":"true"}}]]}"#;
    assert_eq!(enc(json), "a = [{x = 1}, 2]\nb = [[], [{y = true}]]\n");
}

#[test]
fn string_escapes() {
    let json = r#"{"s":{"type":"string","value":"q\" b\\ \b\t\n\f\r \u0000 \u007f é"}}"#;
    assert_eq!(enc(json), "s = \"q\\\" b\\\\ \\b\\t\\n\\f\\r \\u0000 \\u007f é\"\n");
}

#[test]
fn empty_tables_get_headers() {
    assert_eq!(enc(r#"{"a":{"b":{}}}"#), "[a]\n\n[a.b]\n");
    assert_eq!(enc("{}"), "\n");
}

#[test]
fn round_trip_through_decoder() {
    let docs = [
        "a = 1\nb = [1, 2.5, 'x', {c = 1979-05-27}]\n[t]\n'k k' = \"v\"\n[[t.u]]\nz = true\n[[t.u]]\n[[t.u]]\nz = false\n",
        "[a.b.c]\nd = 0x10\n[a.e]\n",
        "x = \"\"\"\nmulti\nline\"\"\"\ny.z = -inf\n",
        "e = []\nf = [[]]\ng = { }\n",
    ];
    for doc in docs {
        let tree = parse(doc).unwrap();
        let toml = to_toml(&tree).unwrap();
        let again = parse(&toml).unwrap_or_else(|e| panic!("{toml}\n{e}"));
        assert_eq!(tagged_json::to_string(&again), tagged_json::to_string(&tree), "{doc}");
    }
}
