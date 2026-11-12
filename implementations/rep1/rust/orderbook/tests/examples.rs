//! The worked examples from the specification, run through the library.

use orderbook::process;

fn check(input: &str, expected: &str) {
    let mut out = Vec::new();
    process(input, &mut out).unwrap();
    assert_eq!(String::from_utf8(out).unwrap(), expected);
}

#[test]
fn example1_fill_across_levels() {
    check(include_str!("fixtures/example1.in"), include_str!("fixtures/example1.out"));
}

#[test]
fn example2_ioc_and_rejects() {
    check(include_str!("fixtures/example2.in"), include_str!("fixtures/example2.out"));
}

#[test]
fn example3_replace_rules() {
    check(include_str!("fixtures/example3.in"), include_str!("fixtures/example3.out"));
}

#[test]
fn quantities_beyond_32_bits() {
    let mut input = String::from("12\n");
    for i in 0..10 {
        input.push_str(&format!("LIMIT s{i} SELL 7 1000000000\n"));
    }
    input.push_str("LIMIT f BUY 7 10000000001 FOK\nBOOK\n");
    let mut out = Vec::new();
    process(&input, &mut out).unwrap();
    let text = String::from_utf8(out).unwrap();
    assert!(text.contains("REJECT f\nASK 7 10000000000 10\n--\n"), "{text}");
}
