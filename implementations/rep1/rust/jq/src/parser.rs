//! Recursive-descent parser for the filter language.

use crate::ast::{BinOp, Builtin, Expr, Key};
use crate::error::{Error, Result};
use crate::lexer::{tokenize, Tok};
use crate::value::Value;
use std::rc::Rc;

/// Maximum syntactic nesting accepted (guards the call stack).
const MAX_DEPTH: usize = 500;

/// Parses filter source text into a syntax tree.
pub(crate) fn parse(src: &str) -> Result<Expr> {
    let mut p = Parser { toks: tokenize(src)?, pos: 0, last_postfix: (usize::MAX, usize::MAX), depth: 0 };
    let e = p.pipe()?;
    if p.pos != p.toks.len() {
        return Err(p.unexpected());
    }
    Ok(e)
}

struct Parser {
    toks: Vec<Tok>,
    pos: usize,
    /// Token span `(start, end)` of the most recently completed postfix term. Used to
    /// recognise `postfix as $x | ...` without backtracking.
    last_postfix: (usize, usize),
    depth: usize,
}

/// Words that can never be field names after `.` (so `. as $x` and `if . then` parse).
fn is_keyword(s: &str) -> bool {
    matches!(s, "if" | "then" | "elif" | "else" | "end" | "as" | "reduce" | "and" | "or")
}

fn lit_str(s: &str) -> Expr {
    Expr::Literal(Value::string(s))
}

impl Parser {
    fn peek(&self) -> Option<&Tok> {
        self.toks.get(self.pos)
    }

    fn peek_at(&self, off: usize) -> Option<&Tok> {
        self.toks.get(self.pos + off)
    }

    fn is_sym(&self, s: &str) -> bool {
        matches!(self.peek(), Some(Tok::Sym(x)) if *x == s)
    }

    fn is_kw(&self, s: &str) -> bool {
        matches!(self.peek(), Some(Tok::Ident(x)) if x == s)
    }

