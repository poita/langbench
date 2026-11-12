//! Tokenizer: turns SQL text into a flat list of [`Token`]s.
//!
//! The lexer never fails. Characters that cannot start a token become
//! [`Token::Invalid`], and a string literal that is never closed becomes
//! [`Token::UnterminatedString`]; the parser rejects the statement
//! containing either.

/// Reserved words. They can never be used as identifiers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(missing_docs)]
pub enum Keyword {
    Select, From, Where, And, Or, Not, Null, Is, Like, As, Insert, Into,
    Values, Delete, Update, Set, Create, Table, Integer, Text, Inner, Join,
    On, Group, By, Having, Order, Asc, Desc, Limit, Offset, Left, Right,
    Full, Outer, Cross, Natural,
}

impl Keyword {
    /// Looks up a lower-case word in the reserved-word table.
    pub fn from_lowercase(word: &str) -> Option<Keyword> {
        use Keyword::*;
        Some(match word {
            "select" => Select, "from" => From, "where" => Where, "and" => And,
            "or" => Or, "not" => Not, "null" => Null, "is" => Is, "like" => Like,
            "as" => As, "insert" => Insert, "into" => Into, "values" => Values,
            "delete" => Delete, "update" => Update, "set" => Set,
            "create" => Create, "table" => Table, "integer" => Integer,
            "text" => Text, "inner" => Inner, "join" => Join, "on" => On,
            "group" => Group, "by" => By, "having" => Having, "order" => Order,
            "asc" => Asc, "desc" => Desc, "limit" => Limit, "offset" => Offset,
            "left" => Left, "right" => Right, "full" => Full, "outer" => Outer,
            "cross" => Cross, "natural" => Natural,
            _ => return None,
        })
    }
}

/// One lexical token.
#[derive(Debug, Clone, PartialEq, Eq)]
#[allow(missing_docs)]
pub enum Token {
    /// A non-reserved identifier, folded to lower case.
    Ident(String),
    Keyword(Keyword),
    /// A non-negative integer literal.
    Integer(u64),
    /// A string literal with its quotes removed and `''` unescaped.
    Str(String),
    Plus,
    Minus,
    Star,
    Slash,
    Percent,
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
    LParen,
    RParen,
    Comma,
    Dot,
    Semicolon,
    /// A character (or integer literal) that is not a valid token.
    Invalid,
    /// A string literal that runs to the end of the input.
    UnterminatedString,
}

