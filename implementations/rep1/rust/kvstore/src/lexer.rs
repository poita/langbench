//! The token stream of the command language (spec §6.1).

use crate::error::{Error, Result};
use crate::predicate::CmpOp;

/// A lexical token.
///
/// Problems that are only reported when the parser *consumes* a token (an
/// out-of-range integer, an unpaired surrogate) are carried inside the token,
/// because the first problem in source order wins.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Token {
    /// `[A-Za-z_][A-Za-z0-9_]*`
    Word(String),
    /// An integer; `None` if it does not fit in 64 bits.
    Int(Option<i64>),
    /// A string literal; `None` if an escape left an unpaired surrogate.
    Str(Option<String>),
    /// One of `{ } [ ] ( ) , : .`
    Punct(u8),
    /// A comparison operator.
    Op(CmpOp),
}

/// Splits `line` into tokens. Any lexical problem is [`Error::Syntax`].
pub fn lex(line: &str) -> Result<Vec<Token>> {
    let b = line.as_bytes();
    let mut toks = Vec::new();
    let mut i = 0;
    while i < b.len() {
        let c = b[i];
        match c {
            b' ' | b'\t' => i += 1,
            b'{' | b'}' | b'[' | b']' | b'(' | b')' | b',' | b':' | b'.' => {
                toks.push(Token::Punct(c));
                i += 1;
            }
            b'=' | b'!' => {
                if b.get(i + 1) == Some(&b'=') {
                    toks.push(Token::Op(if c == b'=' { CmpOp::Eq } else { CmpOp::Ne }));
                    i += 2;
                } else {
                    return Err(Error::Syntax);
                }
            }
            b'<' | b'>' => {
                let le = b.get(i + 1) == Some(&b'=');
                let op = match (c, le) {
                    (b'<', false) => CmpOp::Lt,
                    (b'<', true) => CmpOp::Le,
                    (_, false) => CmpOp::Gt,
                    (_, true) => CmpOp::Ge,
                };
                toks.push(Token::Op(op));
                i += if le { 2 } else { 1 };
            }
            b'-' | b'0'..=b'9' => {
                let start = i;
                let neg = c == b'-';
                if neg {
                    i += 1;
                }
                let digits = i;
                while i < b.len() && b[i].is_ascii_digit() {
                    i += 1;
                }
                let run = &line[digits..i];
                if run.is_empty() || (run.len() > 1 && run.starts_with('0')) || (neg && run == "0") {
                    return Err(Error::Syntax);
                }
                toks.push(Token::Int(line[start..i].parse::<i64>().ok()));
            }
            b'"' => {
                let (tok, next) = lex_string(b, i + 1)?;
                toks.push(tok);
                i = next;
            }
            c if c.is_ascii_alphabetic() || c == b'_' => {
                let start = i;
                while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'_') {
                    i += 1;
                }
                toks.push(Token::Word(line[start..i].to_string()));
            }
            _ => return Err(Error::Syntax),
        }
    }
    Ok(toks)
}

fn hex4(b: &[u8], at: usize) -> Option<u32> {
    let s = b.get(at..at + 4)?;
    let mut v = 0u32;
    for &d in s {
        v = v * 16 + (d as char).to_digit(16)?;
    }
    Some(v)
}

