//! Recursive-descent parser for the grammar in the specification.

use crate::ast::{BinOp, Decl, Expr};
use crate::error::ParseError;
use crate::lexer::{tokenize, Token};
use crate::symbol::{Interner, Sym};

/// Parses a whole program (a sequence of `;;`-terminated declarations).
///
/// Recursion depth is proportional to expression nesting; callers that parse
/// deeply nested input should run on a thread with a large stack (the
/// [`Session`](crate::Session) source-level methods do this).
pub fn parse_program(src: &str, interner: &mut Interner) -> Result<Vec<Decl>, ParseError> {
    let toks = tokenize(src, interner)?;
    let mut p = Parser { toks, pos: 0, end: src.len() };
    let mut decls = Vec::new();
    while p.peek().is_some() {
        decls.push(p.decl()?);
    }
    Ok(decls)
}

struct Parser {
    toks: Vec<(Token, usize)>,
    pos: usize,
    end: usize,
}

type PResult<T> = Result<T, ParseError>;

impl Parser {
    fn peek(&self) -> Option<Token> {
        self.toks.get(self.pos).map(|t| t.0)
    }

    fn here(&self) -> usize {
        self.toks.get(self.pos).map_or(self.end, |t| t.1)
    }

    fn bump(&mut self) {
        self.pos += 1;
    }

    fn eat(&mut self, t: Token) -> bool {
        if self.peek() == Some(t) {
            self.bump();
            true
        } else {
            false
        }
    }

    fn expect(&mut self, t: Token) -> PResult<()> {
        if self.eat(t) {
            Ok(())
        } else {
            Err(ParseError::new(self.here(), format!("expected {:?}", t)))
        }
    }

    fn ident(&mut self) -> PResult<Sym> {
        match self.peek() {
            Some(Token::Ident(s)) => {
                self.bump();
                Ok(s)
            }
            _ => Err(ParseError::new(self.here(), "expected identifier")),
        }
    }

    fn idents(&mut self) -> Vec<Sym> {
        let mut v = Vec::new();
        while let Some(Token::Ident(s)) = self.peek() {
            self.bump();
            v.push(s);
        }
        v
    }

    /// Parses the part of a binding after `let`: `[rec] name params = expr`.
    fn binding(&mut self) -> PResult<(bool, Sym, Vec<Sym>, Expr)> {
        let rec = self.eat(Token::Rec);
        let name = self.ident()?;
        let params = self.idents();
        if rec && params.is_empty() {
            return Err(ParseError::new(self.here(), "`let rec` needs a parameter"));
        }
        self.expect(Token::Eq)?;
        let rhs = self.expr()?;
        Ok((rec, name, params, rhs))
    }

    fn decl(&mut self) -> PResult<Decl> {
        if self.eat(Token::Let) {
            let (rec, name, params, rhs) = self.binding()?;
            self.expect(Token::DSemi)?;
            Ok(if rec {
                Decl::LetRec { name, params, rhs }
            } else {
                Decl::Let { name, rhs: wrap_fun(params, rhs) }
            })
        } else {
            let e = self.expr()?;
            self.expect(Token::DSemi)?;
            Ok(Decl::Expr(e))
        }
    }

    fn expr(&mut self) -> PResult<Expr> {
        match self.peek() {
            Some(Token::Let) => {
                self.bump();
                let (rec, name, params, rhs) = self.binding()?;
                self.expect(Token::In)?;
                let body = Box::new(self.expr()?);
                Ok(if rec {
                    Expr::LetRec { name, params, rhs: Box::new(rhs), body }
                } else {
                    Expr::Let { name, rhs: Box::new(wrap_fun(params, rhs)), body }
                })
            }
            Some(Token::Fun) => {
                self.bump();
                let params = self.idents();
                if params.is_empty() {
                    return Err(ParseError::new(self.here(), "`fun` needs a parameter"));
                }
                self.expect(Token::Arrow)?;
                let body = self.expr()?;
                Ok(Expr::Fun(params, Box::new(body)))
            }
            Some(Token::If) => {
                self.bump();
                let c = self.expr()?;
                self.expect(Token::Then)?;
                let a = self.expr()?;
                self.expect(Token::Else)?;
                let b = self.expr()?;
                Ok(Expr::If(Box::new(c), Box::new(a), Box::new(b)))
            }
            _ => self.or(),
        }
    }

    fn or(&mut self) -> PResult<Expr> {
        let mut l = self.and()?;
        while self.eat(Token::OrOr) {
            let r = self.and()?;
            l = Expr::Binary(BinOp::Or, Box::new(l), Box::new(r));
        }
        Ok(l)
    }

    fn and(&mut self) -> PResult<Expr> {
        let mut l = self.cmp()?;
        while self.eat(Token::AndAnd) {
            let r = self.cmp()?;
            l = Expr::Binary(BinOp::And, Box::new(l), Box::new(r));
        }
        Ok(l)
    }

    fn cmp(&mut self) -> PResult<Expr> {
        let l = self.cons()?;
        let op = match self.peek() {
            Some(Token::Eq) => BinOp::Eq,
            Some(Token::Lt) => BinOp::Lt,
            Some(Token::Gt) => BinOp::Gt,
            Some(Token::Le) => BinOp::Le,
            Some(Token::Ge) => BinOp::Ge,
            _ => return Ok(l),
        };
        self.bump();
        let r = self.cons()?;
        Ok(Expr::Binary(op, Box::new(l), Box::new(r)))
    }

