//! Recursive-descent parser producing a [`Program`].

use crate::ast::{Atom, CmpOp, Const, Literal, Program, Rule, Term};
use crate::error::ParseError;
use crate::lexer::{tokenize, Spanned, Token};

/// Maximum number of arguments of a predicate.
pub const MAX_ARITY: usize = 16;

/// Parse a whole program.
///
/// ```
/// let p = datalog::parse("edge(a, b). path(X, Y) :- edge(X, Y). ?- path(a, X).").unwrap();
/// assert_eq!(p.rules.len(), 2);
/// assert_eq!(p.queries.len(), 1);
/// ```
pub fn parse(src: &str) -> Result<Program, ParseError> {
    let toks = tokenize(src)?;
    let mut p = Parser { toks, pos: 0, last: (1, 1) };
    let mut program = Program::default();
    while p.peek().is_some() {
        if p.eat(&Token::Query) {
            let atom = p.atom()?;
            p.expect(&Token::Dot, "`.` after query")?;
            program.queries.push(atom);
            continue;
        }
        let head = p.atom()?;
        let mut body = Vec::new();
        if p.eat(&Token::Implies) {
            loop {
                body.push(p.literal()?);
                if !p.eat(&Token::Comma) {
                    break;
                }
            }
        }
        p.expect(&Token::Dot, "`.` at end of clause")?;
        program.rules.push(Rule { head, body });
    }
    Ok(program)
}

struct Parser {
    toks: Vec<Spanned>,
    pos: usize,
    last: (usize, usize),
}

impl Parser {
    fn peek(&self) -> Option<&Token> {
        self.toks.get(self.pos).map(|s| &s.token)
    }

    fn peek_at(&self, n: usize) -> Option<&Token> {
        self.toks.get(self.pos + n).map(|s| &s.token)
    }

    fn error(&self, message: impl Into<String>) -> ParseError {
        let (line, column) = self.toks.get(self.pos).map_or(self.last, |s| (s.line, s.column));
        ParseError { message: message.into(), line, column }
    }

    fn next(&mut self) -> Option<Token> {
        let s = self.toks.get(self.pos)?;
        self.last = (s.line, s.column);
        self.pos += 1;
        Some(s.token.clone())
    }

    fn eat(&mut self, t: &Token) -> bool {
        if self.peek() == Some(t) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn expect(&mut self, t: &Token, what: &str) -> Result<(), ParseError> {
        if self.eat(t) {
            Ok(())
        } else {
            Err(self.error(format!("expected {what}")))
        }
    }

    fn atom(&mut self) -> Result<Atom, ParseError> {
        let pred = match self.next() {
            Some(Token::Ident(s)) => s,
            _ => {
                self.pos -= 1;
                return Err(self.error("expected a predicate name"));
            }
        };
        self.expect(&Token::LParen, "`(`")?;
        let mut args = vec![self.term()?];
        while self.eat(&Token::Comma) {
            args.push(self.term()?);
        }
        self.expect(&Token::RParen, "`)`")?;
        if args.len() > MAX_ARITY {
            self.pos -= 1;
            return Err(self.error(format!("predicates are limited to {MAX_ARITY} arguments")));
        }
        Ok(Atom { pred, args })
    }

    fn term(&mut self) -> Result<Term, ParseError> {
        match self.next() {
            Some(Token::Ident(s)) => Ok(Term::Const(Const::Sym(s))),
            Some(Token::Int(i)) => Ok(Term::Const(Const::Int(i))),
            Some(Token::Var(v)) => Ok(Term::Var(v)),
            Some(Token::Anon) => Ok(Term::Anon),
            _ => {
                self.pos -= 1;
                Err(self.error("expected a term"))
            }
        }
    }

    fn literal(&mut self) -> Result<Literal, ParseError> {
        if self.eat(&Token::Not) {
            return Ok(Literal::Neg(self.atom()?));
        }
        if matches!(self.peek(), Some(Token::Ident(_))) && self.peek_at(1) == Some(&Token::LParen) {
            return Ok(Literal::Pos(self.atom()?));
        }
        let lhs = self.term()?;
        let op = match self.next() {
            Some(Token::Lt) => CmpOp::Lt,
            Some(Token::Le) => CmpOp::Le,
            Some(Token::Gt) => CmpOp::Gt,
            Some(Token::Ge) => CmpOp::Ge,
            Some(Token::Eq) => CmpOp::Eq,
            Some(Token::Ne) => CmpOp::Ne,
            _ => {
                self.pos -= 1;
                return Err(self.error("expected a comparison operator"));
            }
        };
        let rhs = self.term()?;
        Ok(Literal::Cmp(lhs, op, rhs))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_all_clause_kinds() {
        let p = parse("f(1,a). r(X) :- f(X, _), not g(X), X >= -3. ?- r(Y).").unwrap();
        assert_eq!(p.rules[0].to_string(), "f(1, a).");
        assert_eq!(p.rules[1].to_string(), "r(X) :- f(X, _), not g(X), X >= -3.");
        assert_eq!(p.queries[0].to_string(), "r(Y)");
    }

    #[test]
    fn empty_and_comment_only() {
        assert_eq!(parse("").unwrap(), Program::default());
        assert_eq!(parse("  % nothing\n\t").unwrap(), Program::default());
    }

    #[test]
    fn syntax_errors() {
        assert!(parse("p(a)").is_err());
        assert!(parse("p().").is_err());
        assert!(parse("p(a) :- .").is_err());
        assert!(parse("X(a).").is_err());
    }
}
