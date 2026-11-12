//! Parsing of KBL build files into syntax trees.
//!
//! [`parse_file`] lexes the whole file first (so lexical errors take
//! priority), then parses logical lines in order with an explicit block
//! stack. Any failure is reported as the 1-based line number of the logical
//! line it belongs to.

use crate::ast::*;
use crate::lexer::{lex_file, scan_region, tokenize, Line, StrLit, Tok};
use crate::value::Value;
use std::rc::Rc;

/// Words that cannot be used as names.
pub const RESERVED: [&str; 21] = [
    "abort", "after", "cmd", "cost", "default", "depfile", "each", "elsewhen", "false", "in", "include", "let", "otherwise",
    "out", "phony", "rule", "set", "step", "true", "use", "when",
];

/// Whether `s` is a reserved word.
pub fn is_reserved(s: &str) -> bool {
    RESERVED.contains(&s)
}

#[derive(Debug)]
struct Bad;
type P<T> = Result<T, Bad>;

/// Parses a build file. On failure returns the line number for `E_PARSE`.
pub fn parse_file(src: &[u8]) -> Result<Vec<Stmt>, usize> {
    let lines = lex_file(src)?;
    parse_lines(&lines)
}

enum Frame {
    Root,
    When { done: Vec<(Expr, Vec<Stmt>)>, cond: Option<Expr> },
    Otherwise { done: Vec<(Expr, Vec<Stmt>)> },
    Each { index: Option<String>, name: String, subject: Expr },
    Rule { name: String, params: Vec<Param> },
    Step,
}

struct Open {
    frame: Frame,
    line: usize,
    body: Vec<Stmt>,
    fields: Vec<Field>,
}

fn parse_lines(lines: &[Line]) -> Result<Vec<Stmt>, usize> {
    let mut stack = vec![Open { frame: Frame::Root, line: 0, body: Vec::new(), fields: Vec::new() }];
    for line in lines {
        handle_line(&mut stack, line).map_err(|_| line.no)?;
    }
    if stack.len() > 1 {
        return Err(stack.last().map(|o| o.line).unwrap_or(0));
    }
    Ok(stack.pop().map(|o| o.body).unwrap_or_default())
}

fn is_sym(t: &Tok, s: &str) -> bool {
    matches!(t, Tok::Sym(x) if *x == s)
}

fn is_kw(t: &Tok, s: &str) -> bool {
    matches!(t, Tok::Ident(x) if x == s)
}

fn handle_line(stack: &mut Vec<Open>, line: &Line) -> P<()> {
    let toks = &line.toks;
    let first = toks.first().ok_or(Bad)?;
    let last = toks.last().ok_or(Bad)?;
    let in_step = matches!(stack.last().map(|o| &o.frame), Some(Frame::Step));
    if is_sym(first, "}") {
        return handle_terminator(stack, line);
    }
    if is_sym(last, "{") {
        if in_step {
            return Err(Bad);
        }
        let head = &toks[..toks.len() - 1];
        let frame = parse_header(head)?;
        stack.push(Open { frame, line: line.no, body: Vec::new(), fields: Vec::new() });
        return Ok(());
    }
    if in_step {
        let field = parse_field(toks)?;
        stack.last_mut().ok_or(Bad)?.fields.push(field);
    } else {
        let stmt = parse_simple(toks)?;
        stack.last_mut().ok_or(Bad)?.body.push(stmt);
    }
    Ok(())
}

fn handle_terminator(stack: &mut Vec<Open>, line: &Line) -> P<()> {
    let toks = &line.toks;
    if stack.len() <= 1 {
        return Err(Bad);
    }
    if toks.len() == 1 {
        let open = stack.pop().ok_or(Bad)?;
        let stmt = close_block(open);
        stack.last_mut().ok_or(Bad)?.body.push(stmt);
        return Ok(());
    }
    if !is_sym(toks.last().ok_or(Bad)?, "{") {
        return Err(Bad);
    }
    let top = stack.last_mut().ok_or(Bad)?;
    let Frame::When { done, cond } = std::mem::replace(&mut top.frame, Frame::Root) else {
        return Err(Bad);
    };
    let mut done = done;
    let body = std::mem::take(&mut top.body);
    let finished = (cond.ok_or(Bad)?, body);
    if is_kw(&toks[1], "elsewhen") {
        let next = parse_expr_all(&toks[2..toks.len() - 1])?;
        done.push(finished);
        top.frame = Frame::When { done, cond: Some(next) };
    } else if is_kw(&toks[1], "otherwise") && toks.len() == 3 {
        done.push(finished);
        top.frame = Frame::Otherwise { done };
    } else {
        return Err(Bad);
    }
    top.line = line.no;
    Ok(())
}

