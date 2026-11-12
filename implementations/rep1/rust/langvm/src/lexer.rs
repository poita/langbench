//! The lexer (pass 1): module text to tokens.

use crate::diag::{err, ErrorKind, Pos, Res};
use std::rc::Rc;

macro_rules! keywords {
    ($($v:ident => $s:literal,)*) => {
        /// Reserved words (one variant per keyword, named after it).
        #[allow(missing_docs)]
        #[derive(Copy, Clone, PartialEq, Eq, Debug)]
        pub enum Kw { $($v,)* }
        /// Returns whether `s` is a reserved word.
        pub fn is_keyword(s: &str) -> bool { keyword(s).is_some() }
        fn keyword(s: &str) -> Option<Kw> {
            match s { $($s => Some(Kw::$v),)* _ => None }
        }
    };
}

keywords! {
    As => "as", Break => "break", Continue => "continue", Else => "else",
    Enum => "enum", False => "false", Fn => "fn", For => "for", If => "if",
    Impl => "impl", In => "in", Let => "let", Match => "match", Pub => "pub",
    Return => "return", SelfKw => "self", Struct => "struct", Trait => "trait",
    True => "true", Use => "use", Var => "var", When => "when", While => "while",
}

/// Operators and punctuation (one variant per token of section 3.9).
#[allow(missing_docs)]
#[derive(Copy, Clone, PartialEq, Eq, Debug)]
pub enum P {
    HashBracket, ColonColon, DotDot, Arrow, EqEq, NotEq, Le, Ge, AndAnd, OrOr,
    Shl, Shr, PlusPlus, LParen, RParen, LBracket, RBracket, LBrace, RBrace,
    Comma, Semi, Colon, Dot, Pipe, Plus, Minus, Star, Slash, Percent, Bang,
    Tilde, Amp, Caret, Lt, Gt, Eq,
}

/// A token kind.
#[derive(Clone, PartialEq, Debug)]
pub enum Tok {
    /// An identifier.
    Ident(String),
    /// An integer literal.
    Int(i64),
    /// A float literal.
    Float(f64),
    /// A string literal (scalar values).
    Str(Rc<Vec<char>>),
    /// A character literal.
    Char(char),
    /// A keyword.
    Kw(Kw),
    /// Punctuation or an operator.
    P(P),
    /// The lone `_`.
    Underscore,
}

/// A token and where it starts.
#[derive(Clone, Debug)]
pub struct Token {
    /// What the token is.
    pub tok: Tok,
    /// Position of its first character.
    pub pos: Pos,
}

struct Lexer {
    cs: Vec<char>,
    i: usize,
    line: u32,
    col: u32,
}