    fn cons(&mut self) -> PResult<Expr> {
        let l = self.add()?;
        if self.eat(Token::ColonColon) {
            let r = self.cons()?;
            Ok(Expr::Cons(Box::new(l), Box::new(r)))
        } else {
            Ok(l)
        }
    }

    fn add(&mut self) -> PResult<Expr> {
        let mut l = self.mul()?;
        loop {
            let op = match self.peek() {
                Some(Token::Plus) => BinOp::Add,
                Some(Token::Minus) => BinOp::Sub,
                _ => return Ok(l),
            };
            self.bump();
            let r = self.mul()?;
            l = Expr::Binary(op, Box::new(l), Box::new(r));
        }
    }

    fn mul(&mut self) -> PResult<Expr> {
        let mut l = self.app()?;
        loop {
            let op = match self.peek() {
                Some(Token::Star) => BinOp::Mul,
                Some(Token::Slash) => BinOp::Div,
                _ => return Ok(l),
            };
            self.bump();
            let r = self.app()?;
            l = Expr::Binary(op, Box::new(l), Box::new(r));
        }
    }

    fn starts_atom(&self) -> bool {
        matches!(
            self.peek(),
            Some(
                Token::Int
                    | Token::True
                    | Token::False
                    | Token::Ident(_)
                    | Token::LParen
                    | Token::LBrack
            )
        )
    }

    fn app(&mut self) -> PResult<Expr> {
        let mut f = self.atom()?;
        while self.starts_atom() {
            let a = self.atom()?;
            f = Expr::App(Box::new(f), Box::new(a));
        }
        Ok(f)
    }

    fn atom(&mut self) -> PResult<Expr> {
        let pos = self.here();
        match self.peek() {
            Some(Token::Int) => {
                self.bump();
                Ok(Expr::Int)
            }
            Some(Token::True) => {
                self.bump();
                Ok(Expr::Bool(true))
            }
            Some(Token::False) => {
                self.bump();
                Ok(Expr::Bool(false))
            }
            Some(Token::Ident(s)) => {
                self.bump();
                Ok(Expr::Var(s))
            }
            Some(Token::LParen) => {
                self.bump();
                if self.eat(Token::RParen) {
                    return Ok(Expr::Unit);
                }
                let first = self.expr()?;
                if self.eat(Token::RParen) {
                    return Ok(first);
                }
                let mut items = vec![first];
                while self.eat(Token::Comma) {
                    items.push(self.expr()?);
                }
                self.expect(Token::RParen)?;
                Ok(Expr::Tuple(items))
            }
            Some(Token::LBrack) => {
                self.bump();
                let mut items = Vec::new();
                if self.eat(Token::RBrack) {
                    return Ok(Expr::List(items));
                }
                items.push(self.expr()?);
                while self.eat(Token::Semi) {
                    items.push(self.expr()?);
                }
                self.expect(Token::RBrack)?;
                Ok(Expr::List(items))
            }
            _ => Err(ParseError::new(pos, "expected an expression")),
        }
    }
}

fn wrap_fun(params: Vec<Sym>, body: Expr) -> Expr {
    if params.is_empty() {
        body
    } else {
        Expr::Fun(params, Box::new(body))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(s: &str) -> Vec<Decl> {
        parse_program(s, &mut Interner::new()).unwrap()
    }

    fn expr(s: &str) -> Expr {
        match parse(&format!("{};;", s)).remove(0) {
            Decl::Expr(e) => e,
            d => panic!("not an expression: {:?}", d),
        }
    }

    #[test]
    fn empty_program() {
        assert!(parse("  \n\t ").is_empty());
    }

    #[test]
    fn precedence_application_over_arithmetic() {
        // f x + g y * 2  ==  (f x) + ((g y) * 2)
        match expr("f x + g y * 2") {
            Expr::Binary(BinOp::Add, l, r) => {
                assert!(matches!(*l, Expr::App(..)));
                assert!(matches!(*r, Expr::Binary(BinOp::Mul, ..)));
            }
            e => panic!("{:?}", e),
        }
    }

    #[test]
    fn cons_is_right_associative() {
        match expr("1 :: 2 :: []") {
            Expr::Cons(_, r) => assert!(matches!(*r, Expr::Cons(..))),
            e => panic!("{:?}", e),
        }
    }

    #[test]
    fn fun_body_stops_at_comma() {
        match expr("(fun x -> x, 1)") {
            Expr::Tuple(v) => {
                assert_eq!(v.len(), 2);
                assert!(matches!(v[0], Expr::Fun(..)));
            }
            e => panic!("{:?}", e),
        }
    }

    #[test]
    fn let_sugar_and_rec() {
        let mut i = Interner::new();
        let d = parse_program("let f x y = x;; let rec g x = g x;;", &mut i).unwrap();
        match &d[0] {
            Decl::Let { rhs: Expr::Fun(ps, _), .. } => assert_eq!(ps.len(), 2),
            d => panic!("{:?}", d),
        }
        assert!(matches!(d[1], Decl::LetRec { .. }));
    }

    #[test]
    fn rec_needs_parameter() {
        assert!(parse_program("let rec f = 1;;", &mut Interner::new()).is_err());
    }

    #[test]
    fn three_tuple_is_flat() {
        assert!(matches!(expr("(1, 2, 3)"), Expr::Tuple(v) if v.len() == 3));
    }
}
