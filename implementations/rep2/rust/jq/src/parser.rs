//! Lexer and recursive-descent parser for filters.

use std::rc::Rc;

use crate::ast::{BinOp, Builtin, Expr, ObjKey};
use crate::error::ParseError;
use crate::json::parse_string;
use crate::value::Value;

#[derive(Debug, Clone, PartialEq)]
enum Tok {
    Num(f64),
    Str(Rc<str>),
    Ident(String),
    Var(String),
    /// `.name`
    Field(String),
    Dot,
    LBrack,
    RBrack,
    LParen,
    RParen,
    LBrace,
    RBrace,
    Comma,
    Pipe,
    Colon,
    Semi,
    Question,
    Plus,
    Minus,
    Star,
    Slash,
    Percent,
    EqEq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
    Eof,
}

fn is_ident_start(c: u8) -> bool {
    c.is_ascii_alphabetic() || c == b'_'
}

fn is_ident_char(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_'
}

fn lex(src: &str) -> Result<Vec<(Tok, usize)>, ParseError> {
    let b = src.as_bytes();
    let mut toks = Vec::new();
    let mut i = 0;
    let err = |offset: usize, m: &str| ParseError { message: m.to_string(), offset };
    let ident_end = |mut j: usize| {
        while j < b.len() && is_ident_char(b[j]) {
            j += 1;
        }
        j
    };
    while i < b.len() {
        let c = b[i];
        let start = i;
        let tok = match c {
            b' ' | b'\t' | b'\n' | b'\r' => {
                i += 1;
                continue;
            }
            b'.' => {
                if i + 1 < b.len() && is_ident_start(b[i + 1]) {
                    let e = ident_end(i + 1);
                    let t = Tok::Field(src[i + 1..e].to_string());
                    i = e;
                    t
                } else {
                    i += 1;
                    Tok::Dot
                }
            }
            b'0'..=b'9' => {
                let mut e = i;
                while e < b.len() && b[e].is_ascii_digit() {
                    e += 1;
                }
                if e + 1 < b.len() && b[e] == b'.' && b[e + 1].is_ascii_digit() {
                    e += 1;
                    while e < b.len() && b[e].is_ascii_digit() {
                        e += 1;
                    }
                }
                let n = src[i..e].parse::<f64>().map_err(|_| err(i, "invalid number"))?;
                i = e;
                Tok::Num(n)
            }
            b'"' => {
                let (s, e) = parse_string(src, i).map_err(|e| err(e.offset, &e.message))?;
                i = e;
                Tok::Str(s)
            }
            b'$' => {
                if i + 1 < b.len() && is_ident_start(b[i + 1]) {
                    let e = ident_end(i + 1);
                    let t = Tok::Var(src[i + 1..e].to_string());
                    i = e;
                    t
                } else {
                    return Err(err(i, "expected variable name after '$'"));
                }
            }
            c if is_ident_start(c) => {
                let e = ident_end(i);
                let t = Tok::Ident(src[i..e].to_string());
                i = e;
                t
            }
            _ => {
                let two = |second: u8| i + 1 < b.len() && b[i + 1] == second;
                let (t, n) = match c {
                    b'[' => (Tok::LBrack, 1),
                    b']' => (Tok::RBrack, 1),
                    b'(' => (Tok::LParen, 1),
                    b')' => (Tok::RParen, 1),
                    b'{' => (Tok::LBrace, 1),
                    b'}' => (Tok::RBrace, 1),
                    b',' => (Tok::Comma, 1),
                    b'|' => (Tok::Pipe, 1),
                    b':' => (Tok::Colon, 1),
                    b';' => (Tok::Semi, 1),
                    b'?' => (Tok::Question, 1),
                    b'+' => (Tok::Plus, 1),
                    b'-' => (Tok::Minus, 1),
                    b'*' => (Tok::Star, 1),
                    b'/' => (Tok::Slash, 1),
                    b'%' => (Tok::Percent, 1),
                    b'=' if two(b'=') => (Tok::EqEq, 2),
                    b'!' if two(b'=') => (Tok::Ne, 2),
                    b'<' if two(b'=') => (Tok::Le, 2),
                    b'<' => (Tok::Lt, 1),
                    b'>' if two(b'=') => (Tok::Ge, 2),
                    b'>' => (Tok::Gt, 1),
                    _ => return Err(err(i, "unexpected character")),
                };
                i += n;
                t
            }
        };
        toks.push((tok, start));
    }
    toks.push((Tok::Eof, src.len()));
    Ok(toks)
}

struct Parser {
    toks: Vec<(Tok, usize)>,
    pos: usize,
}

type PResult<T> = Result<T, ParseError>;

fn bx(e: Expr) -> Box<Expr> {
    Box::new(e)
}