impl Lexer {
    fn peek(&self) -> Option<char> {
        self.cs.get(self.i).copied()
    }
    fn peek_at(&self, k: usize) -> Option<char> {
        self.cs.get(self.i + k).copied()
    }
    fn pos(&self) -> Pos {
        Pos::new(self.line, self.col)
    }
    fn bump(&mut self) -> Option<char> {
        let c = self.cs.get(self.i).copied()?;
        self.i += 1;
        if c == '\n' {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        Some(c)
    }
}

fn hex_val(c: char) -> Option<u32> {
    c.to_digit(16)
}

/// Lexes one module body.
///
/// # Errors
/// `bad-token`, `int-range`, `bad-escape` or `unterminated`, at the first
/// ill-formed token.
pub fn lex(text: &str) -> Res<Vec<Token>> {
    let mut lx = Lexer { cs: text.chars().collect(), i: 0, line: 1, col: 1 };
    let mut out = Vec::with_capacity(lx.cs.len() / 4 + 4);
    loop {
        // skip whitespace and comments
        loop {
            match lx.peek() {
                Some(' ') | Some('\t') | Some('\n') | Some('\r') => {
                    lx.bump();
                }
                Some('/') if lx.peek_at(1) == Some('/') => {
                    while let Some(c) = lx.peek() {
                        if c == '\n' {
                            break;
                        }
                        lx.bump();
                    }
                }
                Some('/') if lx.peek_at(1) == Some('*') => {
                    let start = lx.pos();
                    lx.bump();
                    lx.bump();
                    let mut depth = 1;
                    while depth > 0 {
                        match (lx.peek(), lx.peek_at(1)) {
                            (None, _) => return err(ErrorKind::Unterminated, start),
                            (Some('/'), Some('*')) => {
                                lx.bump();
                                lx.bump();
                                depth += 1;
                            }
                            (Some('*'), Some('/')) => {
                                lx.bump();
                                lx.bump();
                                depth -= 1;
                            }
                            _ => {
                                lx.bump();
                            }
                        }
                    }
                }
                _ => break,
            }
        }
        let pos = lx.pos();
        let c = match lx.peek() {
            Some(c) => c,
            None => break,
        };
        let tok = if c.is_ascii_alphabetic() || c == '_' {
            let mut s = String::new();
            while let Some(c) = lx.peek() {
                if c.is_ascii_alphanumeric() || c == '_' {
                    s.push(c);
                    lx.bump();
                } else {
                    break;
                }
            }
            if s == "_" {
                Tok::Underscore
            } else if s.len() > 200 {
                return err(ErrorKind::BadToken, pos);
            } else if let Some(k) = keyword(&s) {
                Tok::Kw(k)
            } else {
                Tok::Ident(s)
            }
        } else if c.is_ascii_digit() {
            lex_number(&mut lx, pos)?
        } else if c == '"' {
            lex_string(&mut lx, pos)?
        } else if c == '\'' {
            lex_char(&mut lx, pos)?
        } else {
            lex_punct(&mut lx, pos)?
        };
        out.push(Token { tok, pos });
    }
    Ok(out)
}

fn lex_punct(lx: &mut Lexer, pos: Pos) -> Res<Tok> {
    let c = lx.peek().unwrap();
    let n = lx.peek_at(1);
    let two = |p: P, lx: &mut Lexer| {
        lx.bump();
        lx.bump();
        Tok::P(p)
    };
    let one = |p: P, lx: &mut Lexer| {
        lx.bump();
        Tok::P(p)
    };
    Ok(match (c, n) {
        ('#', Some('[')) => two(P::HashBracket, lx),
        (':', Some(':')) => two(P::ColonColon, lx),
        ('.', Some('.')) => two(P::DotDot, lx),
        ('-', Some('>')) => two(P::Arrow, lx),
        ('=', Some('=')) => two(P::EqEq, lx),
        ('!', Some('=')) => two(P::NotEq, lx),
        ('<', Some('=')) => two(P::Le, lx),
        ('>', Some('=')) => two(P::Ge, lx),
        ('&', Some('&')) => two(P::AndAnd, lx),
        ('|', Some('|')) => two(P::OrOr, lx),
        ('<', Some('<')) => two(P::Shl, lx),
        ('>', Some('>')) => two(P::Shr, lx),
        ('+', Some('+')) => two(P::PlusPlus, lx),
        ('(', _) => one(P::LParen, lx),
        (')', _) => one(P::RParen, lx),
        ('[', _) => one(P::LBracket, lx),
        (']', _) => one(P::RBracket, lx),
        ('{', _) => one(P::LBrace, lx),
        ('}', _) => one(P::RBrace, lx),
        (',', _) => one(P::Comma, lx),
        (';', _) => one(P::Semi, lx),
        (':', _) => one(P::Colon, lx),
        ('.', _) => one(P::Dot, lx),
        ('|', _) => one(P::Pipe, lx),
        ('+', _) => one(P::Plus, lx),
        ('-', _) => one(P::Minus, lx),
        ('*', _) => one(P::Star, lx),
        ('/', _) => one(P::Slash, lx),
        ('%', _) => one(P::Percent, lx),
        ('!', _) => one(P::Bang, lx),
        ('~', _) => one(P::Tilde, lx),
        ('&', _) => one(P::Amp, lx),
        ('^', _) => one(P::Caret, lx),
        ('<', _) => one(P::Lt, lx),
        ('>', _) => one(P::Gt, lx),
        ('=', _) => one(P::Eq, lx),
        _ => return err(ErrorKind::BadToken, pos),
    })
}

/// Reads a digit run (digits and `_`), appending the digits to `out`.
fn digit_run(lx: &mut Lexer, out: &mut String) {
    while let Some(c) = lx.peek() {
        if c.is_ascii_digit() {
            out.push(c);
            lx.bump();
        } else if c == '_' {
            lx.bump();
        } else {
            break;
        }
    }
}

fn lex_number(lx: &mut Lexer, pos: Pos) -> Res<Tok> {
    if lx.peek() == Some('0') {
        let radix = match lx.peek_at(1) {
            Some('x') => Some(16),
            Some('b') => Some(2),
            _ => None,
        };
        if let Some(radix) = radix {
            lx.bump();
            lx.bump();
            let ok = |c: char| c.to_digit(radix).is_some();
            match lx.peek() {
                Some(c) if ok(c) => {}
                _ => return err(ErrorKind::BadToken, pos),
            }
            let mut value: u128 = 0;
            let mut overflow = false;
            while let Some(c) = lx.peek() {
                if let Some(d) = c.to_digit(radix) {
                    if !overflow {
                        value = value * radix as u128 + d as u128;
                        if value > i64::MAX as u128 {
                            overflow = true;
                        }
                    }
                    lx.bump();
                } else if c == '_' {
                    lx.bump();
                } else {
                    break;
                }
            }
            if overflow {
                return err(ErrorKind::IntRange, pos);
            }
            return Ok(Tok::Int(value as i64));
        }
    }
    let mut int_digits = String::new();
    digit_run(lx, &mut int_digits);
    let mut is_float = false;
    let mut text = int_digits.clone();
    // fraction
    if lx.peek() == Some('.') && lx.peek_at(1).map_or(false, |c| c.is_ascii_digit()) {
        lx.bump();
        text.push('.');
        digit_run(lx, &mut text);
        is_float = true;
    }
    // exponent
    if matches!(lx.peek(), Some('e') | Some('E')) {
        let (sign_len, sign) = match lx.peek_at(1) {
            Some('+') => (1, Some('+')),
            Some('-') => (1, Some('-')),
            _ => (0, None),
        };
        if lx.peek_at(1 + sign_len).map_or(false, |c| c.is_ascii_digit()) {
            lx.bump();
            text.push('e');
            if sign_len == 1 {
                lx.bump();
                text.push(sign.unwrap());
            }
            digit_run(lx, &mut text);
            is_float = true;
        }
    }
    if is_float {
        let v: f64 = text.parse().unwrap_or(f64::NAN);
        Ok(Tok::Float(v))
    } else {
        let mut v: u128 = 0;
        for c in int_digits.chars() {
            v = v * 10 + c.to_digit(10).unwrap() as u128;
            if v > i64::MAX as u128 {
                return err(ErrorKind::IntRange, pos);
            }
        }
        Ok(Tok::Int(v as i64))
    }
}

/// Reads one escape after the backslash has been seen at `start` (the
/// backslash itself is the current character).
fn lex_escape(lx: &mut Lexer, start: Pos) -> Res<char> {
    lx.bump(); // the backslash
    let bad = || err(ErrorKind::BadEscape, start);
    let c = match lx.peek() {
        Some(c) => c,
        None => return bad(),
    };
    let r = match c {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        '0' => '\0',
        '\\' => '\\',
        '\'' => '\'',
        '"' => '"',
        'u' => {
            lx.bump();
            if lx.peek() != Some('{') {
                return bad();
            }
            lx.bump();
            let mut v: u32 = 0;
            let mut n = 0;
            loop {
                match lx.peek() {
                    Some('}') => break,
                    Some(c) if hex_val(c).is_some() => {
                        n += 1;
                        if n > 6 {
                            return bad();
                        }
                        v = v * 16 + hex_val(c).unwrap();
                        lx.bump();
                    }
                    _ => return bad(),
                }
            }
            if n == 0 {
                return bad();
            }
            lx.bump(); // }
            return match char::from_u32(v) {
                Some(ch) => Ok(ch),
                None => bad(),
            };
        }
        _ => return bad(),
    };
    lx.bump();
    Ok(r)
}

fn lex_string(lx: &mut Lexer, pos: Pos) -> Res<Tok> {
    lx.bump();
    let mut s = Vec::new();
    loop {
        match lx.peek() {
            None | Some('\n') | Some('\r') => return err(ErrorKind::Unterminated, pos),
            Some('"') => {
                lx.bump();
                break;
            }
            Some('\\') => {
                let p = lx.pos();
                s.push(lex_escape(lx, p)?);
            }
            Some(c) => {
                s.push(c);
                lx.bump();
            }
        }
    }
    Ok(Tok::Str(Rc::new(s)))
}

fn lex_char(lx: &mut Lexer, pos: Pos) -> Res<Tok> {
    lx.bump();
    let c = match lx.peek() {
        None | Some('\n') | Some('\r') | Some('\'') => return err(ErrorKind::Unterminated, pos),
        Some('\\') => {
            let p = lx.pos();
            lex_escape(lx, p)?
        }
        Some(c) => {
            lx.bump();
            c
        }
    };
    if lx.peek() == Some('\'') {
        lx.bump();
        Ok(Tok::Char(c))
    } else {
        err(ErrorKind::Unterminated, pos)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn toks(s: &str) -> Vec<Tok> {
        lex(s).unwrap().into_iter().map(|t| t.tok).collect()
    }

    #[test]
    fn numbers() {
        assert_eq!(toks("1_000 0x_f"[..5].trim()), vec![Tok::Int(1000)]);
        assert_eq!(toks("0..3"), vec![Tok::Int(0), Tok::P(P::DotDot), Tok::Int(3)]);
        assert_eq!(toks("1_.5"), vec![Tok::Float(1.5)]);
        assert_eq!(toks("1e1_0"), vec![Tok::Float(1e10)]);
        assert_eq!(toks("1e_5"), vec![Tok::Int(1), Tok::Ident("e_5".into())]);
        assert_eq!(toks("0X1"), vec![Tok::Int(0), Tok::Ident("X1".into())]);
        assert!(lex("0x_1").is_err());
        assert_eq!(lex("9223372036854775808").unwrap_err().kind, ErrorKind::IntRange);
    }

    #[test]
    fn comments_and_strings() {
        assert_eq!(toks("/* a /* b */ c */ x"), vec![Tok::Ident("x".into())]);
        assert_eq!(lex("/* x").unwrap_err().kind, ErrorKind::Unterminated);
        assert_eq!(lex("\"ab\\q").unwrap_err().kind, ErrorKind::BadEscape);
        assert_eq!(lex("'ab'").unwrap_err().kind, ErrorKind::Unterminated);
        assert_eq!(toks("'\\u{41}'"), vec![Tok::Char('A')]);
    }
}