fn close_block(open: Open) -> Stmt {
    match open.frame {
        Frame::When { mut done, cond } => {
            if let Some(c) = cond {
                done.push((c, open.body));
            }
            Stmt::When { branches: done, otherwise: None }
        }
        Frame::Otherwise { done } => Stmt::When { branches: done, otherwise: Some(open.body) },
        Frame::Each { index, name, subject } => Stmt::Each { index, name, subject, body: open.body },
        Frame::Rule { name, params } => Stmt::Rule { name, params, body: Rc::new(open.body) },
        Frame::Step => Stmt::Step(open.fields),
        Frame::Root => unreachable!("the root frame is never closed"),
    }
}

fn parse_header(head: &[Tok]) -> P<Frame> {
    let kw = match head.first() {
        Some(Tok::Ident(k)) => k.as_str(),
        _ => return Err(Bad),
    };
    match kw {
        "step" if head.len() == 1 => Ok(Frame::Step),
        "when" => Ok(Frame::When { done: Vec::new(), cond: Some(parse_expr_all(&head[1..])?) }),
        "each" => {
            let mut p = Cursor::new(&head[1..]);
            let a = p.ident()?;
            let (index, name) = if p.eat_sym(",") {
                let b = p.ident()?;
                if a == b {
                    return Err(Bad);
                }
                (Some(a), b)
            } else {
                (None, a)
            };
            if !p.eat_kw("in") {
                return Err(Bad);
            }
            let subject = p.expr()?;
            p.finish()?;
            Ok(Frame::Each { index, name, subject })
        }
        "rule" => {
            let mut p = Cursor::new(&head[1..]);
            let name = p.ident()?;
            p.expect_sym("(")?;
            let mut params: Vec<Param> = Vec::new();
            if !p.eat_sym(")") {
                loop {
                    let pname = p.ident()?;
                    let default = if p.eat_sym("=") { Some(p.expr()?) } else { None };
                    if params.iter().any(|q| q.name == pname) {
                        return Err(Bad);
                    }
                    if default.is_none() && params.last().is_some_and(|q| q.default.is_some()) {
                        return Err(Bad);
                    }
                    params.push(Param { name: pname, default });
                    if p.eat_sym(",") {
                        if p.eat_sym(")") {
                            break;
                        }
                    } else {
                        p.expect_sym(")")?;
                        break;
                    }
                }
            }
            p.finish()?;
            Ok(Frame::Rule { name, params })
        }
        _ => Err(Bad),
    }
}

fn parse_field(toks: &[Tok]) -> P<Field> {
    let kw = match toks.first() {
        Some(Tok::Ident(k)) => k.as_str(),
        _ => return Err(Bad),
    };
    let rest = &toks[1..];
    match kw {
        "out" => Ok(Field::Out(parse_expr_all(rest)?)),
        "in" => Ok(Field::In(parse_expr_all(rest)?)),
        "after" => Ok(Field::After(parse_expr_all(rest)?)),
        "cost" => Ok(Field::Cost(parse_expr_all(rest)?)),
        "depfile" => Ok(Field::Depfile(parse_expr_all(rest)?)),
        "cmd" => {
            let mut p = Cursor::new(rest);
            let name = p.any_ident()?;
            p.expect_sym("(")?;
            let args = p.call_args()?;
            p.finish()?;
            Ok(Field::Cmd { name, args })
        }
        _ => Err(Bad),
    }
}

