//! Lexical analysis of KBL: comment stripping, logical-line assembly and
//! tokenisation.
//!
//! The *literal scanner* ([`scan_literal`]) is shared by all stages so they
//! agree on what is inside a string literal.

/// A string literal token: its raw content between the quotes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StrLit {
    pub double: bool,
    pub raw: Vec<u8>,
}

/// A token.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Tok {
    Ident(String),
    Int(i64),
    Str(StrLit),
    /// Punctuation or an operator.
    Sym(&'static str),
}

/// A byte that cannot begin a token, or an unterminated literal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LexError;

/// A logical line: its 1-based first physical line number and its tokens.
#[derive(Debug, Clone)]
pub struct Line {
    pub no: usize,
    pub toks: Vec<Tok>,
}

/// Given `s[i]` is a quote, returns the index just after the literal's
/// closing quote, or `None` if the line ends first.
pub fn scan_literal(s: &[u8], i: usize) -> Option<usize> {
    let mut j = i + 1;
    if s[i] == b'\'' {
        while j < s.len() {
            if s[j] == b'\'' {
                if s.get(j + 1) == Some(&b'\'') {
                    j += 2;
                } else {
                    return Some(j + 1);
                }
            } else {
                j += 1;
            }
        }
        return None;
    }
    while j < s.len() {
        match s[j] {
            b'\\' => {
                if j + 1 >= s.len() {
                    return None;
                }
                j += 2;
            }
            b'{' => {
                if s.get(j + 1) == Some(&b'{') {
                    j += 2;
                } else {
                    j = scan_region(s, j + 1)?;
                }
            }
            b'}' => j += if s.get(j + 1) == Some(&b'}') { 2 } else { 1 },
            b'"' => return Some(j + 1),
            _ => j += 1,
        }
    }
    None
}

/// Scans an interpolation region whose body starts at `j` (just after the
/// `{`); returns the index just after the closing `}`.
pub fn scan_region(s: &[u8], mut j: usize) -> Option<usize> {
    let mut depth = 1usize;
    while j < s.len() {
        match s[j] {
            b'"' | b'\'' => j = scan_literal(s, j)?,
            b'{' => {
                depth += 1;
                j += 1;
            }
            b'}' => {
                depth -= 1;
                j += 1;
                if depth == 0 {
                    return Some(j);
                }
            }
            _ => j += 1,
        }
    }
    None
}

/// Splits a source file into logical lines of tokens. On a lexical error
/// returns the line number of the logical line it belongs to.
pub fn lex_file(src: &[u8]) -> Result<Vec<Line>, usize> {
    let mut physical: Vec<&[u8]> = src.split(|&b| b == b'\n').collect();
    if src.last() == Some(&b'\n') || src.is_empty() {
        physical.pop();
    }
    let mut lines = Vec::new();
    let mut text: Vec<u8> = Vec::new();
    let mut start = 0usize;
    let mut depth: i64 = 0;
    for (idx, line) in physical.iter().enumerate() {
        let continuing = depth > 0;
        if !continuing {
            start = idx + 1;
            text.clear();
        }
        let mut i = 0;
        let mut cut = line.len();
        while i < line.len() {
            match line[i] {
                b'"' | b'\'' => {
                    i = scan_literal(line, i).ok_or(start)?;
                    continue;
                }
                b'#' => {
                    cut = i;
                    break;
                }
                b'(' | b'[' => depth += 1,
                b')' | b']' => {
                    depth -= 1;
                    if depth < 0 {
                        return Err(start);
                    }
                }
                _ => {}
            }
            i += 1;
        }
        let mut piece = &line[..cut];
        while let Some((&last, rest)) = piece.split_last() {
            if last == b' ' || last == b'\t' {
                piece = rest;
            } else {
                break;
            }
        }
        if continuing {
            text.push(b' ');
        }
        text.extend_from_slice(piece);
        if depth == 0 {
            if !text.iter().all(|&b| b == b' ' || b == b'\t') {
                let toks = tokenize(&text).map_err(|_| start)?;
                lines.push(Line { no: start, toks });
            }
            text.clear();
        }
    }
    if depth > 0 {
        return Err(start);
    }
    Ok(lines)
}

