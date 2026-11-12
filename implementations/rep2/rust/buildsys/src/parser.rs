//! The KBL parser: logical lines to statements, with a precedence-climbing
//! expression parser.

use std::rc::Rc;

use crate::ast::*;
use crate::error::Error;
use crate::lexer::{self, interpolation_end, tokenize, Line, Op, StrTok, Tok};

/// Reserved words: not usable as variable, parameter, rule or loop names.
pub const RESERVED: [&str; 21] = [
    "abort", "after", "cmd", "cost", "default", "depfile", "each", "elsewhen", "false", "in",
    "include", "let", "otherwise", "out", "phony", "rule", "set", "step", "true", "use", "when",
];

/// Whether `s` is a reserved word.
pub fn is_reserved(s: &str) -> bool {
    RESERVED.contains(&s)
}

/// Parses a whole build file. `file` is only used to label `E_PARSE` errors.
///
/// ```
/// let stmts = kiln::parser::parse_file(b"let x = 1 + 2\n", "main.kiln").unwrap();
/// assert_eq!(stmts.len(), 1);
/// let err = kiln::parser::parse_file(b"let = 1\n", "main.kiln").unwrap_err();
/// assert_eq!(err.to_string(), "E_PARSE main.kiln:1");
/// ```
pub fn parse_file(src: &[u8], file: &str) -> Result<Vec<Stmt>, Error> {
    let lines = lexer::lex(src).map_err(|l| Error::parse(file, l))?;
    let mut p = Parser {
        lines: &lines,
        pos: 0,
    };
    p.stmts(None).map_err(|l| Error::parse(file, l))
}

type PResult<T> = Result<T, ()>;
/// Statement-level result: the error is the offending line number.
type SResult<T> = Result<T, usize>;

struct Cur<'a> {
    toks: &'a [Tok],
    pos: usize,
}

impl<'a> Cur<'a> {
    fn new(toks: &'a [Tok]) -> Self {
        Cur { toks, pos: 0 }
    }