impl Parser {
    fn peek(&self) -> &Tok {
        &self.toks[self.pos].0
    }

    fn bump(&mut self) -> Tok {
        let t = self.toks[self.pos].0.clone();
        if self.pos + 1 < self.toks.len() {
            self.pos += 1;
        }
        t
    }

    fn err<T>(&self, message: impl Into<String>) -> PResult<T> {
        Err(ParseError { message: message.into(), offset: self.toks[self.pos].1 })
    }

    fn expect(&mut self, t: Tok, what: &str) -> PResult<()> {
        if *self.peek() == t {
            self.bump();
            Ok(())
        } else {
            self.err(format!("expected {}", what))
        }
    }

    fn at_keyword(&self, kw: &str) -> bool {
        matches!(self.peek(), Tok::Ident(s) if s == kw)
    }

    fn expect_keyword(&mut self, kw: &str) -> PResult<()> {
        if self.at_keyword(kw) {
            self.bump();
            Ok(())
        } else {
            self.err(format!("expected '{}'", kw))
        }
    }

    fn expect_var(&mut self) -> PResult<Rc<str>> {
        match self.bump() {
            Tok::Var(n) => Ok(Rc::from(n)),
            _ => {
                self.pos = self.pos.saturating_sub(1);
                self.err("expected variable")
            }
        }
    }

    // pipe := comma [ "as" $x "|" pipe | "|" pipe ]
    fn pipe(&mut self) -> PResult<Expr> {
        let lhs = self.comma()?;
        if self.at_keyword("as") {
            self.bump();
            let name = self.expect_var()?;
            self.expect(Tok::Pipe, "'|' after binding")?;
            let body = self.pipe()?;
            return Ok(Expr::As { source: bx(lhs), name, body: bx(body) });
        }
        if *self.peek() == Tok::Pipe {
            self.bump();
            let rhs = self.pipe()?;
            return Ok(Expr::Pipe(bx(lhs), bx(rhs)));
        }
        Ok(lhs)
    }

    fn comma(&mut self) -> PResult<Expr> {
        let mut lhs = self.or()?;
        while *self.peek() == Tok::Comma {
            self.bump();
            let rhs = self.or()?;
            lhs = Expr::Comma(bx(lhs), bx(rhs));
        }
        Ok(lhs)
    }

    fn or(&mut self) -> PResult<Expr> {
        let mut lhs = self.and()?;
        while self.at_keyword("or") {
            self.bump();
            let rhs = self.and()?;
            lhs = Expr::Or(bx(lhs), bx(rhs));
        }
        Ok(lhs)
    }

    fn and(&mut self) -> PResult<Expr> {
        let mut lhs = self.cmp()?;
        while self.at_keyword("and") {
            self.bump();
            let rhs = self.cmp()?;
            lhs = Expr::And(bx(lhs), bx(rhs));
        }
        Ok(lhs)
    }

    fn cmp(&mut self) -> PResult<Expr> {
        let lhs = self.add()?;
        let op = match self.peek() {
            Tok::EqEq => BinOp::Eq,
            Tok::Ne => BinOp::Ne,
            Tok::Lt => BinOp::Lt,
            Tok::Le => BinOp::Le,
            Tok::Gt => BinOp::Gt,
            Tok::Ge => BinOp::Ge,
            _ => return Ok(lhs),
        };
        self.bump();
        let rhs = self.add()?;
        Ok(Expr::Binary(op, bx(lhs), bx(rhs)))
    }

    fn add(&mut self) -> PResult<Expr> {
        let mut lhs = self.mul()?;
        loop {
            let op = match self.peek() {
                Tok::Plus => BinOp::Add,
                Tok::Minus => BinOp::Sub,
                _ => return Ok(lhs),
            };
            self.bump();
            let rhs = self.mul()?;
            lhs = Expr::Binary(op, bx(lhs), bx(rhs));
        }
    }

    fn mul(&mut self) -> PResult<Expr> {
        let mut lhs = self.unary()?;
        loop {
            let op = match self.peek() {
                Tok::Star => BinOp::Mul,
                Tok::Slash => BinOp::Div,
                Tok::Percent => BinOp::Mod,
                _ => return Ok(lhs),
            };
            self.bump();
            let rhs = self.unary()?;
            lhs = Expr::Binary(op, bx(lhs), bx(rhs));
        }
    }

    fn unary(&mut self) -> PResult<Expr> {
        if *self.peek() == Tok::Minus {
            self.bump();
            let e = self.unary()?;
            return Ok(Expr::Neg(bx(e)));
        }
        self.postfix()
    }

