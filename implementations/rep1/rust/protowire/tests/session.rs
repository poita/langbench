//! End-to-end tests of the batch protocol through the library API.

use protowire::session::run;

fn out(input: &str) -> String {
    String::from_utf8(run(input.as_bytes())).unwrap()
}

#[test]
fn spec_example_1() {
    let input = "message Inner { sint32 v = 1; }\nmessage Outer {\n  int32 a = 1;\n  string b = 2;\n  repeated int32 c = 3;\n  Inner d = 4;\n}\n--\nencode Outer {a: 1, b: \"x\", c: [1, 2], d: {v: -5}}\ndecode Outer 08011201781a02010222020809\nencode Outer {d: {}, c: [], a: 0}\ndecode Outer 3800\ndecode Outer 08ff\n";
    assert_eq!(out(input), "08011201781a02010222020809\n{a: 1, b: \"x\", c: [1, 2], d: {v: -5}}\n2200\n{}\nerror\n");
}

#[test]
fn spec_example_2() {
    let input = "message M { uint64 u = 1; sint64 s = 2; fixed32 f = 3; bytes y = 4; repeated bool bs = 5; bool k = 6; }\n--\ndecode M 08ffffffffffffffffff0110ff011dffffffff2202000f2a03010001\ndecode M 3002\ndecode M 3d000000\nencode M {k: true, y: x\"cafe\", s: -128, u: 18446744073709551615}\nencode M {u: -1}";
    assert_eq!(
        out(input),
        "{u: 18446744073709551615, s: -128, f: 4294967295, y: x\"000f\", bs: [true, false, true]}\n{k: true}\nerror\n08ffffffffffffffffff0110ff012202cafe3001\nerror\n"
    );
}

#[test]
fn spec_example_3() {
    let input = "message P { repeated int32 r = 1; P p = 2; string s = 3; }\n--\ndecode P 0801080212020803120208041a0322095c\ndecode P 1b08011c0805\ndecode P 1b08011400\n";
    assert_eq!(out(input), "{r: [1, 2], p: {r: [3, 4]}, s: \"\\\"\\t\\\\\"}\n{r: [5]}\nerror\n");
}

#[test]
fn empty_encoding_is_an_empty_line() {
    assert_eq!(out("message M { int32 a = 1; }\n--\nencode M {}\nencode M {a: 0}\n"), "\n\n");
}

#[test]
fn no_requests_no_output() {
    assert_eq!(out("message M { int32 a = 1; }\n--\n"), "");
    assert_eq!(out("message M { int32 a = 1; }\n--"), "");
}

#[test]
fn hex_strictness() {
    let input = "message M { int32 a = 1; }\n--\ndecode M \ndecode M 082A\ndecode M 0\ndecode M 08 01\ndecode M 0801\n";
    assert_eq!(out(input), "error\nerror\nerror\nerror\n{a: 1}\n");
}

#[test]
fn round_trips_every_scalar_type() {
    let schema = "message M { int32 a = 1; int64 b = 2; uint32 c = 3; uint64 d = 4; sint32 e = 5; sint64 f = 6; bool g = 7; fixed32 h = 8; fixed64 i = 9; sfixed32 j = 10; sfixed64 k = 11; string l = 12; bytes m = 13; repeated sint32 n = 14; repeated sfixed64 o = 15; }";
    let text = r#"{a: -2147483648, b: -9223372036854775808, c: 4294967295, d: 18446744073709551615, e: -2147483648, f: -9223372036854775808, g: true, h: 4294967295, i: 18446744073709551615, j: -2147483648, k: -9223372036854775808, l: "h\x00\x7fé", m: x"00ff", n: [0, -1, 2147483647], o: [-1, 0]}"#;
    let encoded = out(&format!("{schema}\n--\nencode M {text}\n"));
    let hex = encoded.trim_end();
    let decoded = out(&format!("{schema}\n--\ndecode M {hex}\n"));
    assert_eq!(decoded.trim_end(), text);
}

#[test]
fn large_repeated_field_is_fast() {
    let n = 100_000;
    let list: Vec<String> = (0..n).map(|i| i.to_string()).collect();
    let text = format!("{{c: [{}]}}", list.join(", "));
    let schema = "message M { repeated int32 c = 1; }";
    let hex = out(&format!("{schema}\n--\nencode M {text}\n"));
    let back = out(&format!("{schema}\n--\ndecode M {}\n", hex.trim_end()));
    assert_eq!(back.trim_end(), text);
}