    fn peek(&self) -> Option<&'a Tok> {
        self.toks.get(self.pos)
    }

    fn peek_at(&self, n: usize) -> Option<&'a Tok> {
        self.toks.get(self.pos + n)
    }

    fn next(&mut self) -> Option<&'a Tok> {
        let t = self.toks.get(self.pos);
        if t.is_some() {
            self.pos += 1;
        }
        t
    }

    fn eat(&mut self, t: &Tok) -> bool {
        if self.peek() == Some(t) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn expect(&mut self, t: &Tok) -> PResult<()> {
        if self.eat(t) {
            Ok(())
        } else {
            Err(())
        }
    }

    fn at_end(&self) -> bool {
        self.pos >= self.toks.len()
    }

    fn ident(&mut self) -> PResult<&'a str> {
        match self.next() {
            Some(Tok::Ident(s)) => Ok(s),
            _ => Err(()),
        }
    }

    /// An identifier that is not a reserved word.
    fn name(&mut self) -> PResult<String> {
        let s = self.ident()?;
        if is_reserved(s) {
            Err(())
        } else {
            Ok(s.to_string())
        }
    }

    fn op(&mut self, ops: &[Op]) -> Option<Op> {
        if let Some(Tok::Op(o)) = self.peek() {
            if ops.contains(o) {
                self.pos += 1;
                return Some(*o);
            }
        }
        None
    }

    // ---- expressions -------------------------------------------------

    fn expr(&mut self) -> PResult<Expr> {
        let mut e = self.or_expr()?;
        while self.op(&[Op::Pipe]).is_some() {
            let name = self.ident()?.to_string();
            let mut args = vec![e];
            if self.eat(&Tok::LParen) {
                args.extend(self.args(&Tok::RParen)?);
            }
            e = Expr::Call(name, args);
        }
        Ok(e)
    }

    fn binary(
        &mut self,
        ops: &[Op],
        next: fn(&mut Self) -> PResult<Expr>,
    ) -> PResult<Expr> {
        let mut e = next(self)?;
        while let Some(op) = self.op(ops) {
            let r = next(self)?;
            e = Expr::Binary(op, Box::new(e), Box::new(r));
        }
        Ok(e)
    }

    fn or_expr(&mut self) -> PResult<Expr> {
        self.binary(&[Op::Or], Self::and_expr)
    }
    fn and_expr(&mut self) -> PResult<Expr> {
        self.binary(&[Op::And], Self::cmp_expr)
    }
    fn cmp_expr(&mut self) -> PResult<Expr> {
        self.binary(
            &[Op::Eq, Op::Ne, Op::Lt, Op::Le, Op::Gt, Op::Ge],
            Self::cat_expr,
        )
    }
    fn cat_expr(&mut self) -> PResult<Expr> {
        self.binary(&[Op::Concat], Self::str_expr)
    }
    fn str_expr(&mut self) -> PResult<Expr> {
        self.binary(&[Op::Tilde], Self::add_expr)
    }
    fn add_expr(&mut self) -> PResult<Expr> {
        self.binary(&[Op::Plus, Op::Minus], Self::mul_expr)
    }
    fn mul_expr(&mut self) -> PResult<Expr> {
        self.binary(&[Op::Star, Op::Slash, Op::Percent], Self::unary_expr)
    }

    fn unary_expr(&mut self) -> PResult<Expr> {
        if let Some(op) = self.op(&[Op::Not, Op::Minus]) {
            let e = self.unary_expr()?;
            return Ok(Expr::Unary(op, Box::new(e)));
        }
        self.postfix_expr()
    }

    fn postfix_expr(&mut self) -> PResult<Expr> {
        let mut e = self.primary()?;
        loop {
            match self.peek() {
                Some(Tok::LBracket) => {
                    self.pos += 1;
                    let i = self.expr()?;
                    self.expect(&Tok::RBracket)?;
                    e = Expr::Index(Box::new(e), Box::new(i));
                }
                // A call is only legal directly on an identifier, which
                // `primary` has already consumed.
                Some(Tok::LParen) => return Err(()),
                _ => return Ok(e),
            }
        }
    }

    fn primary(&mut self) -> PResult<Expr> {
        match self.next().ok_or(())? {
            Tok::Int(v) => Ok(Expr::Int(*v)),
            Tok::Str(StrTok::Single(b)) => Ok(Expr::Str(Rc::new(b.clone()))),
            Tok::Str(StrTok::Double(raw)) => parse_double(raw),
            Tok::Ident(name) => {
                if self.eat(&Tok::LParen) {
                    let args = self.args(&Tok::RParen)?;
                    Ok(Expr::Call(name.clone(), args))
                } else if name == "true" {
                    Ok(Expr::Bool(true))
                } else if name == "false" {
                    Ok(Expr::Bool(false))
                } else if is_reserved(name) {
                    Err(())
                } else {
                    Ok(Expr::Var(name.clone()))
                }
            }
            Tok::LParen => {
                let e = self.expr()?;
                self.expect(&Tok::RParen)?;
                Ok(e)
            }
            Tok::LBracket => Ok(Expr::List(self.args(&Tok::RBracket)?)),
            _ => Err(()),
        }
    }

    /// `[ expr { "," expr } [ "," ] ] close`, the opening token already eaten.
    fn args(&mut self, close: &Tok) -> PResult<Vec<Expr>> {
        let mut out = Vec::new();
        if self.eat(close) {
            return Ok(out);
        }
        loop {
            out.push(self.expr()?);
            if self.eat(&Tok::Comma) {
                if self.eat(close) {
                    return Ok(out);
                }
            } else {
                self.expect(close)?;
                return Ok(out);
            }
        }
    }
}

/// Parses an expression that must consume all of `toks`.
fn expr_all(toks: &[Tok]) -> PResult<Expr> {
    let mut c = Cur::new(toks);
    let e = c.expr()?;
    if c.at_end() {
        Ok(e)
    } else {
        Err(())
    }
}

/// Parses the raw content of a double-quoted literal.
fn parse_double(raw: &[u8]) -> PResult<Expr> {
    let mut parts: Vec<Part> = Vec::new();
    let mut lit: Vec<u8> = Vec::new();
    let mut i = 0;
    while i < raw.len() {
        match raw[i] {
            b'\\' => {
                let c = *raw.get(i + 1).ok_or(())?;
                lit.push(match c {
                    b'\\' => b'\\',
                    b'"' => b'"',
                    b'n' => b'\n',
                    b't' => b'\t',
                    b'r' => b'\r',
                    b'0' => 0,
                    _ => return Err(()),
                });
                i += 2;
            }
            b'{' => {
                if raw.get(i + 1) == Some(&b'{') {
                    lit.push(b'{');
                    i += 2;
                } else {
                    let end = interpolation_end(raw, i + 1).map_err(|_| ())?;
                    let toks = tokenize(&raw[i + 1..end]).map_err(|_| ())?;
                    if toks.is_empty() {
                        return Err(());
                    }
                    let e = expr_all(&toks)?;
                    if !lit.is_empty() {
                        parts.push(Part::Lit(std::mem::take(&mut lit)));
                    }
                    parts.push(Part::Expr(e));
                    i = end + 1;
                }
            }
            b'}' => {
                if raw.get(i + 1) == Some(&b'}') {
                    lit.push(b'}');
                    i += 2;
                } else {
                    return Err(());
                }
            }
            b => {
                lit.push(b);
                i += 1;
            }
        }
    }
    if parts.is_empty() {
        return Ok(Expr::Str(Rc::new(lit)));
    }
    if !lit.is_empty() {
        parts.push(Part::Lit(lit));
    }
    Ok(Expr::Interp(parts))
}

