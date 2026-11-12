//! Canonical serialization of a [`Value`] tree.
//!
//! Output is written into one growing buffer in a single walk over the tree;
//! no per-subtree text is built and copied. Object members are ordered by a
//! stable sort on their keys in UTF-16 code-unit order, and for each run of
//! equal keys only the last member is written.

use crate::value::Value;
use std::cmp::Ordering;

/// Serializes `value` canonically (no whitespace, sorted unique keys,
/// minimal string escaping) and returns the UTF-8 text.
pub fn to_canonical_string(value: &Value) -> String {
    let mut out = String::new();
    write_canonical(value, &mut out);
    out
}

/// Appends the canonical serialization of `value` to `out`.
pub fn write_canonical(value: &Value, out: &mut String) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(true) => out.push_str("true"),
        Value::Bool(false) => out.push_str("false"),
        Value::Number(n) => out.push_str(n),
        Value::String(s) => write_string(s, out),
        Value::Array(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_canonical(item, out);
            }
            out.push(']');
        }
        Value::Object(members) => write_object(members, out),
    }
}

/// Compares two strings by their UTF-16 code-unit sequences.
///
/// This differs from UTF-8 byte order only for supplementary characters
/// versus U+E000–U+FFFF, so the common byte prefix is skipped and the first
/// differing characters are compared as UTF-16 units.
pub fn cmp_utf16(a: &str, b: &str) -> Ordering {
    let (ab, bb) = (a.as_bytes(), b.as_bytes());
    let common = ab.iter().zip(bb).take_while(|(x, y)| x == y).count();
    // Back up to a character boundary so both tails start at a whole char.
    let mut start = common;
    while !a.is_char_boundary(start) {
        start -= 1;
    }
    a[start..].encode_utf16().cmp(b[start..].encode_utf16())
}

fn write_object(members: &[(String, Value)], out: &mut String) {
    let mut order: Vec<&(String, Value)> = members.iter().collect();
    order.sort_by(|x, y| cmp_utf16(&x.0, &y.0)); // stable
    out.push('{');
    let mut first = true;
    for (i, m) in order.iter().enumerate() {
        // Within a run of equal keys, only the last (latest in input) is kept.
        if i + 1 < order.len() && order[i + 1].0 == m.0 {
            continue;
        }
        if !first {
            out.push(',');
        }
        first = false;
        write_string(&m.0, out);
        out.push(':');
        write_canonical(&m.1, out);
    }
    out.push('}');
}

/// Writes `s` as a JSON string, escaping only `"`, `\` and U+0000–U+001F.
pub fn write_string(s: &str, out: &mut String) {
    out.push('"');
    let mut run = 0;
    for (i, &b) in s.as_bytes().iter().enumerate() {
        let esc: &str = match b {
            b'"' => "\\\"",
            b'\\' => "\\\\",
            0x08 => "\\b",
            0x0C => "\\f",
            b'\n' => "\\n",
            b'\r' => "\\r",
            b'\t' => "\\t",
            0x00..=0x1F => {
                out.push_str(&s[run..i]);
                out.push_str("\\u00");
                const HEX: &[u8; 16] = b"0123456789abcdef";
                out.push(HEX[(b >> 4) as usize] as char);
                out.push(HEX[(b & 15) as usize] as char);
                run = i + 1;
                continue;
            }
            _ => continue,
        };
        out.push_str(&s[run..i]);
        out.push_str(esc);
        run = i + 1;
    }
    out.push_str(&s[run..]);
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utf16_order() {
        let order = ["", "Z", "a", "a\0", "aa", "é", "😀", "\u{E000}", "\u{FFFF}"];
        for w in order.windows(2) {
            assert_eq!(cmp_utf16(w[0], w[1]), Ordering::Less, "{:?} {:?}", w[0], w[1]);
            assert_eq!(cmp_utf16(w[1], w[0]), Ordering::Greater);
        }
        assert_eq!(cmp_utf16("😀", "😀"), Ordering::Equal);
        assert_eq!(cmp_utf16("😀a", "😁"), Ordering::Less);
    }

    #[test]
    fn escapes() {
        let mut s = String::new();
        write_string("a\"\\\u{8}\u{c}\n\r\t\u{0}\u{1f}\u{7f}/é", &mut s);
        assert_eq!(s, "\"a\\\"\\\\\\b\\f\\n\\r\\t\\u0000\\u001f\u{7f}/é\"");
    }
}
