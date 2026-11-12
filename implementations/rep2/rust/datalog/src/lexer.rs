//! Tokeniser.

use crate::error::ParseError;

/// A lexical token.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Token {
    /// Lower-case identifier (predicate or symbolic constant).
    Ident(String),
    /// Upper-case variable name.
    Var(String),
    /// `_`
    Anon,
    /// Integer literal.
    Int(i64),
    /// The reserved word `not`.
    Not,
    /// `(`
    LParen,
    /// `)`
    RParen,
    /// `,`
    Comma,
    /// `.`
    Dot,
    /// `:-`
    Implies,
    /// `?-`
    Query,
    /// `<`
    Lt,
    /// `<=`
    Le,
    /// `>`
    Gt,
    /// `>=`
    Ge,
    /// `=`
    Eq,
    /// `!=`
    Ne,
}

/// A token with its source position (1-based).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Spanned {
    /// The token.
    pub token: Token,
    /// 1-based line.
    pub line: usize,
    /// 1-based column.
    pub column: usize,
}

fn is_word(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}

/// Split `src` into tokens, dropping whitespace and `%` comments.
pub fn tokenize(src: &str) -> Result<Vec<Spanned>, ParseError> {
    let bytes = src.as_bytes();
    let mut out = Vec::new();
    let (mut i, mut line, mut line_start) = (0usize, 1usize, 0usize);
    while i < bytes.len() {
        let b = bytes[i];
        let column = i - line_start + 1;
        let err = |message: String| ParseError { message, line, column };
        let simple = |t: Token, n: usize| (t, n);
        let (token, len) = match b {
            b'\n' => {
                i += 1;
                line += 1;
                line_start = i;
                continue;
            }
            b' ' | b'\t' | b'\r' => {
                i += 1;
                continue;
            }
            b'%' => {
                while i < bytes.len() && bytes[i] != b'\n' {
                    i += 1;
                }
                continue;
            }
            b'(' => simple(Token::LParen, 1),
            b')' => simple(Token::RParen, 1),
            b',' => simple(Token::Comma, 1),
            b'.' => simple(Token::Dot, 1),
            b'=' => simple(Token::Eq, 1),
            b'<' if bytes.get(i + 1) == Some(&b'=') => simple(Token::Le, 2),
            b'<' => simple(Token::Lt, 1),
            b'>' if bytes.get(i + 1) == Some(&b'=') => simple(Token::Ge, 2),
            b'>' => simple(Token::Gt, 1),
            b'!' if bytes.get(i + 1) == Some(&b'=') => simple(Token::Ne, 2),
            b':' if bytes.get(i + 1) == Some(&b'-') => simple(Token::Implies, 2),
            b'?' if bytes.get(i + 1) == Some(&b'-') => simple(Token::Query, 2),
            b'-' | b'0'..=b'9' => {
                let mut j = i + usize::from(b == b'-');
                let digits = j;
                while j < bytes.len() && bytes[j].is_ascii_digit() {
                    j += 1;
                }
                if j == digits {
                    return Err(err("`-` must start a negative integer".into()));
                }
                let n = src[i..j]
                    .parse::<i64>()
                    .map_err(|_| err(format!("integer `{}` out of range", &src[i..j])))?;
                (Token::Int(n), j - i)
            }
            b'_' | b'a'..=b'z' | b'A'..=b'Z' => {
                let mut j = i + 1;
                while j < bytes.len() && is_word(bytes[j]) {
                    j += 1;
                }
                let word = &src[i..j];
                let t = match b {
                    b'_' if word == "_" => Token::Anon,
                    b'_' => return Err(err(format!("invalid token `{word}`"))),
                    b'A'..=b'Z' => Token::Var(word.to_string()),
                    _ if word == "not" => Token::Not,
                    _ => Token::Ident(word.to_string()),
                };
                (t, j - i)
            }
            _ => return Err(err(format!("unexpected character `{}`", src[i..].chars().next().unwrap()))),
        };
        out.push(Spanned { token, line, column });
        i += len;
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn toks(s: &str) -> Vec<Token> {
        tokenize(s).unwrap().into_iter().map(|t| t.token).collect()
    }

    #[test]
    fn longest_match_and_negative_numbers() {
        assert_eq!(toks("X<-1"), vec![Token::Var("X".into()), Token::Lt, Token::Int(-1)]);
        assert_eq!(toks("<= >= != ="), vec![Token::Le, Token::Ge, Token::Ne, Token::Eq]);
        assert_eq!(toks("p :- q. ?- r."), vec![
            Token::Ident("p".into()), Token::Implies, Token::Ident("q".into()), Token::Dot,
            Token::Query, Token::Ident("r".into()), Token::Dot,
        ]);
    }

    #[test]
    fn keywords_and_identifiers() {
        assert_eq!(toks("not nothing not_x _"), vec![
            Token::Not, Token::Ident("nothing".into()), Token::Ident("not_x".into()), Token::Anon,
        ]);
    }

    #[test]
    fn comments_and_positions() {
        let t = tokenize("% hi\n  a(1). % bye\nb").unwrap();
        assert_eq!(t[0].line, 2);
        assert_eq!(t[0].column, 3);
        assert_eq!(t.last().unwrap().line, 3);
    }

    #[test]
    fn errors() {
        assert!(tokenize("a $ b").is_err());
        assert!(tokenize("- 1").is_err());
        assert!(tokenize("_x").is_err());
    }
}