fn parse_simple(toks: &[Tok]) -> P<Stmt> {
    let kw = match toks.first() {
        Some(Tok::Ident(k)) => k.as_str(),
        _ => return Err(Bad),
    };
    let rest = &toks[1..];
    match kw {
        "let" | "set" | "phony" => {
            let mut p = Cursor::new(rest);
            let name = p.ident()?;
            p.expect_sym("=")?;
            let e = p.expr()?;
            p.finish()?;
            Ok(match kw {
                "let" => Stmt::Let(name, e),
                "set" => Stmt::Set(name, e),
                _ => Stmt::Phony(name, e),
            })
        }
        "include" => Ok(Stmt::Include(parse_expr_all(rest)?)),
        "abort" => Ok(Stmt::Abort(parse_expr_all(rest)?)),
        "default" => Ok(Stmt::Default(parse_expr_all(rest)?)),
        "use" => {
            let mut p = Cursor::new(rest);
            let name = p.any_ident()?;
            p.expect_sym("(")?;
            let mut args: Vec<Arg> = Vec::new();
            let mut seen_kw = false;
            if !p.eat_sym(")") {
                loop {
                    let is_kwarg = match (p.peek(), p.peek_at(1)) {
                        (Some(Tok::Ident(n)), Some(t)) => !is_reserved(n) && is_sym(t, "="),
                        _ => false,
                    };
                    if is_kwarg {
                        let n = p.ident()?;
                        p.expect_sym("=")?;
                        args.push(Arg::Keyword(n, p.expr()?));
                        seen_kw = true;
                    } else {
                        if seen_kw {
                            return Err(Bad);
                        }
                        args.push(Arg::Positional(p.expr()?));
                    }
                    if p.eat_sym(",") {
                        if p.eat_sym(")") {
                            break;
                        }
                    } else {
                        p.expect_sym(")")?;
                        break;
                    }
                }
            }
            p.finish()?;
            Ok(Stmt::Use { name, args })
        }
        _ => Err(Bad),
    }
}

fn parse_expr_all(toks: &[Tok]) -> P<Expr> {
    let mut p = Cursor::new(toks);
    let e = p.expr()?;
    p.finish()?;
    Ok(e)
}

/// A recursive-descent expression parser over a token slice.
struct Cursor<'a> {
    toks: &'a [Tok],
    pos: usize,
}

impl<'a> Cursor<'a> {
    fn new(toks: &'a [Tok]) -> Cursor<'a> {
        Cursor { toks, pos: 0 }
    }

    fn peek(&self) -> Option<&'a Tok> {
        self.toks.get(self.pos)
    }

