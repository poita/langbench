//! A recursive-descent parser for formulas.
//!
//! ```
//! use spreadsheet::parser::parse_formula;
//! let expr = parse_formula("1+2*3").unwrap();
//! # let _ = expr;
//! ```

use crate::ast::{Aggregate, Arg, BinOp, Expr};
use crate::cell::{CellRef, Range};
use crate::value::ErrorCode;
use std::fmt;
use std::rc::Rc;

/// A syntax error in a formula.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct ParseError {
    /// What went wrong.
    pub message: String,
    /// Byte offset into the formula text (after the `=`).
    pub position: usize,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "syntax error at {}: {}", self.position, self.message)
    }
}

impl std::error::Error for ParseError {}

#[derive(Clone, PartialEq, Debug)]
enum Tok {
    Number(f64),
    Str(Rc<str>),
    /// A reference token; `None` if it is not a valid cell name.
    Ref(Option<CellRef>),
    Name(String),
    Op(BinOp),
    Minus,
    Plus,
    LParen,
    RParen,
    Comma,
    Colon,
}

fn lex(src: &str) -> Result<Vec<(Tok, usize)>, ParseError> {
    let b = src.as_bytes();
    let err = |message: &str, position| ParseError { message: message.to_string(), position };
    let mut toks = Vec::new();
    let mut i = 0;
    while i < b.len() {
        let start = i;
        let c = b[i];
        let tok = match c {
            b' ' => {
                i += 1;
                continue;
            }
            b'0'..=b'9' => {
                while i < b.len() && b[i].is_ascii_digit() {
                    i += 1;
                }
                if i + 1 < b.len() && b[i] == b'.' && b[i + 1].is_ascii_digit() {
                    i += 1;
                    while i < b.len() && b[i].is_ascii_digit() {
                        i += 1;
                    }
                }
                let n: f64 = src[start..i].parse().map_err(|_| err("bad number", start))?;
                Tok::Number(n)
            }
            b'"' => {
                let end = src[i + 1..].find('"').ok_or_else(|| err("unterminated string", i))?;
                let s = &src[i + 1..i + 1 + end];
                i += end + 2;
                Tok::Str(Rc::from(s))
            }
            b'A'..=b'Z' => {
                while i < b.len() && b[i].is_ascii_uppercase() {
                    i += 1;
                }
                let letters_end = i;
                while i < b.len() && b[i].is_ascii_digit() {
                    i += 1;
                }
                if i > letters_end {
                    Tok::Ref(CellRef::from_parts(&b[start..letters_end], &b[letters_end..i]))
                } else {
                    Tok::Name(src[start..i].to_string())
                }
            }
            _ => {
                i += 1;
                match c {
                    b'+' => Tok::Plus,
                    b'-' => Tok::Minus,
                    b'*' => Tok::Op(BinOp::Mul),
                    b'/' => Tok::Op(BinOp::Div),
                    b'&' => Tok::Op(BinOp::Concat),
                    b'=' => Tok::Op(BinOp::Eq),
                    b'<' => match b.get(i) {
                        Some(b'>') => {
                            i += 1;
                            Tok::Op(BinOp::Ne)
                        }
                        Some(b'=') => {
                            i += 1;
                            Tok::Op(BinOp::Le)
                        }
                        _ => Tok::Op(BinOp::Lt),
                    },
                    b'>' => match b.get(i) {
                        Some(b'=') => {
                            i += 1;
                            Tok::Op(BinOp::Ge)
                        }
                        _ => Tok::Op(BinOp::Gt),
                    },
                    b'(' => Tok::LParen,
                    b')' => Tok::RParen,
                    b',' => Tok::Comma,
                    b':' => Tok::Colon,
                    _ => return Err(err("unexpected character", start)),
                }
            }
        };
        toks.push((tok, start));
    }
    Ok(toks)
}

struct Parser {
    toks: Vec<(Tok, usize)>,
    pos: usize,
    end: usize,
    invalid_ref: bool,
}

impl Parser {
    fn peek(&self) -> Option<&Tok> {
        self.toks.get(self.pos).map(|t| &t.0)
    }