/// Splits `src` into tokens. Whitespace and `--` comments are dropped.
pub fn tokenize(src: &str) -> Vec<Token> {
    let b = src.as_bytes();
    let mut toks = Vec::new();
    let mut i = 0;
    while i < b.len() {
        let c = b[i];
        match c {
            b' ' | b'\t' | b'\r' | b'\n' | 0x0c | 0x0b => i += 1,
            b'-' if b.get(i + 1) == Some(&b'-') => {
                while i < b.len() && b[i] != b'\n' {
                    i += 1;
                }
            }
            b'a'..=b'z' | b'A'..=b'Z' | b'_' => {
                let start = i;
                while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'_') {
                    i += 1;
                }
                let word = src[start..i].to_ascii_lowercase();
                toks.push(match Keyword::from_lowercase(&word) {
                    Some(k) => Token::Keyword(k),
                    None => Token::Ident(word),
                });
            }
            b'0'..=b'9' => {
                let start = i;
                while i < b.len() && b[i].is_ascii_digit() {
                    i += 1;
                }
                toks.push(match src[start..i].parse::<u64>() {
                    Ok(n) => Token::Integer(n),
                    Err(_) => Token::Invalid,
                });
            }
            b'\'' => {
                i += 1;
                let mut s = String::new();
                let mut seg = i;
                let mut closed = false;
                while i < b.len() {
                    if b[i] == b'\'' {
                        s.push_str(&src[seg..i]);
                        if b.get(i + 1) == Some(&b'\'') {
                            s.push('\'');
                            i += 2;
                            seg = i;
                        } else {
                            i += 1;
                            closed = true;
                            break;
                        }
                    } else {
                        i += 1;
                    }
                }
                toks.push(if closed { Token::Str(s) } else { Token::UnterminatedString });
            }
            b'+' => { toks.push(Token::Plus); i += 1 }
            b'-' => { toks.push(Token::Minus); i += 1 }
            b'*' => { toks.push(Token::Star); i += 1 }
            b'/' => { toks.push(Token::Slash); i += 1 }
            b'%' => { toks.push(Token::Percent); i += 1 }
            b'(' => { toks.push(Token::LParen); i += 1 }
            b')' => { toks.push(Token::RParen); i += 1 }
            b',' => { toks.push(Token::Comma); i += 1 }
            b'.' => { toks.push(Token::Dot); i += 1 }
            b';' => { toks.push(Token::Semicolon); i += 1 }
            b'=' => {
                i += if b.get(i + 1) == Some(&b'=') { 2 } else { 1 };
                toks.push(Token::Eq);
            }
            b'!' => {
                if b.get(i + 1) == Some(&b'=') {
                    toks.push(Token::Ne);
                    i += 2;
                } else {
                    toks.push(Token::Invalid);
                    i += 1;
                }
            }
            b'<' => match b.get(i + 1) {
                Some(b'=') => { toks.push(Token::Le); i += 2 }
                Some(b'>') => { toks.push(Token::Ne); i += 2 }
                _ => { toks.push(Token::Lt); i += 1 }
            },
            b'>' => {
                if b.get(i + 1) == Some(&b'=') {
                    toks.push(Token::Ge);
                    i += 2;
                } else {
                    toks.push(Token::Gt);
                    i += 1;
                }
            }
            _ => {
                // Any other character is invalid; skip a whole UTF-8 sequence.
                toks.push(Token::Invalid);
                i += 1;
                while i < b.len() && (b[i] & 0xC0) == 0x80 {
                    i += 1;
                }
            }
        }
    }
    toks
}

/// Splits a token stream into statements at `;` tokens.
///
/// Empty statements are dropped; a trailing statement without `;` is kept.
pub fn split_statements(tokens: &[Token]) -> Vec<&[Token]> {
    tokens
        .split(|t| *t == Token::Semicolon)
        .filter(|s| !s.is_empty())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keywords_and_identifiers_fold_case() {
        assert_eq!(
            tokenize("SeLeCt Emp"),
            vec![Token::Keyword(Keyword::Select), Token::Ident("emp".into())]
        );
    }

    #[test]
    fn comments_and_double_minus() {
        assert_eq!(tokenize("1 --5\n2"), vec![Token::Integer(1), Token::Integer(2)]);
        assert_eq!(tokenize("1 - -5").len(), 4);
    }

    #[test]
    fn string_escapes_and_multiline() {
        assert_eq!(tokenize("'it''s\n;'"), vec![Token::Str("it's\n;".into())]);
        assert_eq!(tokenize("'abc"), vec![Token::UnterminatedString]);
    }

    #[test]
    fn operators_longest_match() {
        assert_eq!(
            tokenize("<= <> != == = < >="),
            vec![Token::Le, Token::Ne, Token::Ne, Token::Eq, Token::Eq, Token::Lt, Token::Ge]
        );
    }

    #[test]
    fn invalid_tokens() {
        assert_eq!(tokenize("é"), vec![Token::Invalid]);
        assert_eq!(tokenize("@ \" !"), vec![Token::Invalid; 3]);
        assert_eq!(
            tokenize("1.5"),
            vec![Token::Integer(1), Token::Dot, Token::Integer(5)]
        );
    }

    #[test]
    fn statement_splitting() {
        let toks = tokenize(";; select 1 ; ; select 2");
        assert_eq!(split_statements(&toks).len(), 2);
    }
}
