//! Behavioural tests for the matching semantics (SPEC section 3).

use btregex::{ErrorKind, Regex};

/// Renders a result the way the CLI does: `no` or `match s e|g1|g2...`.
fn show(pattern: &str, subject: &str) -> String {
    let re = Regex::new(pattern).unwrap_or_else(|e| panic!("{pattern}: {e}"));
    match re.find(subject) {
        None => "no".to_string(),
        Some(m) => {
            let mut s = format!("match {} {}", m.start(), m.end());
            for g in 1..=re.group_count() {
                match m.group(g) {
                    Some(r) => s.push_str(&format!("|{},{}", r.start, r.end)),
                    None => s.push_str("|-"),
                }
            }
            s
        }
    }
}

fn check(cases: &[(&str, &str, &str)]) {
    for (p, s, want) in cases {
        assert_eq!(show(p, s), *want, "pattern {p:?} on {s:?}");
    }
}

#[test]
fn spec_examples() {
    check(&[
        ("(a|ab)(c|bcd)(d*)", "abcd", "match 0 4|0,1|1,4|4,4"),
        ("a*", "bbb", "match 0 0"),
        ("a*", "", "match 0 0"),
        ("^(a+)+$", "aaaa", "match 0 4|0,4"),
        ("^(a+)+$", "aaab", "no"),
        ("(a|(b))+", "ba", "match 0 2|1,2|0,1"),
        ("(a|(b))+", "ab", "match 0 2|1,2|1,2"),
        (r"[^a-c]\d{2,3}x?", "zz123xx", "match 1 6"),
        (r"[^a-c]\d{2,3}x?", "abc9", "no"),
        ("(a*)*b", "aab", "match 0 3|2,2"),
        ("(a*)*b", "ccc", "no"),
        ("x$|^(y)?z", "xz", "no"),
        ("x$|^(y)?z", "yz", "match 0 2|0,1"),
        ("x$|^(y)?z", "zzz", "match 0 1|-"),
        ("(a){0}b|(c)?(d)", "xb", "match 1 2|-|-|-"),
        ("(a){0}b|(c)?(d)", "xcd", "match 1 3|-|1,2|2,3"),
        ("(a){0}b|(c)?(d)", "d", "match 0 1|-|-|0,1"),
    ]);
}

#[test]
fn ordered_choice_beats_longest() {
    check(&[("a|ab", "ab", "match 0 1"), ("(a|ab)(c|bcd)", "abcd", "match 0 4|0,1|1,4")]);
}

#[test]
fn leftmost_beats_longer_later_match() {
    check(&[("a*", "baaa", "match 0 0"), ("a+", "baaa", "match 1 4")]);
}

#[test]
fn greedy_gives_back_one_at_a_time() {
    check(&[
        ("a*ab", "aaab", "match 0 4"),
        ("(a*)(a*)", "aaa", "match 0 3|0,3|3,3"),
    ]);
}

#[test]
fn empty_iterations() {
    check(&[
        ("(a*)*", "b", "match 0 0|0,0"),
        ("(a*)+", "b", "match 0 0|0,0"),
        ("(a*){3}", "", "match 0 0|0,0"),
        ("(a|b*)*c", "abc", "match 0 3|2,2"),
    ]);
}

#[test]
fn captures_keep_earlier_iteration_values() {
    check(&[
        ("(a|(b))+", "ba", "match 0 2|1,2|0,1"),
    ]);
}

#[test]
fn failed_paths_discard_captures() {
    // The first alternative sets group 1 and then fails.
    check(&[("(a)b|ac", "ac", "match 0 2|-"), ("((a)|b)*c", "abc", "match 0 3|1,2|0,1")]);
}

#[test]
fn counted_quantifiers() {
    check(&[
        ("a{0}", "a", "match 0 0"),
        ("a{2}", "aaa", "match 0 2"),
        ("a{2,}", "aaaa", "match 0 4"),
        ("a{1,3}", "aaaa", "match 0 3"),
        ("(ab){2}", "ababab", "match 0 4|2,4"),
        ("(a|b){3}c", "abbc", "match 0 4|2,3"),
        ("a{0,0}b", "ab", "match 1 2"),
        ("(a{2}){2}", "aaaa", "match 0 4|2,4"),
    ]);
}