    fn error<T>(&self, message: &str) -> Result<T, ParseError> {
        let position = self.toks.get(self.pos).map_or(self.end, |t| t.1);
        Err(ParseError { message: message.to_string(), position })
    }

    fn expect(&mut self, tok: Tok, what: &str) -> Result<(), ParseError> {
        if self.peek() == Some(&tok) {
            self.pos += 1;
            Ok(())
        } else {
            self.error(&format!("expected {what}"))
        }
    }

    fn cmp(&mut self) -> Result<Expr, ParseError> {
        let mut lhs = self.cat()?;
        while let Some(Tok::Op(op @ (BinOp::Eq | BinOp::Ne | BinOp::Lt | BinOp::Gt | BinOp::Le | BinOp::Ge))) =
            self.peek().cloned()
        {
            self.pos += 1;
            let rhs = self.cat()?;
            lhs = Expr::Binary(op, Box::new(lhs), Box::new(rhs));
        }
        Ok(lhs)
    }

    fn cat(&mut self) -> Result<Expr, ParseError> {
        let mut lhs = self.add()?;
        while self.peek() == Some(&Tok::Op(BinOp::Concat)) {
            self.pos += 1;
            let rhs = self.add()?;
            lhs = Expr::Binary(BinOp::Concat, Box::new(lhs), Box::new(rhs));
        }
        Ok(lhs)
    }

    fn add(&mut self) -> Result<Expr, ParseError> {
        let mut lhs = self.mul()?;
        loop {
            let op = match self.peek() {
                Some(Tok::Plus) => BinOp::Add,
                Some(Tok::Minus) => BinOp::Sub,
                _ => return Ok(lhs),
            };
            self.pos += 1;
            let rhs = self.mul()?;
            lhs = Expr::Binary(op, Box::new(lhs), Box::new(rhs));
        }
    }

    fn mul(&mut self) -> Result<Expr, ParseError> {
        let mut lhs = self.unary()?;
        while let Some(Tok::Op(op @ (BinOp::Mul | BinOp::Div))) = self.peek().cloned() {
            self.pos += 1;
            let rhs = self.unary()?;
            lhs = Expr::Binary(op, Box::new(lhs), Box::new(rhs));
        }
        Ok(lhs)
    }

    fn unary(&mut self) -> Result<Expr, ParseError> {
        if self.peek() == Some(&Tok::Minus) {
            self.pos += 1;
            return Ok(Expr::Neg(Box::new(self.unary()?)));
        }
        self.primary()
    }

    fn reference(&mut self, r: Option<CellRef>) -> Option<CellRef> {
        if r.is_none() {
            self.invalid_ref = true;
        }
        r
    }

    fn primary(&mut self) -> Result<Expr, ParseError> {
        let Some(tok) = self.peek().cloned() else {
            return self.error("unexpected end of formula");
        };
        match tok {
            Tok::Number(n) => {
                self.pos += 1;
                Ok(Expr::Number(n))
            }
            Tok::Str(s) => {
                self.pos += 1;
                Ok(Expr::Str(s))
            }
            Tok::Ref(r) => {
                self.pos += 1;
                Ok(match self.reference(r) {
                    Some(c) => Expr::Ref(c),
                    None => Expr::Error(ErrorCode::Ref),
                })
            }
            Tok::LParen => {
                self.pos += 1;
                let e = self.cmp()?;
                self.expect(Tok::RParen, "`)`")?;
                Ok(e)
            }
            Tok::Name(name) => {
                self.pos += 1;
                self.expect(Tok::LParen, "`(` after function name")?;
                if name == "IF" {
                    let c = self.cmp()?;
                    self.expect(Tok::Comma, "`,`")?;
                    let a = self.cmp()?;
                    self.expect(Tok::Comma, "`,`")?;
                    let b = self.cmp()?;
                    self.expect(Tok::RParen, "`)`")?;
                    return Ok(Expr::If(Box::new(c), Box::new(a), Box::new(b)));
                }
                let func = match name.as_str() {
                    "SUM" => Aggregate::Sum,
                    "MIN" => Aggregate::Min,
                    "MAX" => Aggregate::Max,
                    "AVG" => Aggregate::Avg,
                    "COUNT" => Aggregate::Count,
                    _ => return self.error(&format!("unknown function {name}")),
                };
                let mut args = vec![self.arg()?];
                while self.peek() == Some(&Tok::Comma) {
                    self.pos += 1;
                    args.push(self.arg()?);
                }
                self.expect(Tok::RParen, "`)`")?;
                Ok(Expr::Call(func, args))
            }
            _ => self.error("unexpected token"),
        }
    }

