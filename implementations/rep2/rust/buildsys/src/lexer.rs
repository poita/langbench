//! Lexing of KBL build files: comment stripping, logical-line assembly and
//! tokenisation. All three stages share one literal scanner so they always
//! agree about where a string literal ends.

/// Binary and unary operators; variants are named after their spellings
/// (see [`Op::spelling`]).
#[allow(missing_docs)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Op {
    Pipe,
    Or,
    And,
    Eq,
    Ne,
    Le,
    Ge,
    Lt,
    Gt,
    Concat,
    Tilde,
    Plus,
    Minus,
    Star,
    Slash,
    Percent,
    Not,
}

impl Op {
    /// The operator's source spelling.
    pub fn spelling(self) -> &'static str {
        match self {
            Op::Pipe => "|>",
            Op::Or => "||",
            Op::And => "&&",
            Op::Eq => "==",
            Op::Ne => "!=",
            Op::Le => "<=",
            Op::Ge => ">=",
            Op::Lt => "<",
            Op::Gt => ">",
            Op::Concat => "++",
            Op::Tilde => "~",
            Op::Plus => "+",
            Op::Minus => "-",
            Op::Star => "*",
            Op::Slash => "/",
            Op::Percent => "%",
            Op::Not => "!",
        }
    }
}

/// A string literal token.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StrTok {
    /// Single-quoted: the already-unescaped content.
    Single(Vec<u8>),
    /// Double-quoted: the raw bytes between the quotes.
    Double(Vec<u8>),
}

/// A token.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Tok {
    Ident(String),
    Int(i64),
    Str(StrTok),
    LParen,
    RParen,
    LBracket,
    RBracket,
    LBrace,
    RBrace,
    Comma,
    Assign,
    Op(Op),
}

/// A logical line: its 1-based first physical line number and its tokens.
#[derive(Debug, Clone)]
pub struct Line {
    pub no: usize,
    pub toks: Vec<Tok>,
}

/// Marker for a lexical failure; the caller attaches the line number.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LexError;

type LResult<T> = Result<T, LexError>;

/// `i` is just after the opening `'`; returns the index just after the close.
fn skip_single(b: &[u8], mut i: usize) -> LResult<usize> {
    loop {
        match b.get(i) {
            None => return Err(LexError),
            Some(b'\'') => {
                if b.get(i + 1) == Some(&b'\'') {
                    i += 2;
                } else {
                    return Ok(i + 1);
                }
            }
            Some(_) => i += 1,
        }
    }
}

/// `i` is just after the opening `"`; returns the index just after the close.
fn skip_double(b: &[u8], mut i: usize) -> LResult<usize> {
    loop {
        match b.get(i) {
            None => return Err(LexError),
            Some(b'\\') => {
                if i + 1 >= b.len() {
                    return Err(LexError);
                }
                i += 2;
            }
            Some(b'{') => {
                if b.get(i + 1) == Some(&b'{') {
                    i += 2;
                } else {
                    i = skip_interp(b, i + 1)?;
                }
            }
            Some(b'"') => return Ok(i + 1),
            Some(_) => i += 1,
        }
    }
}

/// `i` is just after the `{` opening an interpolation; returns the index just
/// after the matching `}`.
fn skip_interp(b: &[u8], mut i: usize) -> LResult<usize> {
    let mut depth = 1usize;
    loop {
        match b.get(i) {
            None => return Err(LexError),
            Some(b'"') => i = skip_double(b, i + 1)?,
            Some(b'\'') => i = skip_single(b, i + 1)?,
            Some(b'{') => {
                depth += 1;
                i += 1;
            }
            Some(b'}') => {
                depth -= 1;
                i += 1;
                if depth == 0 {
                    return Ok(i);
                }
            }
            Some(_) => i += 1,
        }
    }
}

/// Finds the end of the interpolation body that starts at `start` (just after
/// the `{`) inside a double-quoted literal's content; returns the index of the
/// closing `}`.
pub(crate) fn interpolation_end(content: &[u8], start: usize) -> LResult<usize> {
    skip_interp(content, start).map(|after| after - 1)
}

