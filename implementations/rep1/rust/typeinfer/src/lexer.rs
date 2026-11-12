//! Tokeniser.

use crate::error::ParseError;
use crate::symbol::{Interner, Sym};

/// A lexical token.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Token {
    Int,
    Ident(Sym),
    Let,
    Rec,
    In,
    Fun,
    If,
    Then,
    Else,
    True,
    False,
    DSemi,
    Arrow,
    ColonColon,
    Le,
    Ge,
    AndAnd,
    OrOr,
    LParen,
    RParen,
    LBrack,
    RBrack,
    Semi,
    Comma,
    Plus,
    Minus,
    Star,
    Slash,
    Eq,
    Lt,
    Gt,
}

/// Splits `src` into tokens, each paired with its starting byte offset.
pub fn tokenize(src: &str, interner: &mut Interner) -> Result<Vec<(Token, usize)>, ParseError> {
    let b = src.as_bytes();
    let mut toks = Vec::new();
    let mut i = 0;
    while i < b.len() {
        let c = b[i];
        let start = i;
        let two = |second: u8| i + 1 < b.len() && b[i + 1] == second;
        let tok = match c {
            b' ' | b'\t' | b'\r' | b'\n' => {
                i += 1;
                continue;
            }
            b'0'..=b'9' => {
                while i < b.len() && b[i].is_ascii_digit() {
                    i += 1;
                }
                toks.push((Token::Int, start));
                continue;
            }
            b'a'..=b'z' => {
                while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'_') {
                    i += 1;
                }
                let word = &src[start..i];
                let t = match word {
                    "let" => Token::Let,
                    "rec" => Token::Rec,
                    "in" => Token::In,
                    "fun" => Token::Fun,
                    "if" => Token::If,
                    "then" => Token::Then,
                    "else" => Token::Else,
                    "true" => Token::True,
                    "false" => Token::False,
                    _ => Token::Ident(interner.intern(word)),
                };
                toks.push((t, start));
                continue;
            }
            b';' if two(b';') => (Token::DSemi, 2),
            b';' => (Token::Semi, 1),
            b'-' if two(b'>') => (Token::Arrow, 2),
            b'-' => (Token::Minus, 1),
            b':' if two(b':') => (Token::ColonColon, 2),
            b'<' if two(b'=') => (Token::Le, 2),
            b'<' => (Token::Lt, 1),
            b'>' if two(b'=') => (Token::Ge, 2),
            b'>' => (Token::Gt, 1),
            b'&' if two(b'&') => (Token::AndAnd, 2),
            b'|' if two(b'|') => (Token::OrOr, 2),
            b'(' => (Token::LParen, 1),
            b')' => (Token::RParen, 1),
            b'[' => (Token::LBrack, 1),
            b']' => (Token::RBrack, 1),
            b',' => (Token::Comma, 1),
            b'+' => (Token::Plus, 1),
            b'*' => (Token::Star, 1),
            b'/' => (Token::Slash, 1),
            b'=' => (Token::Eq, 1),
            _ => {
                return Err(ParseError::new(i, format!("unexpected byte {:?}", c as char)));
            }
        };
        toks.push((tok.0, start));
        i += tok.1;
    }
    Ok(toks)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn toks(s: &str) -> Vec<Token> {
        let mut i = Interner::new();
        tokenize(s, &mut i).unwrap().into_iter().map(|t| t.0).collect()
    }

    #[test]
    fn longest_match() {
        assert_eq!(
            toks("-> ;; :: <= >= && || ; < > -"),
            vec![
                Token::Arrow,
                Token::DSemi,
                Token::ColonColon,
                Token::Le,
                Token::Ge,
                Token::AndAnd,
                Token::OrOr,
                Token::Semi,
                Token::Lt,
                Token::Gt,
                Token::Minus
            ]
        );
    }

    #[test]
    fn keywords_vs_identifiers() {
        let mut i = Interner::new();
        let t = tokenize("let letx in inx rec", &mut i).unwrap();
        assert_eq!(t[0].0, Token::Let);
        assert!(matches!(t[1].0, Token::Ident(_)));
        assert_eq!(t[2].0, Token::In);
        assert!(matches!(t[3].0, Token::Ident(_)));
        assert_eq!(t[4].0, Token::Rec);
    }

    #[test]
    fn long_integer_and_adjacent_symbols() {
        assert_eq!(
            toks("123456789012345678901234567890;;"),
            vec![Token::Int, Token::DSemi]
        );
        assert_eq!(toks("[1;2]"), vec![Token::LBrack, Token::Int, Token::Semi, Token::Int, Token::RBrack]);
    }

    #[test]
    fn rejects_unknown_bytes() {
        let mut i = Interner::new();
        assert!(tokenize("a # b", &mut i).is_err());
    }
}