struct Parser<'a> {
    lines: &'a [Line],
    pos: usize,
}

enum Term {
    Close,
    Elsewhen(Expr),
    Otherwise,
}

impl<'a> Parser<'a> {
    /// Parses statements until a line starting with `}` (left unconsumed) or
    /// end of file. `header` is the line of the enclosing block header, if any.
    fn stmts(&mut self, header: Option<usize>) -> SResult<Vec<Stmt>> {
        let mut out = Vec::new();
        loop {
            let Some(line) = self.lines.get(self.pos) else {
                return match header {
                    Some(h) => Err(h),
                    None => Ok(out),
                };
            };
            if line.toks.first() == Some(&Tok::RBrace) {
                return match header {
                    Some(_) => Ok(out),
                    None => Err(line.no),
                };
            }
            self.pos += 1;
            out.push(self.stmt(line)?);
        }
    }

    /// Consumes the terminator line the previous `stmts` call stopped at.
    fn terminator(&mut self) -> SResult<Term> {
        let line = &self.lines[self.pos];
        self.pos += 1;
        let t = &line.toks;
        let bad = line.no;
        if t.len() == 1 {
            return Ok(Term::Close);
        }
        match (&t[1], t.last()) {
            (Tok::Ident(k), Some(Tok::LBrace)) if k == "elsewhen" && t.len() >= 4 => {
                let e = expr_all(&t[2..t.len() - 1]).map_err(|_| bad)?;
                Ok(Term::Elsewhen(e))
            }
            (Tok::Ident(k), Some(Tok::LBrace)) if k == "otherwise" && t.len() == 3 => {
                Ok(Term::Otherwise)
            }
            _ => Err(bad),
        }
    }

    /// Reads a block body followed by a plain `}`.
    fn plain_block(&mut self, header: usize) -> SResult<Vec<Stmt>> {
        let body = self.stmts(Some(header))?;
        let at = self.lines[self.pos].no;
        match self.terminator()? {
            Term::Close => Ok(body),
            _ => Err(at),
        }
    }

    fn stmt(&mut self, line: &Line) -> SResult<Stmt> {
        let bad = line.no;
        let t = &line.toks[..];
        let Some(Tok::Ident(kw)) = t.first() else {
            return Err(bad);
        };
        if t.last() == Some(&Tok::LBrace) {
            return self.header(line, kw);
        }
        self.simple(kw, t).map_err(|_| bad)
    }

    fn header(&mut self, line: &Line, kw: &str) -> SResult<Stmt> {
        let bad = line.no;
        let t = &line.toks[..];
        let inner = &t[..t.len() - 1];
        match kw {
            "step" => {
                if inner.len() != 1 {
                    return Err(bad);
                }
                let mut fields = Vec::new();
                loop {
                    let Some(l) = self.lines.get(self.pos) else {
                        return Err(bad);
                    };
                    if l.toks.first() == Some(&Tok::RBrace) {
                        break;
                    }
                    self.pos += 1;
                    fields.push(step_field(&l.toks).map_err(|_| l.no)?);
                }
                let at = self.lines[self.pos].no;
                match self.terminator()? {
                    Term::Close => Ok(Stmt::Step(fields)),
                    _ => Err(at),
                }
            }
            "when" => {
                let mut branches = Vec::new();
                let mut otherwise = None;
                let mut cond = expr_all(&inner[1..]).map_err(|_| bad)?;
                let mut header = bad;
                loop {
                    let body = self.stmts(Some(header))?;
                    let at = self.lines[self.pos].no;
                    match self.terminator()? {
                        Term::Close => {
                            branches.push((cond, body));
                            break;
                        }
                        Term::Elsewhen(e) => {
                            branches.push((cond, body));
                            cond = e;
                            header = at;
                        }
                        Term::Otherwise => {
                            branches.push((cond, body));
                            let body = self.plain_block(at)?;
                            otherwise = Some(body);
                            break;
                        }
                    }
                }
                Ok(Stmt::When {
                    branches,
                    otherwise,
                })
            }
            "each" => {
                let (index, name, subject) = each_header(inner).map_err(|_| bad)?;
                let body = self.plain_block(bad)?;
                Ok(Stmt::Each {
                    index,
                    name,
                    subject,
                    body,
                })
            }
            "rule" => {
                let (name, params) = rule_header(inner).map_err(|_| bad)?;
                let body = self.plain_block(bad)?;
                Ok(Stmt::Rule(Rc::new(RuleDef { name, params, body })))
            }
            _ => Err(bad),
        }
    }