    fn peek_at(&self, n: usize) -> Option<&'a Tok> {
        self.toks.get(self.pos + n)
    }

    fn at_sym(&self, s: &str) -> bool {
        self.peek().is_some_and(|t| is_sym(t, s))
    }

    fn eat_sym(&mut self, s: &str) -> bool {
        if self.at_sym(s) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn eat_kw(&mut self, s: &str) -> bool {
        if self.peek().is_some_and(|t| is_kw(t, s)) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn expect_sym(&mut self, s: &str) -> P<()> {
        if self.eat_sym(s) {
            Ok(())
        } else {
            Err(Bad)
        }
    }

    fn finish(&self) -> P<()> {
        if self.pos == self.toks.len() {
            Ok(())
        } else {
            Err(Bad)
        }
    }

    /// An identifier that is not a reserved word.
    fn ident(&mut self) -> P<String> {
        match self.peek() {
            Some(Tok::Ident(n)) if !is_reserved(n) => {
                self.pos += 1;
                Ok(n.clone())
            }
            _ => Err(Bad),
        }
    }

    /// An identifier in a namespace of its own (reserved words allowed).
    fn any_ident(&mut self) -> P<String> {
        match self.peek() {
            Some(Tok::Ident(n)) => {
                self.pos += 1;
                Ok(n.clone())
            }
            _ => Err(Bad),
        }
    }

    fn expr(&mut self) -> P<Expr> {
        let mut lhs = self.or_expr()?;
        while self.eat_sym("|>") {
            let name = self.any_ident()?;
            let mut args = vec![lhs];
            if self.eat_sym("(") {
                args.extend(self.call_args()?);
            }
            lhs = Expr::Call(name, args);
        }
        Ok(lhs)
    }

    fn binary(&mut self, ops: &[(&str, BinOp)], next: fn(&mut Self) -> P<Expr>) -> P<Expr> {
        let mut lhs = next(self)?;
        'outer: loop {
            for (sym, op) in ops {
                if self.eat_sym(sym) {
                    let rhs = next(self)?;
                    lhs = Expr::Binary(*op, Box::new(lhs), Box::new(rhs));
                    continue 'outer;
                }
            }
            return Ok(lhs);
        }
    }

    fn or_expr(&mut self) -> P<Expr> {
        self.binary(&[("||", BinOp::Or)], Self::and_expr)
    }

    fn and_expr(&mut self) -> P<Expr> {
        self.binary(&[("&&", BinOp::And)], Self::cmp_expr)
    }

    fn cmp_expr(&mut self) -> P<Expr> {
        self.binary(
            &[("==", BinOp::Eq), ("!=", BinOp::Ne), ("<=", BinOp::Le), (">=", BinOp::Ge), ("<", BinOp::Lt), (">", BinOp::Gt)],
            Self::cat_expr,
        )
    }

    fn cat_expr(&mut self) -> P<Expr> {
        self.binary(&[("++", BinOp::Concat)], Self::str_expr)
    }

    fn str_expr(&mut self) -> P<Expr> {
        self.binary(&[("~", BinOp::StrCat)], Self::add_expr)
    }

    fn add_expr(&mut self) -> P<Expr> {
        self.binary(&[("+", BinOp::Add), ("-", BinOp::Sub)], Self::mul_expr)
    }

    fn mul_expr(&mut self) -> P<Expr> {
        self.binary(&[("*", BinOp::Mul), ("/", BinOp::Div), ("%", BinOp::Rem)], Self::unary_expr)
    }

    fn unary_expr(&mut self) -> P<Expr> {
        if self.eat_sym("!") {
            return Ok(Expr::Unary(UnOp::Not, Box::new(self.unary_expr()?)));
        }
        if self.eat_sym("-") {
            return Ok(Expr::Unary(UnOp::Neg, Box::new(self.unary_expr()?)));
        }
        self.postfix_expr()
    }

    fn postfix_expr(&mut self) -> P<Expr> {
        let mut e = self.primary()?;
        loop {
            if self.eat_sym("[") {
                let i = self.expr()?;
                self.expect_sym("]")?;
                e = Expr::Index(Box::new(e), Box::new(i));
            } else if self.at_sym("(") {
                // A call applied to anything but a bare identifier.
                return Err(Bad);
            } else {
                return Ok(e);
            }
        }
    }

    /// Arguments after an already consumed `(`, through the closing `)`.
    fn call_args(&mut self) -> P<Vec<Expr>> {
        let mut args = Vec::new();
        if self.eat_sym(")") {
            return Ok(args);
        }
        loop {
            args.push(self.expr()?);
            if self.eat_sym(",") {
                if self.eat_sym(")") {
                    return Ok(args);
                }
            } else {
                self.expect_sym(")")?;
                return Ok(args);
            }
        }
    }

    fn primary(&mut self) -> P<Expr> {
        let tok = self.peek().ok_or(Bad)?;
        self.pos += 1;
        match tok {
            Tok::Int(n) => Ok(Expr::Lit(Value::Int(*n))),
            Tok::Str(lit) => parse_string(lit),
            Tok::Ident(name) => {
                if self.eat_sym("(") {
                    let args = self.call_args()?;
                    return Ok(Expr::Call(name.clone(), args));
                }
                match name.as_str() {
                    "true" => Ok(Expr::Lit(Value::Bool(true))),
                    "false" => Ok(Expr::Lit(Value::Bool(false))),
                    n if is_reserved(n) => Err(Bad),
                    n => Ok(Expr::Var(n.to_string())),
                }
            }
            Tok::Sym("(") => {
                let e = self.expr()?;
                self.expect_sym(")")?;
                Ok(e)
            }
            Tok::Sym("[") => {
                let mut items = Vec::new();
                if !self.eat_sym("]") {
                    loop {
                        items.push(self.expr()?);
                        if self.eat_sym(",") {
                            if self.eat_sym("]") {
                                break;
                            }
                        } else {
                            self.expect_sym("]")?;
                            break;
                        }
                    }
                }
                Ok(Expr::List(items))
            }
            _ => Err(Bad),
        }
    }
}

