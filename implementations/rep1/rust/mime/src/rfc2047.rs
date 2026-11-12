//! RFC 2047 encoded words and the whitespace rules for decoding them.

use crate::charset;
use crate::scan::{is_blank, quoted_string, skip_comment, strip_blanks};
use crate::transfer::{decode_base64, hex_pair};

/// Tries to recognise an encoded word starting at `chars[i]`.
///
/// Returns the index just past the word and its decoded text.
pub fn encoded_word(chars: &[char], i: usize) -> Option<(usize, String)> {
    if chars.get(i) != Some(&'=') || chars.get(i + 1) != Some(&'?') {
        return None;
    }
    let j = i + 2 + chars[i + 2..].iter().position(|&c| c == '?')?;
    let charset_field = &chars[i + 2..j];
    if charset_field.is_empty() || charset_field.iter().any(|&c| is_blank(c)) {
        return None;
    }
    let enc = *chars.get(j + 1)?;
    if !matches!(enc, 'Q' | 'q' | 'B' | 'b') || chars.get(j + 2) != Some(&'?') {
        return None;
    }
    let m = j + 3 + chars.get(j + 3..)?.iter().position(|&c| c == '?')?;
    let text = &chars[j + 3..m];
    if text.iter().any(|&c| is_blank(c)) || chars.get(m + 1) != Some(&'=') {
        return None;
    }

    let field: String = charset_field.iter().collect();
    let name = field.split('*').next().unwrap_or("");
    let name = charset::normalize_name(name);
    let name = if name.is_empty() { "us-ascii".to_string() } else { name };

    let text: String = text.iter().collect();
    let bytes = if enc == 'Q' || enc == 'q' {
        decode_q(&text)
    } else {
        decode_base64(text.as_bytes())
    };
    Some((m + 2, charset::decode(&bytes, &name)))
}

/// Q-decodes the text of an encoded word.
fn decode_q(text: &str) -> Vec<u8> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'_' => {
                out.push(b' ');
                i += 1;
            }
            b'=' => {
                if let Some(v) = hex_pair(&bytes[i + 1..]) {
                    out.push(v);
                    i += 3;
                } else {
                    out.push(b'=');
                    i += 1;
                }
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    out
}

#[derive(Debug, PartialEq)]
enum Item {
    Encoded(String),
    Space(String),
    Literal(String),
}

/// Joins items: blanks between two encoded words vanish.
fn assemble(items: &[Item]) -> String {
    let mut out = String::new();
    for (k, item) in items.iter().enumerate() {
        match item {
            Item::Encoded(s) | Item::Literal(s) => out.push_str(s),
            Item::Space(s) => {
                let before = k > 0 && matches!(items[k - 1], Item::Encoded(_));
                let after = matches!(items.get(k + 1), Some(Item::Encoded(_)));
                if !(before && after) {
                    out.push_str(s);
                }
            }
        }
    }
    strip_blanks(&out).to_string()
}

/// Appends a blank to the current whitespace run, starting a new item if the
/// previous item is not an open run (a comment's space is an item of its own).
fn push_space(items: &mut Vec<Item>, open_run: &mut bool, c: char) {
    match items.last_mut() {
        Some(Item::Space(s)) if *open_run => s.push(c),
        _ => items.push(Item::Space(c.to_string())),
    }
    *open_run = true;
}

fn push_literal(items: &mut Vec<Item>, c: char) {
    if let Some(Item::Literal(s)) = items.last_mut() {
        s.push(c);
    } else {
        items.push(Item::Literal(c.to_string()));
    }
}

fn scan(v: &str, display: bool) -> String {
    let chars: Vec<char> = v.chars().collect();
    let mut items: Vec<Item> = Vec::new();
    let mut open_run = false;
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if let Some((end, text)) = encoded_word(&chars, i) {
            items.push(Item::Encoded(text));
            open_run = false;
            i = end;
        } else if display && c == '(' {
            i = skip_comment(&chars, i);
            items.push(Item::Space(" ".to_string()));
            open_run = false;
        } else if display && c == '"' {
            let (text, next) = quoted_string(&chars, i);
            items.push(Item::Literal(text));
            open_run = false;
            i = next;
        } else if is_blank(c) {
            push_space(&mut items, &mut open_run, c);
            i += 1;
        } else {
            push_literal(&mut items, c);
            open_run = false;
            i += 1;
        }
    }
    assemble(&items)
}

/// Decodes encoded words in an unstructured header value.
pub fn decode_unstructured(v: &str) -> String {
    scan(v, false)
}

/// Like [`decode_unstructured`], but also drops comments (leaving one space)
/// and takes quoted strings literally. Used for address display names.
pub fn decode_display(v: &str) -> String {
    scan(v, true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unstructured_examples() {
        let cases = [
            ("=?utf-8?Q?caf=C3=A9?=", "café"),
            ("=?utf-8?Q?a?=   =?utf-8?Q?b?=", "ab"),
            ("x =?utf-8?Q?a?= y", "x a y"),
            ("=?utf-8?Q?a?=b", "ab"),
            ("=?iso-8859-1?Q?caf=E9?=", "café"),
            ("=?windows-1252?Q?smart=92quote?=", "smart\u{2019}quote"),
            ("=?utf-8?B?SsO2cmc=?=", "Jörg"),
            ("=?utf-8*en?Q?hi?=", "hi"),
            ("=?utf-8?X?hi?=", "=?utf-8?X?hi?="),
            ("  plain    spaced   text  ", "plain    spaced   text"),
            ("=?utf-8?Q?a?= \t =?utf-8?Q?b?= \t c", "ab \t c"),
        ];
        for (input, want) in cases {
            assert_eq!(decode_unstructured(input), want, "{input:?}");
        }
    }

    #[test]
    fn display_examples() {
        assert_eq!(decode_display("John Q. Public "), "John Q. Public");
        assert_eq!(decode_display("\"Doe, John\" "), "Doe, John");
        assert_eq!(decode_display("=?utf-8?B?SsO2cmc=?= "), "Jörg");
        assert_eq!(decode_display("John (the third) Public "), "John   Public");
        assert_eq!(decode_display("=?utf-8?Q?a?= (c) =?utf-8?Q?b?= "), "a   b");
    }

    #[test]
    fn malformed_words() {
        assert_eq!(decode_unstructured("=?utf-8?Q?a b?="), "=?utf-8?Q?a b?=");
        assert_eq!(decode_unstructured("=??Q?a?="), "=??Q?a?=");
        assert_eq!(decode_unstructured("=?utf-8?Q?a?"), "=?utf-8?Q?a?");
        assert_eq!(decode_unstructured("=?utf-8?Q??="), "");
        assert_eq!(decode_unstructured("=?x?q?a=zz?="), "a=zz");
    }
}
