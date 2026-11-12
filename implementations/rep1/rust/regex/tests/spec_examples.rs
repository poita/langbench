//! Library-level tests of the semantics, including the worked examples.

use btregex::Regex;

/// Formats a match the way the CLI does: `match s e|gs,ge|-...` or `no`.
fn fmt(pattern: &str, subject: &str) -> String {
    let re = Regex::new(pattern).unwrap_or_else(|e| panic!("{pattern:?}: {e}"));
    match re.find(subject) {
        None => "no".to_string(),
        Some(m) => {
            let mut s = format!("match {} {}", m.start(), m.end());
            for g in 1..=m.group_count() {
                match m.get(g) {
                    Some((a, b)) => s.push_str(&format!("|{a},{b}")),
                    None => s.push_str("|-"),
                }
            }
            s
        }
    }
}

#[track_caller]
fn check(pattern: &str, subject: &str, expected: &str) {
    assert_eq!(fmt(pattern, subject), expected, "pattern {pattern:?} on {subject:?}");
}

#[test]
fn ordered_choice_and_greedy() {
    check("(a|ab)(c|bcd)(d*)", "abcd", "match 0 4|0,1|1,4|4,4");
    check("a|ab", "ab", "match 0 1");
    check("a*", "bbb", "match 0 0");
    check("a*", "", "match 0 0");
    check("a*b", "aaab", "match 0 4");
}

#[test]
fn nested_quantifiers() {
    check("^(a+)+$", "aaaa", "match 0 4|0,4");
    check("^(a+)+$", "aaab", "no");
    check("(a*)*b", "aab", "match 0 3|2,2");
    check("(a*)*b", "ccc", "no");
    check("(x+x+)+y", "xxxxxxxxxxxxxxxxxxxx", "no");
}

#[test]
fn captures_follow_successful_path() {
    check("(a|(b))+", "ba", "match 0 2|1,2|0,1");
    check("(a|(b))+", "ab", "match 0 2|1,2|1,2");
    check("(a){0}b|(c)?(d)", "xb", "match 1 2|-|-|-");
    check("(a){0}b|(c)?(d)", "xcd", "match 1 3|-|1,2|2,3");
    check("(a){0}b|(c)?(d)", "d", "match 0 1|-|-|0,1");
    check("(a*){3}", "", "match 0 0|0,0");
    // Captures set on abandoned paths are discarded.
    check("(a|ab)(c|bcd)", "abcd", "match 0 4|0,1|1,4");
}

#[test]
fn anchors() {
    check("x$|^(y)?z", "xz", "no");
    check("x$|^(y)?z", "yz", "match 0 2|0,1");
    check("x$|^(y)?z", "zzz", "match 0 1|-");
    check("a^b", "ab", "no");
    check("^", "abc", "match 0 0");
    check("$", "abc", "match 3 3");
    check("(^a|b)+", "bab", "match 0 1|0,1");
    check("(^a|b)+", "abb", "match 0 3|2,3");
}

#[test]
fn classes_and_escapes() {
    check("[^a-c]\\d{2,3}x?", "zz123xx", "match 1 6");
    check("[^a-c]\\d{2,3}x?", "abc9", "no");
    check("[a-c-e]", "-", "match 0 1");
    check("[-a]+", "a-a-", "match 0 4");
    check("[\\]\\-x]+", "a]-x", "match 1 4");
    check("\\w+\\s\\S+", "foo bar", "match 0 7");
    check("\\D+", "12ab34", "match 2 4");
    check("\\W", "ab_ c", "match 3 4");
    check("\\.\\(\\)\\ ", "a.() b", "match 1 5");
    check("[a^]+", "^a", "match 0 2");
}

#[test]
fn counted_quantifiers() {
    check("a{0}", "aaa", "match 0 0");
    check("a{0,0}b", "ab", "match 1 2");
    check("a{2}", "aaa", "match 0 2");
    check("a{2,}", "aaaa", "match 0 4");
    check("a{2,3}", "a", "no");
    check("(ab){2,3}", "ababababab", "match 0 6|4,6");
    check("(a|b){1,2}c", "abc", "match 0 3|1,2");
    check("(a?){2,4}b", "aab", "match 0 3|2,2");
}

#[test]
fn empty_iterations() {
    // The second iteration is empty and ends the loop with its captures.
    check("(a*)*", "b", "match 0 0|0,0");
    check("(a*)+", "aa", "match 0 2|2,2");
    check("(a|)+b", "aab", "match 0 3|2,2");
    check("(|a)+", "aa", "match 0 0|0,0");
}

#[test]
fn start_positions_are_scanned_in_order() {
    check("b", "abab", "match 1 2");
    check("(b)", "aaa", "no");
    check("$", "", "match 0 0");
    check("a*$", "baaa", "match 1 4");
}

#[test]
fn deep_backtracking_does_not_overflow() {
    let subject = "a".repeat(10_000);
    let re = Regex::new("(.)*b|(a|b)*$").unwrap();
    let m = re.find(&subject).unwrap();
    assert_eq!((m.start(), m.end()), (0, 10_000));
    let re = Regex::new("(a|aa)+c").unwrap();
    assert!(re.find(&"a".repeat(25)).is_none());
}

#[test]
fn compile_errors() {
    for p in ["(", "a**", "a+?", "(?:a)", "[z-a]", "a{2,1}", "\\", "*a"] {
        assert!(Regex::new(p).is_err(), "{p:?}");
    }
}