/// Reads a string literal token into an expression.
fn parse_string(lit: &StrLit) -> P<Expr> {
    let raw = &lit.raw;
    if !lit.double {
        let mut out = Vec::with_capacity(raw.len());
        let mut i = 0;
        while i < raw.len() {
            out.push(raw[i]);
            // `''` denotes one quote.
            i += if raw[i] == b'\'' { 2 } else { 1 };
        }
        return Ok(Expr::Lit(Value::str(out)));
    }
    let mut parts: Vec<Part> = Vec::new();
    let mut cur: Vec<u8> = Vec::new();
    let mut i = 0;
    while i < raw.len() {
        match raw[i] {
            b'\\' => {
                let c = match raw.get(i + 1) {
                    Some(b'\\') => b'\\',
                    Some(b'"') => b'"',
                    Some(b'n') => b'\n',
                    Some(b't') => b'\t',
                    Some(b'r') => b'\r',
                    Some(b'0') => 0,
                    _ => return Err(Bad),
                };
                cur.push(c);
                i += 2;
            }
            b'{' => {
                if raw.get(i + 1) == Some(&b'{') {
                    cur.push(b'{');
                    i += 2;
                } else {
                    let end = scan_region(raw, i + 1).ok_or(Bad)?;
                    let body = &raw[i + 1..end - 1];
                    let toks = tokenize(body).map_err(|_| Bad)?;
                    if toks.is_empty() {
                        return Err(Bad);
                    }
                    let e = parse_expr_all(&toks)?;
                    if !cur.is_empty() {
                        parts.push(Part::Lit(std::mem::take(&mut cur)));
                    }
                    parts.push(Part::Interp(e));
                    i = end;
                }
            }
            b'}' => {
                if raw.get(i + 1) == Some(&b'}') {
                    cur.push(b'}');
                    i += 2;
                } else {
                    return Err(Bad);
                }
            }
            b => {
                cur.push(b);
                i += 1;
            }
        }
    }
    if parts.is_empty() {
        return Ok(Expr::Lit(Value::str(cur)));
    }
    if !cur.is_empty() {
        parts.push(Part::Lit(cur));
    }
    Ok(Expr::Interp(parts))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn err(src: &str) -> usize {
        parse_file(src.as_bytes()).unwrap_err()
    }

    fn ok(src: &str) -> Vec<Stmt> {
        parse_file(src.as_bytes()).expect("parses")
    }

    #[test]
    fn parses_blocks() {
        let stmts = ok("rule r(a, b = 1) {\n step {\n out \"out/{a}\"\n cmd write(\"x\")\n }\n}\nwhen true {\n} elsewhen false {\n} otherwise {\n}\n");
        assert_eq!(stmts.len(), 2);
        match &stmts[1] {
            Stmt::When { branches, otherwise } => {
                assert_eq!(branches.len(), 2);
                assert!(otherwise.is_some());
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn error_priority() {
        assert_eq!(err("let = 1\nlet x = \"abc\n"), 2);
        assert_eq!(err("let = 1\nlet y = 2\n"), 1);
        assert_eq!(err("when true {\nlet = 1\n"), 2);
        assert_eq!(err("when true {\nwhen true {\nlet x = 1\n"), 2);
        assert_eq!(err("when true {\n} otherwise {\nlet x = 1\n"), 2);
    }

    #[test]
    fn terminators() {
        assert_eq!(err("}\n"), 1);
        assert_eq!(err("step {\n} otherwise {\n}\n"), 2);
        assert_eq!(err("when true {\n} otherwise {\n} elsewhen true {\n}\n"), 3);
        assert_eq!(err("when true {\n} otherwise {\n} otherwise {\n}\n"), 3);
        assert_eq!(err("when true {\n} foo\n"), 2);
        assert_eq!(err("{\n"), 1);
    }

    #[test]
    fn reserved_words() {
        assert_eq!(err("let in = 1\n"), 1);
        assert_eq!(err("let x = cost\n"), 1);
        ok("let x = true\n");
        ok("let x = 1 |> cost\n");
        ok("let x = true(1)\n");
        assert_eq!(err("let x = (f)(1)\n"), 1);
        assert_eq!(err("use f(cost = 1)\n"), 1);
        ok("use cost(1)\n");
    }

    #[test]
    fn strings() {
        ok("let x = \"a{{b}}c\\n\"\n");
        assert_eq!(err("let x = \"a}b\"\n"), 1);
        assert_eq!(err("let x = \"{}\"\n"), 1);
        assert_eq!(err("let x = \"{ }\"\n"), 1);
        assert_eq!(err("let x = \"\\q\"\n"), 1);
        assert_eq!(err("let x = \"{1 2}\"\n"), 1);
        ok("let x = \"{join(xs, \", \")}\"\n");
    }

    #[test]
    fn rule_params() {
        assert_eq!(err("rule r(a, a) {\n}\n"), 1);
        assert_eq!(err("rule r(a = 1, b) {\n}\n"), 1);
        ok("rule r(a, b = a,) {\n}\n");
    }

    #[test]
    fn each_names_differ() {
        assert_eq!(err("each a, a in [] {\n}\n"), 1);
        ok("each i, a in [] {\n}\n");
    }

    #[test]
    fn use_arguments() {
        assert_eq!(err("use r(a = 1, 2)\n"), 1);
        ok("use r(1, a = 2,)\n");
        ok("use r(a == b)\n");
    }

    #[test]
    fn step_fields_only_in_steps() {
        assert_eq!(err("out \"x\"\n"), 1);
        assert_eq!(err("step {\nlet x = 1\n}\n"), 2);
        assert_eq!(err("step {\nstep {\n}\n}\n"), 2);
    }
}
