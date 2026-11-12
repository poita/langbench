//! Tokenizer for filter source text.

use crate::error::{Error, Result};

/// A filter token.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Tok {
    Ident(String),
    Var(String),
    Num(f64),
    Str(String),
    /// Punctuation or operator, e.g. `|`, `==`, `[`.
    Sym(&'static str),
}

const SYMS: [&str; 24] = [
    "==", "!=", "<=", ">=", "|", ",", ":", ";", "(", ")", "[", "]", "{", "}", "?", ".", "+", "-", "*", "/", "%", "<",
    ">", "=",
];

fn is_ident_start(c: u8) -> bool {
    c.is_ascii_alphabetic() || c == b'_'
}

fn is_ident_char(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_'
}

/// Splits `src` into tokens.
pub(crate) fn tokenize(src: &str) -> Result<Vec<Tok>> {
    let b = src.as_bytes();
    let mut i = 0;
    let mut toks = Vec::new();
    while i < b.len() {
        let c = b[i];
        match c {
            b' ' | b'\t' | b'\n' | b'\r' => i += 1,
            b'#' => {
                while i < b.len() && b[i] != b'\n' {
                    i += 1;
                }
            }
            b'"' => {
                let (s, next) = lex_string(src, i)?;
                toks.push(Tok::Str(s));
                i = next;
            }
            b'$' => {
                let start = i + 1;
                let mut j = start;
                while j < b.len() && is_ident_char(b[j]) {
                    j += 1;
                }
                if j == start || !is_ident_start(b[start]) {
                    return Err(Error::syntax("expected variable name after '$'"));
                }
                toks.push(Tok::Var(src[start..j].to_string()));
                i = j;
            }
            b'0'..=b'9' => {
                let start = i;
                while i < b.len() && b[i].is_ascii_digit() {
                    i += 1;
                }
                if i + 1 < b.len() && b[i] == b'.' && b[i + 1].is_ascii_digit() {
                    i += 1;
                    while i < b.len() && b[i].is_ascii_digit() {
                        i += 1;
                    }
                }
                let n = src[start..i].parse::<f64>().map_err(|_| Error::syntax("invalid number"))?;
                toks.push(Tok::Num(n));
            }
            _ if is_ident_start(c) => {
                let start = i;
                while i < b.len() && is_ident_char(b[i]) {
                    i += 1;
                }
                toks.push(Tok::Ident(src[start..i].to_string()));
            }
            _ => {
                let rest = &src[i..];
                match SYMS.iter().find(|s| rest.starts_with(**s)) {
                    Some(s) => {
                        toks.push(Tok::Sym(s));
                        i += s.len();
                    }
                    None => {
                        let ch = rest.chars().next().unwrap_or('?');
                        return Err(Error::syntax(format!("unexpected character '{}'", ch)));
                    }
                }
            }
        }
    }
    Ok(toks)
}

fn hex4(b: &[u8], i: usize) -> Result<u32> {
    let slice = b.get(i..i + 4).ok_or_else(|| Error::syntax("truncated \\u escape"))?;
    let s = std::str::from_utf8(slice).map_err(|_| Error::syntax("invalid \\u escape"))?;
    u32::from_str_radix(s, 16).map_err(|_| Error::syntax("invalid \\u escape"))
}

/// Lexes a string literal starting at the opening quote; returns the value and the next index.
fn lex_string(src: &str, start: usize) -> Result<(String, usize)> {
    let b = src.as_bytes();
    let mut out = String::new();
    let mut i = start + 1;
    loop {
        let seg = i;
        while i < b.len() && b[i] != b'"' && b[i] != b'\\' {
            i += 1;
        }
        out.push_str(&src[seg..i]);
        if i >= b.len() {
            return Err(Error::syntax("unterminated string"));
        }
        if b[i] == b'"' {
            return Ok((out, i + 1));
        }
        i += 1;
        let e = *b.get(i).ok_or_else(|| Error::syntax("unterminated string"))?;
        i += 1;
        match e {
            b'"' => out.push('"'),
            b'\\' => out.push('\\'),
            b'/' => out.push('/'),
            b'b' => out.push('\u{8}'),
            b'f' => out.push('\u{c}'),
            b'n' => out.push('\n'),
            b'r' => out.push('\r'),
            b't' => out.push('\t'),
            b'u' => {
                let hi = hex4(b, i)?;
                i += 4;
                let cp = if (0xD800..0xDC00).contains(&hi) {
                    if b.get(i) == Some(&b'\\') && b.get(i + 1) == Some(&b'u') {
                        let lo = hex4(b, i + 2)?;
                        i += 6;
                        if !(0xDC00..0xE000).contains(&lo) {
                            return Err(Error::syntax("invalid surrogate pair"));
                        }
                        0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
                    } else {
                        return Err(Error::syntax("unpaired surrogate"));
                    }
                } else {
                    hi
                };
                out.push(char::from_u32(cp).ok_or_else(|| Error::syntax("invalid code point"))?);
            }
            _ => return Err(Error::syntax("invalid escape in string")),
        }
    }
}
