//! Splits template source into text and tags, handling whitespace control
//! and tokenizing the content of `{{ }}` and `{% %}` tags.

use crate::error::{Error, Result};
use crate::value::is_ws;
use std::rc::Rc;

/// A token inside a tag.
#[derive(Clone, Debug, PartialEq)]
pub enum Token {
    /// An identifier or keyword.
    Name(Rc<str>),
    /// An integer literal.
    Int(i64),
    /// A float literal.
    Float(f64),
    /// A string literal (escapes already resolved).
    Str(Rc<str>),
    /// An operator or punctuation.
    Punct(&'static str),
}

/// A lexed piece of a template.
#[derive(Debug)]
pub enum Item {
    /// Literal text (after whitespace control).
    Text(String),
    /// `{{ ... }}` with its tokens.
    Print(Vec<Token>),
    /// `{% ... %}` with its tokens.
    Stmt(Vec<Token>),
}

const PUNCT2: [&str; 6] = ["**", "//", "==", "!=", "<=", ">="];
const PUNCT1: [&str; 16] =
    ["~", "+", "-", "*", "/", "%", "<", ">", "(", ")", "[", "]", ",", "|", ".", "="];

/// Lexes a whole template.
pub fn lex(src: &str) -> Result<Vec<Item>> {
    let bytes = src.as_bytes();
    let mut items = Vec::new();
    let mut pos = 0;
    let mut lstrip = false; // previous tag ended with `-`
    loop {
        // Find the next tag opener.
        let mut open = None;
        let mut i = pos;
        while let Some(off) = bytes[i..].iter().position(|&b| b == b'{') {
            let at = i + off;
            if matches!(bytes.get(at + 1), Some(b'{' | b'%' | b'#')) {
                open = Some(at);
                break;
            }
            i = at + 1;
        }
        let mut text = &src[pos..open.unwrap_or(src.len())];
        if lstrip {
            text = text.trim_start_matches(is_ws);
        }
        let Some(at) = open else {
            if !text.is_empty() {
                items.push(Item::Text(text.to_string()));
            }
            return Ok(items);
        };
        let kind = bytes[at + 1];
        let mut content = at + 2;
        if bytes.get(content) == Some(&b'-') {
            text = text.trim_end_matches(is_ws);
            content += 1;
        }
        if !text.is_empty() {
            items.push(Item::Text(text.to_string()));
        }
        if kind == b'#' {
            let end = src[content..]
                .find("#}")
                .ok_or_else(|| Error::syntax("unclosed comment"))?
                + content;
            lstrip = end > content && bytes[end - 1] == b'-';
            pos = end + 2;
            continue;
        }
        let (tokens, next, strip) = lex_tag(src, content, kind == b'{')?;
        items.push(if kind == b'{' { Item::Print(tokens) } else { Item::Stmt(tokens) });
        pos = next;
        lstrip = strip;
    }
}

/// Tokenizes a tag body starting at `start`; returns the tokens, the index
/// after the closer and whether the closer had `-`.
fn lex_tag(src: &str, start: usize, is_print: bool) -> Result<(Vec<Token>, usize, bool)> {
    let bytes = src.as_bytes();
    let closer: &[u8] = if is_print { b"}}" } else { b"%}" };
    let mut tokens = Vec::new();
    let mut i = start;
    loop {
        while i < bytes.len() && is_ws(bytes[i] as char) {
            i += 1;
        }
        if i >= bytes.len() {
            return Err(Error::syntax("unclosed tag"));
        }
        if bytes[i..].starts_with(closer) {
            return Ok((tokens, i + 2, false));
        }
        if bytes[i] == b'-' && bytes[i + 1..].starts_with(closer) {
            return Ok((tokens, i + 3, true));
        }
        let c = bytes[i];
        if c.is_ascii_alphabetic() || c == b'_' {
            let s = i;
            while i < bytes.len() && (bytes[i].is_ascii_alphanumeric() || bytes[i] == b'_') {
                i += 1;
            }
            tokens.push(Token::Name(Rc::from(&src[s..i])));
        } else if c.is_ascii_digit() {
            let s = i;
            while i < bytes.len() && bytes[i].is_ascii_digit() {
                i += 1;
            }
            if i + 1 < bytes.len() && bytes[i] == b'.' && bytes[i + 1].is_ascii_digit() {
                i += 1;
                while i < bytes.len() && bytes[i].is_ascii_digit() {
                    i += 1;
                }
                let f = src[s..i].parse::<f64>().map_err(|_| Error::syntax("bad float"))?;
                tokens.push(Token::Float(f));
            } else {
                let n = src[s..i].parse::<i64>().map_err(|_| Error::syntax("integer too large"))?;
                tokens.push(Token::Int(n));
            }
        } else if c == b'"' || c == b'\'' {
            let (s, next) = lex_string(src, i)?;
            tokens.push(Token::Str(Rc::from(s)));
            i = next;
        } else {
            let rest = &src[i..];
            if let Some(p) = PUNCT2.iter().find(|p| rest.starts_with(**p)) {
                tokens.push(Token::Punct(p));
                i += 2;
            } else if let Some(p) = PUNCT1.iter().find(|p| rest.starts_with(**p)) {
                tokens.push(Token::Punct(p));
                i += 1;
            } else {
                return Err(Error::syntax("unexpected character in tag"));
            }
        }
    }
}

/// Lexes a string literal whose opening quote is at `start`.
fn lex_string(src: &str, start: usize) -> Result<(String, usize)> {
    let bytes = src.as_bytes();
    let quote = bytes[start];
    let mut out = String::new();
    let mut chars = src[start + 1..].char_indices();
    while let Some((off, c)) = chars.next() {
        if c as u32 == quote as u32 {
            return Ok((out, start + 1 + off + 1));
        }
        if c == '\\' {
            match chars.next() {
                Some((_, '\\')) => out.push('\\'),
                Some((_, '"')) => out.push('"'),
                Some((_, '\'')) => out.push('\''),
                Some((_, 'n')) => out.push('\n'),
                Some((_, 't')) => out.push('\t'),
                _ => return Err(Error::syntax("bad string escape")),
            }
        } else {
            out.push(c);
        }
    }
    Err(Error::syntax("unterminated string"))
}
