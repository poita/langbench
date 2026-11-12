//! S-expression reader for the card database (SPEC.md section 5.1).
//!
//! The reader is deliberately tiny: it produces a tree of [`Sexpr`] values and
//! knows nothing about cards. [`Sexpr`] implements [`std::fmt::Display`] as the
//! *canonical printing* used by the `CARD` directive (SPEC.md 23.4).

use std::fmt;

/// One node of an s-expression tree.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Sexpr {
    /// A parenthesised list.
    List(Vec<Sexpr>),
    /// An atom matching `-?[0-9]+` whose value fits in an `i64`.
    Int(i64),
    /// Any other atom. Symbols are case-sensitive.
    Sym(String),
    /// A double-quoted string (no escapes). Holds the contents without quotes.
    Str(String),
}

/// Why a database text failed to tokenise or parse.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SexprError(pub String);

impl fmt::Display for SexprError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for SexprError {}

impl fmt::Display for Sexpr {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Sexpr::List(items) => {
                f.write_str("(")?;
                for (i, it) in items.iter().enumerate() {
                    if i > 0 {
                        f.write_str(" ")?;
                    }
                    write!(f, "{it}")?;
                }
                f.write_str(")")
            }
            Sexpr::Int(n) => write!(f, "{n}"),
            Sexpr::Sym(s) => f.write_str(s),
            Sexpr::Str(s) => write!(f, "\"{s}\""),
        }
    }
}

impl Sexpr {
    /// The list's elements, if this is a list.
    pub fn as_list(&self) -> Option<&[Sexpr]> {
        match self {
            Sexpr::List(v) => Some(v),
            _ => None,
        }
    }

    /// The symbol's text, if this is a symbol.
    pub fn as_sym(&self) -> Option<&str> {
        match self {
            Sexpr::Sym(s) => Some(s),
            _ => None,
        }
    }

    /// The integer value, if this is an integer atom.
    pub fn as_int(&self) -> Option<i64> {
        match self {
            Sexpr::Int(n) => Some(*n),
            _ => None,
        }
    }
}

fn is_space(c: char) -> bool {
    matches!(c, ' ' | '\t' | '\r' | '\n' | '\x0c' | '\x0b')
}

fn is_atom_char(c: char) -> bool {
    !is_space(c) && !matches!(c, '(' | ')' | ';' | '"')
}

fn is_integer_atom(s: &str) -> bool {
    let digits = s.strip_prefix('-').unwrap_or(s);
    !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit())
}

/// Parse a whole file into its sequence of top-level forms.
///
/// Top-level atoms are returned as-is; it is the caller's business to reject
/// them. Unbalanced parentheses, unterminated strings and integers that do not
/// fit in an `i64` are errors.
pub fn parse(text: &str) -> Result<Vec<Sexpr>, SexprError> {
    let chars: Vec<char> = text.chars().collect();
    let mut pos = 0usize;
    let mut stack: Vec<Vec<Sexpr>> = Vec::new();
    let mut top: Vec<Sexpr> = Vec::new();
    while pos < chars.len() {
        let c = chars[pos];
        if is_space(c) {
            pos += 1;
        } else if c == ';' {
            while pos < chars.len() && chars[pos] != '\n' {
                pos += 1;
            }
        } else if c == '(' {
            stack.push(std::mem::take(&mut top));
            pos += 1;
        } else if c == ')' {
            let parent = stack
                .pop()
                .ok_or_else(|| SexprError("unbalanced ')'".into()))?;
            let list = std::mem::replace(&mut top, parent);
            top.push(Sexpr::List(list));
            pos += 1;
        } else if c == '"' {
            let start = pos + 1;
            let mut end = start;
            loop {
                match chars.get(end) {
                    None | Some('\n') => {
                        return Err(SexprError("unterminated string".into()));
                    }
                    Some('"') => break,
                    Some(_) => end += 1,
                }
            }
            top.push(Sexpr::Str(chars[start..end].iter().collect()));
            pos = end + 1;
        } else {
            let start = pos;
            while pos < chars.len() && is_atom_char(chars[pos]) {
                pos += 1;
            }
            let atom: String = chars[start..pos].iter().collect();
            if is_integer_atom(&atom) {
                let n = atom
                    .parse::<i64>()
                    .map_err(|_| SexprError(format!("integer out of range: {atom}")))?;
                top.push(Sexpr::Int(n));
            } else {
                top.push(Sexpr::Sym(atom));
            }
        }
    }
    if !stack.is_empty() {
        return Err(SexprError("unbalanced '('".into()));
    }
    Ok(top)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_atoms_lists_strings() {
        let v = parse("(a 12 -3 \"x y\" (b))").unwrap();
        assert_eq!(v.len(), 1);
        assert_eq!(v[0].to_string(), "(a 12 -3 \"x y\" (b))");
    }

    #[test]
    fn comments_and_odd_whitespace() {
        let v = parse("(a ; hi (\n\t b\x0c(c)\x0b)").unwrap();
        assert_eq!(v[0].to_string(), "(a b (c))");
    }

    #[test]
    fn string_may_contain_punctuation() {
        let v = parse("(n \"Odd (Name); x\")").unwrap();
        assert_eq!(v[0].to_string(), "(n \"Odd (Name); x\")");
    }

    #[test]
    fn errors() {
        assert!(parse("(a").is_err());
        assert!(parse("a)").is_err());
        assert!(parse("(\"abc)").is_err());
        assert!(parse("(\"a\nb\")").is_err());
        assert!(parse("(99999999999999999999)").is_err());
    }

    #[test]
    fn integer_vs_symbol() {
        let v = parse("-0 007 - 1a --1 -9223372036854775808").unwrap();
        assert_eq!(v[0], Sexpr::Int(0));
        assert_eq!(v[1], Sexpr::Int(7));
        assert_eq!(v[2], Sexpr::Sym("-".into()));
        assert_eq!(v[3], Sexpr::Sym("1a".into()));
        assert_eq!(v[4], Sexpr::Sym("--1".into()));
        assert_eq!(v[5], Sexpr::Int(i64::MIN));
    }
}