    fn eat_sym(&mut self, s: &str) -> bool {
        if self.is_sym(s) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn eat_kw(&mut self, s: &str) -> bool {
        if self.is_kw(s) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn unexpected(&self) -> Error {
        match self.peek() {
            Some(t) => Error::syntax(format!("unexpected token {:?} at token {}", t, self.pos)),
            None => Error::syntax("unexpected end of filter"),
        }
    }

    fn expect_sym(&mut self, s: &str) -> Result<()> {
        if self.eat_sym(s) {
            Ok(())
        } else {
            Err(Error::syntax(format!("expected '{}', found {}", s, self.describe())))
        }
    }

    fn expect_kw(&mut self, s: &str) -> Result<()> {
        if self.eat_kw(s) {
            Ok(())
        } else {
            Err(Error::syntax(format!("expected '{}', found {}", s, self.describe())))
        }
    }

    fn describe(&self) -> String {
        match self.peek() {
            Some(t) => format!("{:?}", t),
            None => "end of filter".to_string(),
        }
    }

    fn expect_var(&mut self) -> Result<Rc<str>> {
        match self.peek() {
            Some(Tok::Var(n)) => {
                let n: Rc<str> = n.as_str().into();
                self.pos += 1;
                Ok(n)
            }
            _ => Err(Error::syntax(format!("expected variable, found {}", self.describe()))),
        }
    }

    fn enter(&mut self) -> Result<()> {
        self.depth += 1;
        if self.depth > MAX_DEPTH {
            Err(Error::syntax("filter nested too deeply"))
        } else {
            Ok(())
        }
    }

    // pipe := postfix "as" "$" IDENT "|" pipe | comma [ "|" pipe ]
    fn pipe(&mut self) -> Result<Expr> {
        self.enter()?;
        let start = self.pos;
        let lhs = self.comma()?;
        let r = if self.is_kw("as") && self.last_postfix == (start, self.pos) {
            self.pos += 1;
            let name = self.expect_var()?;
            self.expect_sym("|")?;
            let body = self.pipe()?;
            Expr::As { source: Box::new(lhs), name, body: Box::new(body) }
        } else if self.eat_sym("|") {
            let rhs = self.pipe()?;
            Expr::Pipe(Box::new(lhs), Box::new(rhs))
        } else {
            lhs
        };
        self.depth -= 1;
        Ok(r)
    }

    fn comma(&mut self) -> Result<Expr> {
        let mut lhs = self.or()?;
        while self.eat_sym(",") {
            let rhs = self.or()?;
            lhs = Expr::Comma(Box::new(lhs), Box::new(rhs));
        }
        Ok(lhs)
    }

    fn or(&mut self) -> Result<Expr> {
        let mut lhs = self.and()?;
        while self.eat_kw("or") {
            let rhs = self.and()?;
            lhs = Expr::Or(Box::new(lhs), Box::new(rhs));
        }
        Ok(lhs)
    }

    fn and(&mut self) -> Result<Expr> {
        let mut lhs = self.cmp()?;
        while self.eat_kw("and") {
            let rhs = self.cmp()?;
            lhs = Expr::And(Box::new(lhs), Box::new(rhs));
        }
        Ok(lhs)
    }

    fn cmp(&mut self) -> Result<Expr> {
        let lhs = self.add()?;
        let op = match self.peek() {
            Some(Tok::Sym("==")) => BinOp::Eq,
            Some(Tok::Sym("!=")) => BinOp::Ne,
            Some(Tok::Sym("<")) => BinOp::Lt,
            Some(Tok::Sym("<=")) => BinOp::Le,
            Some(Tok::Sym(">")) => BinOp::Gt,
            Some(Tok::Sym(">=")) => BinOp::Ge,
            _ => return Ok(lhs),
        };
        self.pos += 1;
        let rhs = self.add()?;
        Ok(Expr::Binary(op, Box::new(lhs), Box::new(rhs)))
    }

    fn add(&mut self) -> Result<Expr> {
        let mut lhs = self.mul()?;
        loop {
            let op = match self.peek() {
                Some(Tok::Sym("+")) => BinOp::Add,
                Some(Tok::Sym("-")) => BinOp::Sub,
                _ => return Ok(lhs),
            };
            self.pos += 1;
            let rhs = self.mul()?;
            lhs = Expr::Binary(op, Box::new(lhs), Box::new(rhs));
        }
    }

    fn mul(&mut self) -> Result<Expr> {
        let mut lhs = self.unary()?;
        loop {
            let op = match self.peek() {
                Some(Tok::Sym("*")) => BinOp::Mul,
                Some(Tok::Sym("/")) => BinOp::Div,
                Some(Tok::Sym("%")) => BinOp::Mod,
                _ => return Ok(lhs),
            };
            self.pos += 1;
            let rhs = self.unary()?;
            lhs = Expr::Binary(op, Box::new(lhs), Box::new(rhs));
        }
    }

    fn unary(&mut self) -> Result<Expr> {
        if self.eat_sym("-") {
            self.enter()?;
            let e = self.unary()?;
            self.depth -= 1;
            Ok(Expr::Neg(Box::new(e)))
        } else {
            self.postfix()
        }
    }

    fn postfix(&mut self) -> Result<Expr> {
        let start = self.pos;
        let mut e = self.primary()?;
        // Whether the last suffix was a path operation that has not yet absorbed a `?`.
        let mut can_opt = false;
        loop {
            if self.is_sym(".") {
                match self.peek_at(1) {
                    Some(Tok::Ident(name)) if !is_keyword(name) => {
                        let key = lit_str(name);
                        self.pos += 2;
                        e = Expr::Index { target: Box::new(e), key: Box::new(key), opt: false };
                    }
                    Some(Tok::Str(s)) => {
                        let key = lit_str(s);
                        self.pos += 2;
                        e = Expr::Index { target: Box::new(e), key: Box::new(key), opt: false };
                    }
                    Some(Tok::Sym("[")) => {
                        self.pos += 1;
                        continue;
                    }
                    _ => return Err(self.unexpected()),
                }
                can_opt = true;
            } else if self.is_sym("[") {
                self.pos += 1;
                e = self.bracket_suffix(e)?;
                can_opt = true;
            } else if self.is_sym("?") {
                self.pos += 1;
                if can_opt {
                    e = set_optional(e);
                    can_opt = false;
                } else {
                    e = Expr::Try(Box::new(e));
                }
            } else {
                break;
            }
        }
        self.last_postfix = (start, self.pos);
        Ok(e)
    }

    /// Parses what follows `[` in a suffix position (index, iterate or slice).
    fn bracket_suffix(&mut self, target: Expr) -> Result<Expr> {
        let target = Box::new(target);
        if self.eat_sym("]") {
            return Ok(Expr::Iterate { target, opt: false });
        }
        let from = if self.is_sym(":") { None } else { Some(Box::new(self.pipe()?)) };
        if self.eat_sym(":") {
            let to = if self.is_sym("]") { None } else { Some(Box::new(self.pipe()?)) };
            self.expect_sym("]")?;
            return Ok(Expr::Slice { target, from, to, opt: false });
        }
        self.expect_sym("]")?;
        match from {
            Some(key) => Ok(Expr::Index { target, key, opt: false }),
            None => Err(self.unexpected()),
        }
    }

    fn primary(&mut self) -> Result<Expr> {
        let tok = match self.peek() {
            Some(t) => t.clone(),
            None => return Err(self.unexpected()),
        };
        match tok {
            Tok::Sym(".") => {
                self.pos += 1;
                match self.peek() {
                    Some(Tok::Ident(name)) if !is_keyword(name) => {
                        let key = lit_str(name);
                        self.pos += 1;
                        Ok(Expr::Index { target: Box::new(Expr::Identity), key: Box::new(key), opt: false })
                    }
                    Some(Tok::Str(s)) => {
                        let key = lit_str(s);
                        self.pos += 1;
                        Ok(Expr::Index { target: Box::new(Expr::Identity), key: Box::new(key), opt: false })
                    }
                    _ => Ok(Expr::Identity),
                }
            }
            Tok::Num(n) => {
                self.pos += 1;
                Ok(Expr::Literal(Value::Number(n)))
            }
            Tok::Str(s) => {
                self.pos += 1;
                Ok(Expr::Literal(Value::string(s)))
            }
            Tok::Var(n) => {
                self.pos += 1;
                Ok(Expr::Var(n.into()))
            }
            Tok::Sym("(") => {
                self.pos += 1;
                let e = self.pipe()?;
                self.expect_sym(")")?;
                Ok(e)
            }
            Tok::Sym("[") => {
                self.pos += 1;
                if self.eat_sym("]") {
                    return Ok(Expr::Array(None));
                }
                let e = self.pipe()?;
                self.expect_sym("]")?;
                Ok(Expr::Array(Some(Box::new(e))))
            }
            Tok::Sym("{") => {
                self.pos += 1;
                self.object()
            }
            Tok::Ident(name) => match name.as_str() {
                "true" => {
                    self.pos += 1;
                    Ok(Expr::Literal(Value::Bool(true)))
                }
                "false" => {
                    self.pos += 1;
                    Ok(Expr::Literal(Value::Bool(false)))
                }
                "null" => {
                    self.pos += 1;
                    Ok(Expr::Literal(Value::Null))
                }
                "if" => {
                    self.pos += 1;
                    self.if_expr()
                }
                "reduce" => {
                    self.pos += 1;
                    let source = self.postfix()?;
                    self.expect_kw("as")?;
                    let name = self.expect_var()?;
                    self.expect_sym("(")?;
                    let init = self.pipe()?;
                    self.expect_sym(";")?;
                    let update = self.pipe()?;
                    self.expect_sym(")")?;
                    Ok(Expr::Reduce {
                        source: Box::new(source),
                        name,
                        init: Box::new(init),
                        update: Box::new(update),
                    })
                }
                "then" | "elif" | "else" | "end" | "as" | "and" | "or" => Err(self.unexpected()),
                _ => {
                    self.pos += 1;
                    let mut args = Vec::new();
                    if self.eat_sym("(") {
                        args.push(self.pipe()?);
                        while self.eat_sym(";") {
                            args.push(self.pipe()?);
                        }
                        self.expect_sym(")")?;
                    }
                    match Builtin::lookup(&name, args.len()) {
                        Some(b) => Ok(Expr::Call(b, args)),
                        None => Err(Error::syntax(format!("unknown function {}/{}", name, args.len()))),
                    }
                }
            },
            _ => Err(self.unexpected()),
        }
    }

    // After `if`: cond then a {elif c then b} [else d] end
    fn if_expr(&mut self) -> Result<Expr> {
        let cond = self.pipe()?;
        self.expect_kw("then")?;
        let then = self.pipe()?;
        let otherwise = if self.eat_kw("elif") {
            Some(Box::new(self.if_expr()?))
        } else if self.eat_kw("else") {
            let e = self.pipe()?;
            self.expect_kw("end")?;
            Some(Box::new(e))
        } else {
            self.expect_kw("end")?;
            None
        };
        Ok(Expr::If { cond: Box::new(cond), then: Box::new(then), otherwise })
    }

    // After `{`
    fn object(&mut self) -> Result<Expr> {
        let mut entries = Vec::new();
        if self.eat_sym("}") {
            return Ok(Expr::Object(entries));
        }
        loop {
            let tok = self.peek().cloned().ok_or_else(|| self.unexpected())?;
            let entry = match tok {
                Tok::Ident(name) => {
                    self.pos += 1;
                    if self.eat_sym(":") {
                        (Key::Literal(name.as_str().into()), self.objval()?)
                    } else {
                        let v = Expr::Index {
                            target: Box::new(Expr::Identity),
                            key: Box::new(lit_str(&name)),
                            opt: false,
                        };
                        (Key::Literal(name.as_str().into()), v)
                    }
                }
                Tok::Str(s) => {
                    self.pos += 1;
                    if self.eat_sym(":") {
                        (Key::Literal(s.as_str().into()), self.objval()?)
                    } else {
                        let v = Expr::Index {
                            target: Box::new(Expr::Identity),
                            key: Box::new(lit_str(&s)),
                            opt: false,
                        };
                        (Key::Literal(s.as_str().into()), v)
                    }
                }
                Tok::Var(name) => {
                    self.pos += 1;
                    (Key::Literal(name.as_str().into()), Expr::Var(name.as_str().into()))
                }
                Tok::Sym("(") => {
                    self.pos += 1;
                    let k = self.pipe()?;
                    self.expect_sym(")")?;
                    self.expect_sym(":")?;
                    (Key::Computed(k), self.objval()?)
                }
                _ => return Err(self.unexpected()),
            };
            entries.push(entry);
            if self.eat_sym(",") {
                continue;
            }
            self.expect_sym("}")?;
            return Ok(Expr::Object(entries));
        }
    }

    // objval := objterm { "|" objterm }
    fn objval(&mut self) -> Result<Expr> {
        let mut e = self.objterm()?;
        while self.eat_sym("|") {
            let r = self.objterm()?;
            e = Expr::Pipe(Box::new(e), Box::new(r));
        }
        Ok(e)
    }

    fn objterm(&mut self) -> Result<Expr> {
        if self.eat_sym("-") {
            self.enter()?;
            let e = self.objterm()?;
            self.depth -= 1;
            Ok(Expr::Neg(Box::new(e)))
        } else {
            self.postfix()
        }
    }
}

/// Marks the outermost path operation of `e` as optional (`.a?`, `.[]?`, ...).
fn set_optional(e: Expr) -> Expr {
    match e {
        Expr::Index { target, key, .. } => Expr::Index { target, key, opt: true },
        Expr::Iterate { target, .. } => Expr::Iterate { target, opt: true },
        Expr::Slice { target, from, to, .. } => Expr::Slice { target, from, to, opt: true },
        other => Expr::Try(Box::new(other)),
    }
}