    fn simple(&mut self, kw: &str, t: &[Tok]) -> PResult<Stmt> {
        match kw {
            "let" | "set" | "phony" => {
                let mut c = Cur::new(&t[1..]);
                let name = c.name()?;
                c.expect(&Tok::Assign)?;
                let e = expr_all(&t[1 + c.pos..])?;
                Ok(match kw {
                    "let" => Stmt::Let(name, e),
                    "set" => Stmt::Set(name, e),
                    _ => Stmt::Phony(name, e),
                })
            }
            "include" => Ok(Stmt::Include(expr_all(&t[1..])?)),
            "abort" => Ok(Stmt::Abort(expr_all(&t[1..])?)),
            "default" => Ok(Stmt::Default(expr_all(&t[1..])?)),
            "use" => {
                let mut c = Cur::new(&t[1..]);
                let rule = c.ident()?.to_string();
                c.expect(&Tok::LParen)?;
                let mut args = Vec::new();
                let mut seen_kw = false;
                if !c.eat(&Tok::RParen) {
                    loop {
                        let is_kw = matches!(
                            (c.peek(), c.peek_at(1)),
                            (Some(Tok::Ident(n)), Some(Tok::Assign)) if !is_reserved(n)
                        );
                        if is_kw {
                            let n = c.ident()?.to_string();
                            c.next();
                            args.push(Arg::Kw(n, c.expr()?));
                            seen_kw = true;
                        } else {
                            if seen_kw {
                                return Err(());
                            }
                            args.push(Arg::Pos(c.expr()?));
                        }
                        if c.eat(&Tok::Comma) {
                            if c.eat(&Tok::RParen) {
                                break;
                            }
                        } else {
                            c.expect(&Tok::RParen)?;
                            break;
                        }
                    }
                }
                if !c.at_end() {
                    return Err(());
                }
                Ok(Stmt::Use { rule, args })
            }
            _ => Err(()),
        }
    }
}

fn step_field(t: &[Tok]) -> PResult<StepField> {
    let Some(Tok::Ident(kw)) = t.first() else {
        return Err(());
    };
    match kw.as_str() {
        "out" => Ok(StepField::Out(expr_all(&t[1..])?)),
        "in" => Ok(StepField::In(expr_all(&t[1..])?)),
        "after" => Ok(StepField::After(expr_all(&t[1..])?)),
        "cost" => Ok(StepField::Cost(expr_all(&t[1..])?)),
        "depfile" => Ok(StepField::Depfile(expr_all(&t[1..])?)),
        "cmd" => {
            let mut c = Cur::new(&t[1..]);
            let name = c.ident()?.to_string();
            c.expect(&Tok::LParen)?;
            let args = c.args(&Tok::RParen)?;
            if !c.at_end() {
                return Err(());
            }
            Ok(StepField::Cmd { name, args })
        }
        _ => Err(()),
    }
}

/// `each IDENT [, IDENT] in EXPR` (without the trailing `{`).
fn each_header(t: &[Tok]) -> PResult<(Option<String>, String, Expr)> {
    let mut c = Cur::new(&t[1..]);
    let first = c.name()?;
    let (index, name) = if c.eat(&Tok::Comma) {
        let second = c.name()?;
        if first == second {
            return Err(());
        }
        (Some(first), second)
    } else {
        (None, first)
    };
    match c.next() {
        Some(Tok::Ident(k)) if k == "in" => {}
        _ => return Err(()),
    }
    let subject = expr_all(&t[1 + c.pos..])?;
    Ok((index, name, subject))
}