    fn arg(&mut self) -> Result<Arg, ParseError> {
        if let (Some(Tok::Ref(a)), Some((Tok::Colon, _))) = (self.peek().cloned(), self.toks.get(self.pos + 1)) {
            self.pos += 2;
            let Some(Tok::Ref(b)) = self.peek().cloned() else {
                return self.error("expected a cell reference after `:`");
            };
            self.pos += 1;
            let (a, b) = (self.reference(a), self.reference(b));
            return Ok(match (a, b) {
                (Some(a), Some(b)) => Arg::Range(Range::new(a, b)),
                _ => Arg::Expr(Expr::Error(ErrorCode::Ref)),
            });
        }
        Ok(Arg::Expr(self.cmp()?))
    }
}

/// Parses formula text (without the leading `=`) into a syntax tree.
///
/// A formula containing any invalid reference (more than two column letters,
/// row 0, a row above 9999, a leading zero) parses successfully to
/// `Expr::Error(ErrorCode::Ref)`, so that it evaluates to `#REF!` and has no
/// dependencies. Genuine syntax errors are reported as [`ParseError`].
pub fn parse_formula(src: &str) -> Result<Expr, ParseError> {
    let toks = lex(src)?;
    let mut p = Parser { toks, pos: 0, end: src.len(), invalid_ref: false };
    let expr = p.cmp()?;
    if p.pos != p.toks.len() {
        return p.error("unexpected trailing input");
    }
    if p.invalid_ref {
        return Ok(Expr::Error(ErrorCode::Ref));
    }
    Ok(expr)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn c(name: &str) -> CellRef {
        CellRef::parse(name).unwrap()
    }

    #[test]
    fn precedence() {
        let e = parse_formula("1+2*3").unwrap();
        assert_eq!(
            e,
            Expr::Binary(
                BinOp::Add,
                Box::new(Expr::Number(1.0)),
                Box::new(Expr::Binary(BinOp::Mul, Box::new(Expr::Number(2.0)), Box::new(Expr::Number(3.0))))
            )
        );
    }

    #[test]
    fn left_associative() {
        let e = parse_formula("1-2-3").unwrap();
        let Expr::Binary(BinOp::Sub, lhs, _) = e else { panic!() };
        assert!(matches!(*lhs, Expr::Binary(BinOp::Sub, _, _)));
    }

    #[test]
    fn range_and_function() {
        let e = parse_formula("SUM(B2:A1, 3)").unwrap();
        assert_eq!(
            e,
            Expr::Call(
                Aggregate::Sum,
                vec![Arg::Range(Range::new(c("A1"), c("B2"))), Arg::Expr(Expr::Number(3.0))]
            )
        );
    }

    #[test]
    fn invalid_reference_poisons_formula() {
        for f in ["AAA1+1", "A0", "IF(1,2,A10000)", "SUM(A1:A01)", "SUM(A01:A1)"] {
            assert_eq!(parse_formula(f).unwrap(), Expr::Error(ErrorCode::Ref), "{f}");
        }
    }

    #[test]
    fn dependencies_include_both_branches_and_ranges() {
        let e = parse_formula("IF(A1,B1,SUM(C1:C2))").unwrap();
        let mut deps = Vec::new();
        e.collect_dependencies(&mut deps);
        assert_eq!(deps, [c("A1"), c("B1"), c("C1"), c("C2")]);
    }

    #[test]
    fn syntax_errors() {
        for f in ["", "1+", "(1", "FOO(1)", "SUM()", "1 2", "A1:B2", "#"] {
            assert!(parse_formula(f).is_err(), "{f}");
        }
    }

    #[test]
    fn strings_keep_spaces_and_unicode() {
        assert_eq!(parse_formula("\" é \"").unwrap(), Expr::Str(Rc::from(" é ")));
    }
}