/// Scans one physical line: strips the comment and trailing blanks, updating
/// the running bracket depth.
fn scan_physical(pl: &[u8], depth: &mut i64) -> LResult<Vec<u8>> {
    let mut i = 0;
    let mut end = pl.len();
    while i < pl.len() {
        match pl[i] {
            b'"' => i = skip_double(pl, i + 1)?,
            b'\'' => i = skip_single(pl, i + 1)?,
            b'#' => {
                end = i;
                break;
            }
            b'(' | b'[' => {
                *depth += 1;
                i += 1;
            }
            b')' | b']' => {
                *depth -= 1;
                if *depth < 0 {
                    return Err(LexError);
                }
                i += 1;
            }
            _ => i += 1,
        }
    }
    let mut stripped = &pl[..end];
    while let [rest @ .., b' ' | b'\t'] = stripped {
        stripped = rest;
    }
    Ok(stripped.to_vec())
}

/// Lexes a whole build file into logical lines of tokens.
///
/// On a lexical error returns the line number (of the first physical line of
/// the offending logical line).
pub fn lex(src: &[u8]) -> Result<Vec<Line>, usize> {
    let mut lines = Vec::new();
    let mut physical: Vec<&[u8]> = src.split(|&b| b == b'\n').collect();
    if src.last() == Some(&b'\n') || src.is_empty() {
        physical.pop();
    }
    let mut text: Vec<u8> = Vec::new();
    let mut group_start: Option<usize> = None;
    let mut depth = 0i64;
    for (idx, pl) in physical.iter().enumerate() {
        let lineno = idx + 1;
        let start = *group_start.get_or_insert(lineno);
        let stripped = scan_physical(pl, &mut depth).map_err(|_| start)?;
        if lineno != start {
            text.push(b' ');
        }
        text.extend_from_slice(&stripped);
        if depth == 0 {
            group_start = None;
            if text.iter().any(|&b| b != b' ' && b != b'\t') {
                let toks = tokenize(&text).map_err(|_| start)?;
                lines.push(Line { no: start, toks });
            }
            text.clear();
        }
    }
    if let Some(start) = group_start {
        return Err(start);
    }
    Ok(lines)
}

