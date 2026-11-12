//! Splitting a template source into text and tags, and tokenizing tag contents.

use std::rc::Rc;

use super::error::{Error, Result};

#[derive(Clone, Debug, PartialEq)]
pub(crate) enum Tok {
    Name(Rc<str>),
    Int(i64),
    Float(f64),
    Str(String),
    Op(&'static str),
}

pub(crate) enum Item {
    Text(String),
    /// `{{ ... }}`
    Print(Vec<Tok>),
    /// `{% ... %}`
    Stmt(Vec<Tok>),
}

fn is_ws(c: u8) -> bool {
    matches!(c, b' ' | b'\t' | b'\n' | b'\r' | b'\x0c' | b'\x0b')
}

fn trim_start_ws(s: &str) -> &str {
    s.trim_start_matches(|c: char| c.is_ascii() && is_ws(c as u8))
}

fn trim_end_ws(s: &str) -> &str {
    s.trim_end_matches(|c: char| c.is_ascii() && is_ws(c as u8))
}

const OPS: [&str; 22] = [
    "**", "//", "==", "!=", "<=", ">=", "~", "+", "-", "*", "/", "%", "<", ">", "(", ")", "[", "]",
    ",", "|", ".", "=",
];

/// Split `src` into items, applying whitespace control.
pub(crate) fn lex(src: &str) -> Result<Vec<Item>> {
    let b = src.as_bytes();
    let mut items = Vec::new();
    let mut i = 0;
    let mut lstrip_next = false;
    loop {
        // Find the next tag opener.
        let mut j = i;
        let mut found = None;
        while j + 1 < b.len() {
            if b[j] == b'{' && matches!(b[j + 1], b'{' | b'%' | b'#') {
                found = Some(b[j + 1]);
                break;
            }
            j += 1;
        }
        let text_end = if found.is_some() { j } else { b.len() };
        let mut text = &src[i..text_end];
        if lstrip_next {
            text = trim_start_ws(text);
        }
        lstrip_next = false;
        let Some(kind) = found else {
            if !text.is_empty() {
                items.push(Item::Text(text.to_string()));
            }
            return Ok(items);
        };
        let mut k = j + 2;
        if k < b.len() && b[k] == b'-' {
            text = trim_end_ws(text);
            k += 1;
        }
        if !text.is_empty() {
            items.push(Item::Text(text.to_string()));
        }
        match kind {
            b'#' => {
                // A comment ends at the first `#}`.
                let mut e = k;
                loop {
                    if e + 1 >= b.len() {
                        return Err(Error::syntax("unclosed comment"));
                    }
                    if b[e] == b'#' && b[e + 1] == b'}' {
                        break;
                    }
                    e += 1;
                }
                if e > k && b[e - 1] == b'-' {
                    lstrip_next = true;
                }
                i = e + 2;
            }
            _ => {
                let (toks, next, strip) = lex_tag(src, k, kind == b'{')?;
                items.push(if kind == b'{' {
                    Item::Print(toks)
                } else {
                    Item::Stmt(toks)
                });
                lstrip_next = strip;
                i = next;
            }
        }
    }
}

/// Tokenize a tag's content starting at `start`. Returns the tokens, the
/// position after the closer and whether the closer had a `-`.
fn lex_tag(src: &str, start: usize, is_print: bool) -> Result<(Vec<Tok>, usize, bool)> {
    let b = src.as_bytes();
    let (closer, closer_dash): (&[u8], &[u8]) = if is_print {
        (b"}}", b"-}}")
    } else {
        (b"%}", b"-%}")
    };
    let mut toks = Vec::new();
    let mut i = start;
    loop {
        while i < b.len() && is_ws(b[i]) {
            i += 1;
        }
        if i >= b.len() {
            return Err(Error::syntax("unclosed tag"));
        }
        if b[i..].starts_with(closer_dash) {
            return Ok((toks, i + 3, true));
        }
        if b[i..].starts_with(closer) {
            return Ok((toks, i + 2, false));
        }
        let c = b[i];
        if c.is_ascii_alphabetic() || c == b'_' {
            let s = i;
            while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'_') {
                i += 1;
            }
            toks.push(Tok::Name(Rc::from(&src[s..i])));
        } else if c.is_ascii_digit() {
            let s = i;
            while i < b.len() && b[i].is_ascii_digit() {
                i += 1;
            }
            if i + 1 < b.len() && b[i] == b'.' && b[i + 1].is_ascii_digit() {
                i += 1;
                while i < b.len() && b[i].is_ascii_digit() {
                    i += 1;
                }
                let f: f64 = src[s..i].parse().map_err(|_| Error::syntax("bad float"))?;
                toks.push(Tok::Float(f));
            } else {
                let n: i64 = src[s..i]
                    .parse()
                    .map_err(|_| Error::syntax("integer literal out of range"))?;
                toks.push(Tok::Int(n));
            }
        } else if c == b'"' || c == b'\'' {
            i += 1;
            let mut s = String::new();
            let mut run = i;
            loop {
                if i >= b.len() {
                    return Err(Error::syntax("unterminated string"));
                }
                if b[i] == c {
                    s.push_str(&src[run..i]);
                    i += 1;
                    break;
                }
                if b[i] == b'\\' {
                    s.push_str(&src[run..i]);
                    let e = b.get(i + 1).copied();
                    match e {
                        Some(b'\\') => s.push('\\'),
                        Some(b'"') => s.push('"'),
                        Some(b'\'') => s.push('\''),
                        Some(b'n') => s.push('\n'),
                        Some(b't') => s.push('\t'),
                        _ => return Err(Error::syntax("bad string escape")),
                    }
                    i += 2;
                    run = i;
                } else {
                    i += 1;
                }
            }
            toks.push(Tok::Str(s));
        } else {
            let rest = &b[i..];
            match OPS.iter().find(|op| rest.starts_with(op.as_bytes())) {
                Some(op) => {
                    toks.push(Tok::Op(op));
                    i += op.len();
                }
                None => return Err(Error::syntax("unexpected character in tag")),
            }
        }
    }
}