/// Lexes a string literal whose opening quote precedes `i`. Returns the token
/// and the index just past the closing quote.
fn lex_string(b: &[u8], mut i: usize) -> Result<(Token, usize)> {
    let mut buf: Vec<u8> = Vec::new();
    let mut bad = false;
    loop {
        let Some(&c) = b.get(i) else { return Err(Error::Syntax) };
        match c {
            b'"' => break,
            0x00..=0x1f => return Err(Error::Syntax),
            b'\\' => {
                let Some(&e) = b.get(i + 1) else { return Err(Error::Syntax) };
                i += 2;
                match e {
                    b'"' => buf.push(b'"'),
                    b'\\' => buf.push(b'\\'),
                    b'/' => buf.push(b'/'),
                    b'b' => buf.push(8),
                    b'f' => buf.push(12),
                    b'n' => buf.push(10),
                    b'r' => buf.push(13),
                    b't' => buf.push(9),
                    b'u' => {
                        let u = hex4(b, i).ok_or(Error::Syntax)?;
                        i += 4;
                        match u {
                            0xD800..=0xDBFF => {
                                let low = if b.get(i) == Some(&b'\\') && b.get(i + 1) == Some(&b'u') {
                                    hex4(b, i + 2).filter(|l| (0xDC00..=0xDFFF).contains(l))
                                } else {
                                    None
                                };
                                match low {
                                    Some(l) => {
                                        i += 6;
                                        let cp = 0x10000 + ((u - 0xD800) << 10) + (l - 0xDC00);
                                        push_char(&mut buf, cp);
                                    }
                                    None => bad = true,
                                }
                            }
                            0xDC00..=0xDFFF => bad = true,
                            _ => push_char(&mut buf, u),
                        }
                    }
                    _ => return Err(Error::Syntax),
                }
            }
            _ => {
                buf.push(c);
                i += 1;
            }
        }
    }
    let tok = if bad {
        Token::Str(None)
    } else {
        Token::Str(Some(String::from_utf8_lossy(&buf).into_owned()))
    };
    Ok((tok, i + 1))
}

fn push_char(buf: &mut Vec<u8>, cp: u32) {
    let c = char::from_u32(cp).unwrap_or('\u{fffd}');
    let mut tmp = [0u8; 4];
    buf.extend_from_slice(c.encode_utf8(&mut tmp).as_bytes());
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &str) -> Token {
        Token::Str(Some(v.to_string()))
    }

    #[test]
    fn basic_tokens() {
        let t = lex(r#"put "a" {x:-12, y:[1,2]} <= >= != == < >"#).unwrap();
        assert_eq!(t[0], Token::Word("put".into()));
        assert_eq!(t[1], s("a"));
        assert!(t.contains(&Token::Int(Some(-12))));
        assert!(t.contains(&Token::Op(CmpOp::Le)));
        assert!(t.contains(&Token::Op(CmpOp::Ne)));
        assert!(lex("   \t ").unwrap().is_empty());
    }

    #[test]
    fn integer_shapes() {
        assert_eq!(lex("0").unwrap(), [Token::Int(Some(0))]);
        for bad in ["007", "-0", "-007", "+1", "-", "- 1"] {
            assert_eq!(lex(bad), Err(Error::Syntax), "{bad}");
        }
        assert_eq!(lex("9223372036854775808").unwrap(), [Token::Int(None)]);
        assert_eq!(lex("-9223372036854775808").unwrap(), [Token::Int(Some(i64::MIN))]);
    }

    #[test]
    fn string_escapes() {
        assert_eq!(lex(r#""a\"b\\\/\b\f\n\r\t\u0041\u00e9""#).unwrap(), [s("a\"b\\/\u{8}\u{c}\n\r\tAé")]);
        assert_eq!(lex(r#""\ud83d\ude00""#).unwrap(), [s("😀")]);
        assert_eq!(lex(r#""\ud800""#).unwrap(), [Token::Str(None)]);
        assert_eq!(lex(r#""\udc00""#).unwrap(), [Token::Str(None)]);
        assert_eq!(lex(r#""\ud800\u0041""#).unwrap(), [Token::Str(None)]);
        assert_eq!(lex(r#""\u00zz""#), Err(Error::Syntax));
        assert_eq!(lex(r#""\ud800" -"#), Err(Error::Syntax));
        assert_eq!(lex("\"a\tb\""), Err(Error::Syntax));
        assert_eq!(lex(r#""abc"#), Err(Error::Syntax));
        assert_eq!(lex(r#""\x""#), Err(Error::Syntax));
        assert_eq!(lex(r#""\u0000""#).unwrap(), [s("\0")]);
    }

    #[test]
    fn bad_bytes() {
        assert_eq!(lex("a = b"), Err(Error::Syntax));
        assert_eq!(lex("a ! b"), Err(Error::Syntax));
        assert_eq!(lex("é"), Err(Error::Syntax));
        assert_eq!(lex("a\rb"), Err(Error::Syntax));
    }
}
