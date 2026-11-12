//! Recursive-descent parser producing a [`Program`].

use crate::ast::*;
use crate::constant::Constant;
use crate::error::Error;
use crate::lexer::{tokenize, Tok, Token};
use crate::relation::MAX_ARITY;

/// Parse a whole program.
///
/// # Errors
/// Returns [`Error::Parse`] on malformed input and [`Error::ArityTooLarge`]
/// if an atom has more than [`MAX_ARITY`] arguments.
pub fn parse(source: &str) -> Result<Program, Error> {
    let tokens = tokenize(source)?;
    let mut p = Parser { tokens, pos: 0, preds: PredicateTable::default() };
    let mut rules = Vec::new();
    let mut queries = Vec::new();
    while p.pos < p.tokens.len() {
        if p.peek() == Some(&Tok::QueryStart) {
            p.pos += 1;
            let atom = p.atom()?;
            p.expect(Tok::Dot, "`.`")?;
            queries.push(atom);
        } else {
            rules.push(p.rule()?);
        }
    }
    Ok(Program { predicates: p.preds.list, rules, queries })
}

struct Parser {
    tokens: Vec<Token>,
    pos: usize,
    preds: PredicateTable,
}

impl Parser {
    fn peek(&self) -> Option<&Tok> {
        self.tokens.get(self.pos).map(|t| &t.tok)
    }

    fn line(&self) -> usize {
        self.tokens
            .get(self.pos)
            .or(self.tokens.last())
            .map_or(1, |t| t.line)
    }

    fn error<T>(&self, message: String) -> Result<T, Error> {
        Err(Error::Parse { line: self.line(), message })
    }

    fn next(&mut self) -> Result<Tok, Error> {
        match self.tokens.get(self.pos) {
            Some(t) => {
                self.pos += 1;
                Ok(t.tok.clone())
            }
            None => self.error("unexpected end of input".into()),
        }
    }

    fn expect(&mut self, want: Tok, what: &str) -> Result<(), Error> {
        let line = self.line();
        let got = self.next()?;
        if got == want {
            Ok(())
        } else {
            Err(Error::Parse { line, message: format!("expected {what}, found {got:?}") })
        }
    }

    fn rule(&mut self) -> Result<Rule, Error> {
        let line = self.line();
        let head = self.atom()?;
        let mut body = Vec::new();
        if self.peek() == Some(&Tok::Implies) {
            self.pos += 1;
            loop {
                body.push(self.literal()?);
                if self.peek() == Some(&Tok::Comma) {
                    self.pos += 1;
                } else {
                    break;
                }
            }
        }
        self.expect(Tok::Dot, "`.`")?;
        Ok(Rule { head, body, line })
    }

    fn literal(&mut self) -> Result<Literal, Error> {
        match self.peek() {
            Some(Tok::Not) => {
                self.pos += 1;
                Ok(Literal::Neg(self.atom()?))
            }
            Some(Tok::Ident(_))
                if self.tokens.get(self.pos + 1).map(|t| &t.tok) == Some(&Tok::LParen) =>
            {
                Ok(Literal::Pos(self.atom()?))
            }
            _ => {
                let l = self.term()?;
                let op = match self.next()? {
                    Tok::Cmp(op) => op,
                    other => return self.error(format!("expected comparison, found {other:?}")),
                };
                let r = self.term()?;
                Ok(Literal::Cmp(l, op, r))
            }
        }
    }

    fn atom(&mut self) -> Result<Atom, Error> {
        let name = match self.next()? {
            Tok::Ident(n) => n,
            other => return self.error(format!("expected predicate name, found {other:?}")),
        };
        self.expect(Tok::LParen, "`(`")?;
        let mut terms = vec![self.term()?];
        while self.peek() == Some(&Tok::Comma) {
            self.pos += 1;
            terms.push(self.term()?);
        }
        self.expect(Tok::RParen, "`)`")?;
        if terms.len() > MAX_ARITY {
            return Err(Error::ArityTooLarge { predicate: name, arity: terms.len() });
        }
        let pred = self.preds.intern(&name, terms.len());
        Ok(Atom { pred, terms })
    }

    fn term(&mut self) -> Result<Term, Error> {
        match self.next()? {
            Tok::Ident(s) => Ok(Term::Const(Constant::Sym(s))),
            Tok::Int(n) => Ok(Term::Const(Constant::Int(n))),
            Tok::Var(v) => Ok(Term::Var(v)),
            Tok::Anon => Ok(Term::Anon),
            other => self.error(format!("expected term, found {other:?}")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_facts_rules_queries() {
        let p = parse("e(1, a). p(X) :- e(X, _), not q(X), X < 3. ?- p(Y).").unwrap();
        assert_eq!(p.rules.len(), 2);
        assert_eq!(p.queries.len(), 1);
        assert_eq!(p.rules[1].body.len(), 3);
        assert!(matches!(p.rules[1].body[2], Literal::Cmp(_, CmpOp::Lt, _)));
    }

    #[test]
    fn arity_distinguishes_predicates() {
        let p = parse("r(1). r(1, 2).").unwrap();
        assert_eq!(p.predicates.len(), 2);
    }

    #[test]
    fn comparison_with_symbol_operand() {
        let p = parse("s(X) :- n(X), X < a.").unwrap();
        assert_eq!(p.rules[0].body.len(), 2);
    }

    #[test]
    fn empty_program() {
        let p = parse("  % nothing\n").unwrap();
        assert!(p.rules.is_empty() && p.queries.is_empty());
    }

    #[test]
    fn malformed_is_an_error() {
        assert!(parse("p(1)").is_err());
        assert!(parse("p(1,).").is_err());
        assert!(matches!(parse("p(1,2,3,4,5,6,7)."), Err(Error::ArityTooLarge { .. })));
    }
}