    fn postfix(&mut self) -> PResult<Expr> {
        let start_tok = self.peek().clone();
        let mut e = self.primary()?;
        // Whether `e` ends in a field/index/iterate/slice operation that a
        // following `?` may make tolerant (as opposed to a parenthesised
        // term or an already-tolerant operation, which get `try`).
        let mut op_last = matches!(&e, Expr::Index { .. }) && matches!(start_tok, Tok::Field(_) | Tok::Dot);
        loop {
            match self.peek().clone() {
                Tok::Field(name) => {
                    self.bump();
                    e = Expr::Index {
                        target: bx(e),
                        index: bx(Expr::Literal(Value::string(&name))),
                        optional: false,
                    };
                    op_last = true;
                }
                Tok::Dot => {
                    // `.["x"]`-style or `."x"` continuation.
                    match self.toks.get(self.pos + 1).map(|t| &t.0) {
                        Some(Tok::Str(s)) => {
                            let s = s.clone();
                            self.bump();
                            self.bump();
                            e = Expr::Index {
                                target: bx(e),
                                index: bx(Expr::Literal(Value::String(s))),
                                optional: false,
                            };
                            op_last = true;
                        }
                        Some(Tok::LBrack) => {
                            self.bump();
                        }
                        _ => return Ok(e),
                    }
                }
                Tok::LBrack => {
                    self.bump();
                    e = self.bracket_suffix(e)?;
                    op_last = true;
                }
                Tok::Question => {
                    self.bump();
                    let tolerant = std::mem::replace(&mut op_last, false);
                    e = match e {
                        Expr::Index { target, index, optional: false } if tolerant => {
                            Expr::Index { target, index, optional: true }
                        }
                        Expr::Iterate { target, optional: false } if tolerant => Expr::Iterate { target, optional: true },
                        Expr::Slice { target, from, to, optional: false } if tolerant => {
                            Expr::Slice { target, from, to, optional: true }
                        }
                        other => Expr::Try(bx(other)),
                    };
                }
                _ => return Ok(e),
            }
        }
    }

    /// Parses the remainder of `[...]` after the opening bracket.
    fn bracket_suffix(&mut self, target: Expr) -> PResult<Expr> {
        let target = bx(target);
        if *self.peek() == Tok::RBrack {
            self.bump();
            return Ok(Expr::Iterate { target, optional: false });
        }
        let from = if *self.peek() == Tok::Colon { None } else { Some(bx(self.pipe()?)) };
        if *self.peek() == Tok::Colon {
            self.bump();
            let to = if *self.peek() == Tok::RBrack { None } else { Some(bx(self.pipe()?)) };
            self.expect(Tok::RBrack, "']'")?;
            return Ok(Expr::Slice { target, from, to, optional: false });
        }
        self.expect(Tok::RBrack, "']'")?;
        Ok(Expr::Index { target, index: from.unwrap(), optional: false })
    }

    fn primary(&mut self) -> PResult<Expr> {
        match self.peek().clone() {
            Tok::Num(n) => {
                self.bump();
                Ok(Expr::Literal(Value::Number(n)))
            }
            Tok::Str(s) => {
                self.bump();
                Ok(Expr::Literal(Value::String(s)))
            }
            Tok::Var(n) => {
                self.bump();
                Ok(Expr::Var(Rc::from(n)))
            }
            Tok::Field(name) => {
                self.bump();
                Ok(Expr::Index {
                    target: bx(Expr::Identity),
                    index: bx(Expr::Literal(Value::string(&name))),
                    optional: false,
                })
            }
            Tok::Dot => {
                self.bump();
                if let Tok::Str(s) = self.peek().clone() {
                    self.bump();
                    return Ok(Expr::Index {
                        target: bx(Expr::Identity),
                        index: bx(Expr::Literal(Value::String(s))),
                        optional: false,
                    });
                }
                Ok(Expr::Identity)
            }
            Tok::LParen => {
                self.bump();
                let e = self.pipe()?;
                self.expect(Tok::RParen, "')'")?;
                Ok(e)
            }
            Tok::LBrack => {
                self.bump();
                if *self.peek() == Tok::RBrack {
                    self.bump();
                    return Ok(Expr::Array(None));
                }
                let e = self.pipe()?;
                self.expect(Tok::RBrack, "']'")?;
                Ok(Expr::Array(Some(bx(e))))
            }
            Tok::LBrace => {
                self.bump();
                self.object()
            }
            Tok::Ident(name) => {
                self.bump();
                match name.as_str() {
                    "true" => Ok(Expr::Literal(Value::Bool(true))),
                    "false" => Ok(Expr::Literal(Value::Bool(false))),
                    "null" => Ok(Expr::Literal(Value::Null)),
                    "if" => self.if_expr(),
                    "reduce" => self.reduce(),
                    "then" | "elif" | "else" | "end" | "as" | "and" | "or" => {
                        self.pos -= 1;
                        self.err(format!("unexpected keyword '{}'", name))
                    }
                    _ => self.call(&name),
                }
            }
            _ => self.err("unexpected token"),
        }
    }

