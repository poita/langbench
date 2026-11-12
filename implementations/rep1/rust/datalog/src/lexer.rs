//! Tokeniser.

use crate::ast::CmpOp;
use crate::error::Error;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Tok {
    Ident(String),
    Var(String),
    Anon,
    Int(i64),
    Not,
    LParen,
    RParen,
    Comma,
    Dot,
    Implies,
    QueryStart,
    Cmp(CmpOp),
}

#[derive(Debug, Clone)]
pub(crate) struct Token {
    pub(crate) tok: Tok,
    pub(crate) line: usize,
}

fn is_ident_char(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}

/// Split `src` into tokens, dropping whitespace and `%` comments.
pub(crate) fn tokenize(src: &str) -> Result<Vec<Token>, Error> {
    let b = src.as_bytes();
    let mut i = 0;
    let mut line = 1;
    let mut out = Vec::new();
    let err = |line: usize, message: String| Error::Parse { line, message };
    while i < b.len() {
        let c = b[i];
        let tok = match c {
            b'\n' => {
                line += 1;
                i += 1;
                continue;
            }
            b' ' | b'\t' | b'\r' => {
                i += 1;
                continue;
            }
            b'%' => {
                while i < b.len() && b[i] != b'\n' {
                    i += 1;
                }
                continue;
            }
            b'(' => {
                i += 1;
                Tok::LParen
            }
            b')' => {
                i += 1;
                Tok::RParen
            }
            b',' => {
                i += 1;
                Tok::Comma
            }
            b'.' => {
                i += 1;
                Tok::Dot
            }
            b'=' => {
                i += 1;
                Tok::Cmp(CmpOp::Eq)
            }
            b'<' | b'>' => {
                let orequal = b.get(i + 1) == Some(&b'=');
                i += if orequal { 2 } else { 1 };
                Tok::Cmp(match (c, orequal) {
                    (b'<', false) => CmpOp::Lt,
                    (b'<', true) => CmpOp::Le,
                    (_, false) => CmpOp::Gt,
                    (_, true) => CmpOp::Ge,
                })
            }
            b'!' if b.get(i + 1) == Some(&b'=') => {
                i += 2;
                Tok::Cmp(CmpOp::Ne)
            }
            b':' if b.get(i + 1) == Some(&b'-') => {
                i += 2;
                Tok::Implies
            }
            b'?' if b.get(i + 1) == Some(&b'-') => {
                i += 2;
                Tok::QueryStart
            }
            b'-' | b'0'..=b'9' => {
                let start = i;
                if c == b'-' {
                    i += 1;
                }
                let digits = i;
                while i < b.len() && b[i].is_ascii_digit() {
                    i += 1;
                }
                if i == digits {
                    return Err(err(line, "`-` must start a negative integer".into()));
                }
                let n = src[start..i]
                    .parse::<i64>()
                    .map_err(|_| err(line, format!("integer out of range: {}", &src[start..i])))?;
                Tok::Int(n)
            }
            b'a'..=b'z' | b'A'..=b'Z' | b'_' => {
                let start = i;
                while i < b.len() && is_ident_char(b[i]) {
                    i += 1;
                }
                let word = &src[start..i];
                match c {
                    b'_' if word == "_" => Tok::Anon,
                    b'_' => return Err(err(line, format!("invalid token `{word}`"))),
                    b'A'..=b'Z' => Tok::Var(word.to_string()),
                    _ if word == "not" => Tok::Not,
                    _ => Tok::Ident(word.to_string()),
                }
            }
            _ => return Err(err(line, format!("unexpected character `{}`", c as char))),
        };
        out.push(Token { tok, line });
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn toks(s: &str) -> Vec<Tok> {
        tokenize(s).unwrap().into_iter().map(|t| t.tok).collect()
    }

    #[test]
    fn longest_match_operators() {
        assert_eq!(
            toks("X<-1"),
            vec![Tok::Var("X".into()), Tok::Cmp(CmpOp::Lt), Tok::Int(-1)]
        );
        assert_eq!(toks("<= >= != ="), vec![
            Tok::Cmp(CmpOp::Le),
            Tok::Cmp(CmpOp::Ge),
            Tok::Cmp(CmpOp::Ne),
            Tok::Cmp(CmpOp::Eq)
        ]);
    }

    #[test]
    fn keyword_vs_identifier() {
        assert_eq!(toks("not nothing not_x"), vec![
            Tok::Not,
            Tok::Ident("nothing".into()),
            Tok::Ident("not_x".into())
        ]);
    }

    #[test]
    fn comments_and_lines() {
        let t = tokenize("a % hi\n\n b").unwrap();
        assert_eq!(t[0].line, 1);
        assert_eq!(t[1].line, 3);
    }

    #[test]
    fn rule_and_query_arrows() {
        assert_eq!(toks(":- ?- _"), vec![Tok::Implies, Tok::QueryStart, Tok::Anon]);
    }
}