/// `rule IDENT ( params )` (without the trailing `{`).
fn rule_header(t: &[Tok]) -> PResult<(String, Vec<Param>)> {
    let mut c = Cur::new(&t[1..]);
    let name = c.name()?;
    c.expect(&Tok::LParen)?;
    let mut params: Vec<Param> = Vec::new();
    if !c.eat(&Tok::RParen) {
        loop {
            let pname = c.name()?;
            if params.iter().any(|p| p.name == pname) {
                return Err(());
            }
            let default = if c.eat(&Tok::Assign) {
                Some(c.expr()?)
            } else {
                None
            };
            if default.is_none() && params.last().is_some_and(|p| p.default.is_some()) {
                return Err(());
            }
            params.push(Param {
                name: pname,
                default,
            });
            if c.eat(&Tok::Comma) {
                if c.eat(&Tok::RParen) {
                    break;
                }
            } else {
                c.expect(&Tok::RParen)?;
                break;
            }
        }
    }
    if !c.at_end() {
        return Err(());
    }
    Ok((name, params))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn err_line(src: &str) -> usize {
        let e = parse_file(src.as_bytes(), "f").unwrap_err();
        let d = String::from_utf8_lossy(e.detail()).into_owned();
        d.rsplit(':').next().unwrap().parse().unwrap()
    }

    fn ok(src: &str) -> Vec<Stmt> {
        parse_file(src.as_bytes(), "f").unwrap()
    }

    #[test]
    fn simple_statements() {
        assert_eq!(ok("let a = 1\nset a = 2\nphony p = []\ndefault \"x\"\n").len(), 4);
        assert_eq!(ok("use r()\nuse r(1, k = 2,)\n").len(), 2);
    }

    #[test]
    fn reserved_words() {
        assert_eq!(err_line("let when = 1\n"), 1);
        assert_eq!(err_line("let x = in\n"), 1);
        ok("let x = true\n");
        ok("let x = 1 |> cost\n");
        ok("let x = true(1)\n");
        ok("use when()\n");
    }

    #[test]
    fn use_arg_rules() {
        assert_eq!(err_line("use r(k = 1, 2)\n"), 1);
        ok("use r(a == b)\n");
    }

    #[test]
    fn blocks() {
        ok("when a {\nlet x = 1\n} elsewhen b {\n} otherwise {\n}\n");
        ok("each i, x in xs {\n}\nrule r(a, b = 1,) {\n}\nstep {\nout \"x\"\ncmd copy()\n}\n");
        assert_eq!(err_line("when a {\nlet x = 1\n"), 1);
        assert_eq!(err_line("when a {\neach x in y {\n"), 2);
        assert_eq!(err_line("}\n"), 1);
        assert_eq!(err_line("let x = 1\n} foo\n"), 2);
        assert_eq!(err_line("each x in y {\n} otherwise {\n}\n"), 2);
        assert_eq!(err_line("when a {\n} otherwise {\n} elsewhen b {\n}\n"), 3);
        assert_eq!(err_line("when a {\n} otherwise {\nlet x = 1\n"), 2);
        assert_eq!(err_line("{\n"), 1);
        assert_eq!(err_line("each x, x in y {\n}\n"), 1);
        assert_eq!(err_line("rule r(a = 1, b) {\n}\n"), 1);
        assert_eq!(err_line("rule r(a, a) {\n}\n"), 1);
    }

    #[test]
    fn step_fields_only_in_step() {
        assert_eq!(err_line("out \"x\"\n"), 1);
        assert_eq!(err_line("step {\nlet x = 1\n}\n"), 2);
        assert_eq!(err_line("step {\nstep {\n}\n}\n"), 2);
    }

    #[test]
    fn calls_only_on_identifiers() {
        assert_eq!(err_line("let x = f(1)(2)\n"), 1);
        assert_eq!(err_line("let x = (f)(2)\n"), 1);
        ok("let x = f(1)[0]\n");
    }

    #[test]
    fn string_literals() {
        ok("let x = \"a{{b}}c{1 + 2}\"\n");
        assert_eq!(err_line("let x = \"a}b\"\n"), 1);
        assert_eq!(err_line("let x = \"{}\"\n"), 1);
        assert_eq!(err_line("let x = \"{ }\"\n"), 1);
        assert_eq!(err_line("let x = \"\\q\"\n"), 1);
        assert_eq!(err_line("let x = \"{1 2}\"\n"), 1);
    }

    #[test]
    fn lexical_errors_win_over_grammar_errors() {
        assert_eq!(err_line("let = 1\nlet x = \"abc\n"), 2);
    }
}