/// Splits text into tokens.
pub fn tokenize(s: &[u8]) -> Result<Vec<Tok>, LexError> {
    const TWO: [&str; 8] = ["|>", "||", "&&", "==", "!=", "<=", ">=", "++"];
    const ONE: [&str; 17] = ["(", ")", "[", "]", "{", "}", ",", "=", "<", ">", "~", "+", "-", "*", "/", "%", "!"];
    let mut toks = Vec::new();
    let mut i = 0;
    while i < s.len() {
        let b = s[i];
        if b == b' ' || b == b'\t' {
            i += 1;
        } else if b.is_ascii_alphabetic() || b == b'_' {
            let st = i;
            while i < s.len() && (s[i].is_ascii_alphanumeric() || s[i] == b'_') {
                i += 1;
            }
            toks.push(Tok::Ident(String::from_utf8_lossy(&s[st..i]).into_owned()));
        } else if b.is_ascii_digit() {
            let mut v: i64 = 0;
            while i < s.len() && s[i].is_ascii_digit() {
                v = v.wrapping_mul(10).wrapping_add(i64::from(s[i] - b'0'));
                i += 1;
            }
            toks.push(Tok::Int(v));
        } else if b == b'"' || b == b'\'' {
            let end = scan_literal(s, i).ok_or(LexError)?;
            toks.push(Tok::Str(StrLit { double: b == b'"', raw: s[i + 1..end - 1].to_vec() }));
            i = end;
        } else {
            let rest = &s[i..];
            if let Some(sym) = TWO.iter().find(|t| rest.starts_with(t.as_bytes())) {
                toks.push(Tok::Sym(sym));
                i += 2;
            } else if let Some(sym) = ONE.iter().find(|t| rest.starts_with(t.as_bytes())) {
                toks.push(Tok::Sym(sym));
                i += 1;
            } else {
                return Err(LexError);
            }
        }
    }
    Ok(toks)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lines(src: &str) -> Result<Vec<Line>, usize> {
        lex_file(src.as_bytes())
    }

    #[test]
    fn comments_and_blank_lines() {
        let l = lines("# c\n\nlet x = 1 # tail\n  \nlet y = \"a#b\"\n").unwrap();
        assert_eq!(l.len(), 2);
        assert_eq!(l[0].no, 3);
        assert_eq!(l[1].no, 5);
        assert_eq!(l[1].toks.len(), 4);
    }

    #[test]
    fn joins_bracketed_lines() {
        let l = lines("let x = f(\n 1,\n 2)\nlet y = 3").unwrap();
        assert_eq!(l.len(), 2);
        assert_eq!(l[0].no, 1);
        assert_eq!(l[1].no, 4);
    }

    #[test]
    fn lexical_errors_report_group_start() {
        assert_eq!(lines("let b = f(\n  \"unterminated\n)\n").unwrap_err(), 1);
        assert_eq!(lines("x\n)\n").unwrap_err(), 2);
        assert_eq!(lines("x\nf(\n1\n").unwrap_err(), 2);
        assert_eq!(lines("a | b").unwrap_err(), 1);
        assert_eq!(lines("a & b").unwrap_err(), 1);
        assert_eq!(lines("a $ b").unwrap_err(), 1);
    }

    #[test]
    fn nested_literal_in_interpolation() {
        let l = lines("cmd write(\"{join(xs, \", \")}\\n\")").unwrap();
        assert_eq!(l[0].toks.len(), 5);
    }

    #[test]
    fn brackets_in_strings_do_not_count() {
        let l = lines("let x = \"(\"\nlet y = '['\n").unwrap();
        assert_eq!(l.len(), 2);
    }

    #[test]
    fn operators_longest_first() {
        let l = lines("a |> b || c ++ d <= e").unwrap();
        let syms: Vec<_> = l[0].toks.iter().filter_map(|t| if let Tok::Sym(s) = t { Some(*s) } else { None }).collect();
        assert_eq!(syms, vec!["|>", "||", "++", "<="]);
    }
}