    fn call(&mut self, name: &str) -> PResult<Expr> {
        let mut args = Vec::new();
        if *self.peek() == Tok::LParen {
            self.bump();
            loop {
                args.push(self.pipe()?);
                if *self.peek() == Tok::Semi {
                    self.bump();
                } else {
                    break;
                }
            }
            self.expect(Tok::RParen, "')'")?;
        }
        match Builtin::lookup(name, args.len()) {
            Some(b) => Ok(Expr::Call(b, args)),
            None => {
                self.pos = self.pos.saturating_sub(1);
                self.err(format!("unknown function {}/{}", name, args.len()))
            }
        }
    }

    fn if_expr(&mut self) -> PResult<Expr> {
        let cond = self.pipe()?;
        self.expect_keyword("then")?;
        let then = self.pipe()?;
        let otherwise = if self.at_keyword("elif") {
            self.bump();
            self.if_expr()?
        } else {
            let e = if self.at_keyword("else") {
                self.bump();
                self.pipe()?
            } else {
                Expr::Identity
            };
            self.expect_keyword("end")?;
            e
        };
        Ok(Expr::If { cond: bx(cond), then: bx(then), otherwise: bx(otherwise) })
    }

    fn reduce(&mut self) -> PResult<Expr> {
        let source = self.postfix()?;
        self.expect_keyword("as")?;
        let name = self.expect_var()?;
        self.expect(Tok::LParen, "'('")?;
        let init = self.pipe()?;
        self.expect(Tok::Semi, "';'")?;
        let update = self.pipe()?;
        self.expect(Tok::RParen, "')'")?;
        Ok(Expr::Reduce { source: bx(source), name, init: bx(init), update: bx(update) })
    }

    fn object(&mut self) -> PResult<Expr> {
        let mut entries = Vec::new();
        if *self.peek() == Tok::RBrace {
            self.bump();
            return Ok(Expr::Object(entries));
        }
        loop {
            let entry = match self.bump() {
                Tok::Ident(name) => {
                    let key: Rc<str> = Rc::from(name.as_str());
                    if *self.peek() == Tok::Colon {
                        self.bump();
                        (ObjKey::Literal(key), self.obj_value()?)
                    } else {
                        let v = field_of_input(Value::String(key.clone()));
                        (ObjKey::Literal(key), v)
                    }
                }
                Tok::Str(key) => {
                    if *self.peek() == Tok::Colon {
                        self.bump();
                        (ObjKey::Literal(key), self.obj_value()?)
                    } else {
                        let v = field_of_input(Value::String(key.clone()));
                        (ObjKey::Literal(key), v)
                    }
                }
                Tok::Var(name) => {
                    (ObjKey::Literal(Rc::from(name.as_str())), Expr::Var(Rc::from(name.as_str())))
                }
                Tok::LParen => {
                    let k = self.pipe()?;
                    self.expect(Tok::RParen, "')'")?;
                    self.expect(Tok::Colon, "':'")?;
                    (ObjKey::Computed(k), self.obj_value()?)
                }
                _ => {
                    self.pos = self.pos.saturating_sub(1);
                    return self.err("invalid object entry");
                }
            };
            entries.push(entry);
            match self.bump() {
                Tok::Comma => {}
                Tok::RBrace => return Ok(Expr::Object(entries)),
                _ => {
                    self.pos = self.pos.saturating_sub(1);
                    return self.err("expected ',' or '}'");
                }
            }
        }
    }

    // objval := objterm { "|" objterm }
    fn obj_value(&mut self) -> PResult<Expr> {
        let lhs = self.obj_term()?;
        if *self.peek() == Tok::Pipe {
            self.bump();
            let rhs = self.obj_value()?;
            return Ok(Expr::Pipe(bx(lhs), bx(rhs)));
        }
        Ok(lhs)
    }

    fn obj_term(&mut self) -> PResult<Expr> {
        if *self.peek() == Tok::Minus {
            self.bump();
            let e = self.obj_term()?;
            return Ok(Expr::Neg(bx(e)));
        }
        self.postfix()
    }
}

fn field_of_input(key: Value) -> Expr {
    Expr::Index { target: bx(Expr::Identity), index: bx(Expr::Literal(key)), optional: false }
}

/// Parses filter source text into an expression tree.
pub(crate) fn parse(src: &str) -> Result<Expr, ParseError> {
    let toks = lex(src)?;
    let mut p = Parser { toks, pos: 0 };
    let e = p.pipe()?;
    if *p.peek() != Tok::Eof {
        return p.err("unexpected token after end of filter");
    }
    Ok(e)
}