/// Splits a logical line (or an interpolation body) into tokens.
pub fn tokenize(b: &[u8]) -> LResult<Vec<Tok>> {
    let mut toks = Vec::new();
    let mut i = 0;
    while i < b.len() {
        let c = b[i];
        match c {
            b' ' | b'\t' => i += 1,
            b'a'..=b'z' | b'A'..=b'Z' | b'_' => {
                let s = i;
                while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'_') {
                    i += 1;
                }
                toks.push(Tok::Ident(String::from_utf8_lossy(&b[s..i]).into_owned()));
            }
            b'0'..=b'9' => {
                let mut v: i64 = 0;
                while i < b.len() && b[i].is_ascii_digit() {
                    v = v.wrapping_mul(10).wrapping_add(i64::from(b[i] - b'0'));
                    i += 1;
                }
                toks.push(Tok::Int(v));
            }
            b'"' => {
                let end = skip_double(b, i + 1)?;
                toks.push(Tok::Str(StrTok::Double(b[i + 1..end - 1].to_vec())));
                i = end;
            }
            b'\'' => {
                let end = skip_single(b, i + 1)?;
                let raw = &b[i + 1..end - 1];
                let mut out = Vec::with_capacity(raw.len());
                let mut k = 0;
                while k < raw.len() {
                    out.push(raw[k]);
                    k += if raw[k] == b'\'' { 2 } else { 1 };
                }
                toks.push(Tok::Str(StrTok::Single(out)));
                i = end;
            }
            b'(' => {
                toks.push(Tok::LParen);
                i += 1;
            }
            b')' => {
                toks.push(Tok::RParen);
                i += 1;
            }
            b'[' => {
                toks.push(Tok::LBracket);
                i += 1;
            }
            b']' => {
                toks.push(Tok::RBracket);
                i += 1;
            }
            b'{' => {
                toks.push(Tok::LBrace);
                i += 1;
            }
            b'}' => {
                toks.push(Tok::RBrace);
                i += 1;
            }
            b',' => {
                toks.push(Tok::Comma);
                i += 1;
            }
            _ => {
                let two = b.get(i + 1).copied();
                let (tok, len) = match (c, two) {
                    (b'|', Some(b'>')) => (Tok::Op(Op::Pipe), 2),
                    (b'|', Some(b'|')) => (Tok::Op(Op::Or), 2),
                    (b'&', Some(b'&')) => (Tok::Op(Op::And), 2),
                    (b'=', Some(b'=')) => (Tok::Op(Op::Eq), 2),
                    (b'!', Some(b'=')) => (Tok::Op(Op::Ne), 2),
                    (b'<', Some(b'=')) => (Tok::Op(Op::Le), 2),
                    (b'>', Some(b'=')) => (Tok::Op(Op::Ge), 2),
                    (b'+', Some(b'+')) => (Tok::Op(Op::Concat), 2),
                    (b'=', _) => (Tok::Assign, 1),
                    (b'<', _) => (Tok::Op(Op::Lt), 1),
                    (b'>', _) => (Tok::Op(Op::Gt), 1),
                    (b'~', _) => (Tok::Op(Op::Tilde), 1),
                    (b'+', _) => (Tok::Op(Op::Plus), 1),
                    (b'-', _) => (Tok::Op(Op::Minus), 1),
                    (b'*', _) => (Tok::Op(Op::Star), 1),
                    (b'/', _) => (Tok::Op(Op::Slash), 1),
                    (b'%', _) => (Tok::Op(Op::Percent), 1),
                    (b'!', _) => (Tok::Op(Op::Not), 1),
                    _ => return Err(LexError),
                };
                toks.push(tok);
                i += len;
            }
        }
    }
    Ok(toks)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lines(s: &str) -> Result<Vec<Line>, usize> {
        lex(s.as_bytes())
    }

    #[test]
    fn comments_and_blank_lines() {
        let l = lines("# c\n\nlet x = 1 # tail\n   \n").unwrap();
        assert_eq!(l.len(), 1);
        assert_eq!(l[0].no, 3);
        assert_eq!(l[0].toks.len(), 4);
    }

    #[test]
    fn hash_inside_string_is_content() {
        let l = lines("let x = \"a#b\"\n").unwrap();
        assert_eq!(l[0].toks.len(), 4);
        let l = lines("let x = \"{\"#\"}\"\n").unwrap();
        assert_eq!(l[0].toks.len(), 4);
    }

    #[test]
    fn bracket_joining_reports_first_line() {
        let l = lines("let b = f(\n  1,\n  2\n)\nlet c = 1\n").unwrap();
        assert_eq!(l.len(), 2);
        assert_eq!(l[0].no, 1);
        assert_eq!(l[1].no, 5);
        assert_eq!(lines("let b = f(\n  \"unterminated\n)\n").unwrap_err(), 1);
        assert_eq!(lines("x\n)\n").unwrap_err(), 2);
        assert_eq!(lines("a\nf(\n1\n").unwrap_err(), 2);
    }

    #[test]
    fn nested_literal_in_interpolation() {
        let l = lines("cmd write(\"{join(xs, \", \")}\\n\")\n").unwrap();
        assert_eq!(l.len(), 1);
        assert_eq!(l[0].toks.len(), 5);
    }

    #[test]
    fn operators_longest_first() {
        let l = lines("a |> b || c && d == e != f <= g >= h ++ i\n").unwrap();
        let ops: Vec<_> = l[0]
            .toks
            .iter()
            .filter_map(|t| if let Tok::Op(o) = t { Some(*o) } else { None })
            .collect();
        assert_eq!(
            ops,
            vec![Op::Pipe, Op::Or, Op::And, Op::Eq, Op::Ne, Op::Le, Op::Ge, Op::Concat]
        );
        assert!(lines("a | b\n").is_err());
        assert!(lines("a & b\n").is_err());
        assert!(lines("a @ b\n").is_err());
    }

    #[test]
    fn single_quote_escape() {
        let l = lines("'it''s'\n").unwrap();
        assert_eq!(l[0].toks, vec![Tok::Str(StrTok::Single(b"it's".to_vec()))]);
    }

    #[test]
    fn unterminated_string_is_lexical() {
        assert_eq!(lines("let x = \"abc\n").unwrap_err(), 1);
        assert_eq!(lines("let x = \"a{b\"\n").unwrap_err(), 1);
    }
}