#[test]
fn anchors() {
    check(&[
        ("^a", "ba", "no"),
        ("a$", "ab", "no"),
        ("a$", "ba", "match 1 2"),
        ("a^b", "ab", "no"),
        ("^$", "", "match 0 0"),
        ("^$", "a", "no"),
        ("$", "abc", "match 3 3"),
        ("(^a|b)+", "ba", "match 0 1|0,1"),
        ("(^|x)a", "xa", "match 0 2|0,1"),
    ]);
}

#[test]
fn classes_and_escapes() {
    check(&[
        ("[a-c]+", "xxabcabx", "match 2 7"),
        ("[^a-c]+", "abxyc", "match 2 4"),
        (r"[\d_-]+", "ab1_-2c", "match 2 6"),
        (r"[-a]+", "b-a-", "match 1 4"),
        (r"[a-]+", "b-a-", "match 1 4"),
        (r"[\]\\]+", "a]\\]b", "match 1 4"),
        (r"\w+", "  ab_9 ", "match 2 6"),
        (r"\W+", "ab, cd", "match 2 4"),
        (r"\s", "a b", "match 1 2"),
        (r"\S+", "  ab ", "match 2 4"),
        (r"\D+", "12ab34", "match 2 4"),
        (r"\.\*\(\)", "x.*()", "match 1 5"),
        (r"a\ b", "a b", "match 0 3"),
        ("[a^]+", "^a", "match 0 2"),
        (".", "", "no"),
        ("a.c", "a c", "match 0 3"),
    ]);
}

#[test]
fn empty_branches_and_groups() {
    check(&[
        ("a|", "b", "match 0 0"),
        ("(|b)", "b", "match 0 0|0,0"),
        ("||", "x", "match 0 0"),
        ("()", "x", "match 0 0|0,0"),
        ("", "", "match 0 0"),
        ("(a)|b", "b", "match 0 1|-"),
    ]);
}

#[test]
fn start_position_prefilter_is_transparent() {
    check(&[
        ("b+", "aaabbb", "match 3 6"),
        ("^b", "aab", "no"),
        ("b$", "baab", "match 3 4"),
        ("(x|y)z", "aaayz", "match 3 5|3,4"),
        ("x", "", "no"),
    ]);
}

#[test]
fn deep_backtracking_does_not_overflow_stack() {
    let subject = "a".repeat(10_000);
    assert_eq!(show("^.*b", &subject), "no");
    assert_eq!(show("(.)*$", &subject), "match 0 10000|9999,10000");
    assert_eq!(show("^(a|b)*c", &subject), "no");
}

#[test]
fn pathological_patterns_finish() {
    assert_eq!(show("(a*)*b", &"a".repeat(12)), "no");
    assert_eq!(show("(x+x+)+y", "xxxxxxxxxxxx"), "no");
    assert_eq!(show("(a|aa)+c", "aaaaaaaaaaaaaa"), "no");
    assert_eq!(show("a*b", &"a".repeat(1000)), "no");
}

#[test]
fn invalid_patterns_are_rejected() {
    let kind = |p: &str| Regex::new(p).unwrap_err().kind();
    assert_eq!(kind("a(b"), ErrorKind::UnclosedGroup);
    assert_eq!(kind("a)"), ErrorKind::UnmatchedCloseParen);
    assert_eq!(kind("+"), ErrorKind::DanglingQuantifier);
    assert_eq!(kind("a{2,1}"), ErrorKind::InvalidQuantifier);
    assert_eq!(kind(r"\d\q"), ErrorKind::InvalidEscape);
    assert_eq!(kind("[b-a]"), ErrorKind::InvalidRange);
    assert_eq!(kind("((((a{100}){100}){100}){100})"), ErrorKind::PatternTooLarge);
}

#[test]
fn matcher_is_reusable() {
    let re = Regex::new("(a|b)+c").unwrap();
    let mut m = re.matcher();
    for _ in 0..3 {
        assert_eq!(m.find("zzabac").unwrap().group(1), Some(4..5));
        assert!(m.find("zzab").is_none());
        assert_eq!(m.find("c"), None);
        assert_eq!(m.find("ac").unwrap().range(), 0..2);
    }
}

#[test]
fn match_accessors() {
    let re = Regex::new("(a)(b)?").unwrap();
    let m = re.find("xa").unwrap();
    assert_eq!((m.start(), m.end()), (1, 2));
    assert_eq!(m.group(0), Some(1..2));
    assert_eq!(m.group(1), Some(1..2));
    assert_eq!(m.group(2), None);
    assert_eq!(m.group(3), None);
    assert_eq!(m.group_count(), 2);
    assert!(re.is_match("a"));
}
