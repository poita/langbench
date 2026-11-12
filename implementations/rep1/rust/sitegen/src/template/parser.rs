//! Parsing a template: statements by recursive descent over the tag stream,
//! expressions by precedence climbing over each tag's tokens.

use std::collections::{HashMap, HashSet};
use std::rc::Rc;

use super::ast::*;
use super::error::{Error, Result};
use super::lexer::{lex, Item, Tok};
use super::value::Value;

const KEYWORDS: [&str; 8] = ["and", "or", "not", "in", "is", "true", "false", "none"];

/// Parse a template source. Reports `Syntax` errors, then `Filter` errors.
pub(crate) fn parse_template(src: &str) -> Result<Template> {
    let items = lex(src)?;
    let mut p = Parser {
        items,
        pos: 0,
        unknown_filter: false,
        block_names: HashSet::new(),
        blocks: HashMap::new(),
        seen_extends: false,
    };
    let (body, term) = p.parse_body(0)?;
    if term.is_some() {
        return Err(Error::syntax("unexpected closing tag"));
    }
    if p.unknown_filter {
        return Err(Error::new(
            super::error::ErrorKind::Filter,
            "unknown filter",
        ));
    }
    Ok(Template {
        body,
        blocks: p.blocks,
    })
}

struct Terminator {
    keyword: Rc<str>,
    tokens: Vec<Tok>,
}

struct Parser {
    items: Vec<Item>,
    pos: usize,
    unknown_filter: bool,
    block_names: HashSet<Rc<str>>,
    blocks: HashMap<Rc<str>, Rc<BlockDef>>,
    seen_extends: bool,
}

fn syntax<T>(msg: &str) -> Result<T> {
    Err(Error::syntax(msg))
}

impl Parser {
    /// Parse nodes until a closing keyword (`else`, `endif`, ...) or the end
    /// of the template. `depth` is 0 at the top level of the template.
    fn parse_body(&mut self, depth: usize) -> Result<(Vec<Node>, Option<Terminator>)> {
        let mut nodes = Vec::new();
        while self.pos < self.items.len() {
            let item = std::mem::replace(&mut self.items[self.pos], Item::Text(String::new()));
            self.pos += 1;
            match item {
                Item::Text(t) => nodes.push(Node::Text(t)),
                Item::Print(toks) => {
                    let e = self.parse_expr_all(&toks)?;
                    nodes.push(Node::Print(e));
                }
                Item::Stmt(toks) => {
                    let Some(Tok::Name(kw)) = toks.first() else {
                        return syntax("empty or malformed statement");
                    };
                    let kw = kw.clone();
                    match &*kw {
                        "if" => nodes.push(self.parse_if(&toks, depth)?),
                        "for" => nodes.push(self.parse_for(&toks, depth)?),
                        "set" => nodes.push(self.parse_set(&toks)?),
                        "macro" => nodes.push(self.parse_macro(&toks, depth)?),
                        "include" => {
                            let e = self.parse_expr_all(&toks[1..])?;
                            nodes.push(Node::Include(e));
                        }
                        "extends" => {
                            if depth != 0 || self.seen_extends {
                                return syntax("misplaced extends");
                            }
                            self.seen_extends = true;
                            let e = self.parse_expr_all(&toks[1..])?;
                            nodes.push(Node::Extends(e));
                        }
                        "block" => nodes.push(self.parse_block(&toks, depth)?),
                        "elif" | "else" | "endif" | "endfor" | "endmacro" | "endblock" => {
                            return Ok((
                                nodes,
                                Some(Terminator {
                                    keyword: kw,
                                    tokens: toks[1..].to_vec(),
                                }),
                            ));
                        }
                        _ => return syntax("unknown statement"),
                    }
                }
            }
        }
        Ok((nodes, None))
    }

    /// Parse a body that must end with the given closing keyword.
    fn parse_until(&mut self, depth: usize, end: &str) -> Result<Vec<Node>> {
        let (body, term) = self.parse_body(depth)?;
        match term {
            Some(t) if &*t.keyword == end && t.tokens.is_empty() => Ok(body),
            _ => syntax("missing or mismatched closing tag"),
        }
    }

    fn parse_if(&mut self, toks: &[Tok], depth: usize) -> Result<Node> {
        let mut branches = Vec::new();
        let mut cond = self.parse_expr_all(&toks[1..])?;
        let mut otherwise = None;
        loop {
            let (body, term) = self.parse_body(depth + 1)?;
            branches.push((cond, body));
            let Some(t) = term else {
                return syntax("unclosed if");
            };
            match &*t.keyword {
                "elif" => cond = self.parse_expr_all(&t.tokens)?,
                "else" => {
                    if !t.tokens.is_empty() {
                        return syntax("unexpected tokens after else");
                    }
                    otherwise = Some(self.parse_until(depth + 1, "endif")?);
                    break;
                }
                "endif" => {
                    if !t.tokens.is_empty() {
                        return syntax("unexpected tokens after endif");
                    }
                    break;
                }
                _ => return syntax("mismatched closing tag in if"),
            }
        }
        Ok(Node::If {
            branches,
            otherwise,
        })
    }

    fn name_token(tok: Option<&Tok>) -> Result<Rc<str>> {
        match tok {
            Some(Tok::Name(n)) if !KEYWORDS.contains(&&**n) => Ok(n.clone()),
            _ => syntax("expected a name"),
        }
    }

    fn parse_for(&mut self, toks: &[Tok], depth: usize) -> Result<Node> {
        let var = Self::name_token(toks.get(1))?;
        match toks.get(2) {
            Some(Tok::Name(n)) if &**n == "in" => {}
            _ => return syntax("expected `in`"),
        }
        let iter = self.parse_expr_all(&toks[3..])?;
        let (body, term) = self.parse_body(depth + 1)?;
        let Some(t) = term else {
            return syntax("unclosed for");
        };
        if !t.tokens.is_empty() {
            return syntax("unexpected tokens after keyword");
        }
        match &*t.keyword {
            "endfor" => Ok(Node::For {
                var,
                iter,
                body,
                otherwise: None,
            }),
            "else" => {
                let otherwise = self.parse_until(depth + 1, "endfor")?;
                Ok(Node::For {
                    var,
                    iter,
                    body,
                    otherwise: Some(otherwise),
                })
            }
            _ => syntax("mismatched closing tag in for"),
        }
    }

    fn parse_set(&mut self, toks: &[Tok]) -> Result<Node> {
        let name = Self::name_token(toks.get(1))?;
        match toks.get(2) {
            Some(Tok::Op("=")) => {}
            _ => return syntax("expected `=`"),
        }
        let e = self.parse_expr_all(&toks[3..])?;
        Ok(Node::Set(name, e))
    }

    fn parse_macro(&mut self, toks: &[Tok], depth: usize) -> Result<Node> {
        let name = Self::name_token(toks.get(1))?;
        match toks.get(2) {
            Some(Tok::Op("(")) => {}
            _ => return syntax("expected `(`"),
        }
        let mut ep = ExprParser {
            toks,
            pos: 3,
            unknown_filter: &mut self.unknown_filter,
        };
        let mut params: Vec<(Rc<str>, Option<Expr>)> = Vec::new();
        if ep.eat_op(")") {
            // no parameters
        } else {
            loop {
                let pname = Self::name_token(ep.toks.get(ep.pos))?;
                ep.pos += 1;
                if params.iter().any(|(n, _)| *n == pname) {
                    return syntax("duplicate parameter");
                }
                let default = if ep.eat_op("=") {
                    Some(ep.parse_expr()?)
                } else {
                    None
                };
                params.push((pname, default));
                if ep.eat_op(",") {
                    continue;
                }
                if ep.eat_op(")") {
                    break;
                }
                return syntax("expected `,` or `)`");
            }
        }
        if ep.pos != toks.len() {
            return syntax("unexpected tokens after macro parameters");
        }
        let body = self.parse_until(depth + 1, "endmacro")?;
        Ok(Node::Macro(Rc::new(MacroDef { name, params, body })))
    }

    fn parse_block(&mut self, toks: &[Tok], depth: usize) -> Result<Node> {
        let name = Self::name_token(toks.get(1))?;
        if toks.len() != 2 {
            return syntax("unexpected tokens after block name");
        }
        if !self.block_names.insert(name.clone()) {
            return syntax("duplicate block name");
        }
        let (body, term) = self.parse_body(depth + 1)?;
        match term {
            Some(t) if &*t.keyword == "endblock" => match t.tokens.as_slice() {
                [] => {}
                [Tok::Name(n)] if *n == name => {}
                _ => return syntax("mismatched endblock"),
            },
            _ => return syntax("unclosed block"),
        }
        let def = Rc::new(BlockDef {
            name: name.clone(),
            body,
        });
        self.blocks.insert(name, def.clone());
        Ok(Node::Block(def))
    }

    fn parse_expr_all(&mut self, toks: &[Tok]) -> Result<Expr> {
        let mut ep = ExprParser {
            toks,
            pos: 0,
            unknown_filter: &mut self.unknown_filter,
        };
        let e = ep.parse_expr()?;
        if ep.pos != toks.len() {
            return syntax("unexpected tokens after expression");
        }
        Ok(e)
    }
}

/// Positional and keyword arguments of a call.
type CallArgs = (Vec<Expr>, Vec<(Rc<str>, Expr)>);

struct ExprParser<'a> {
    toks: &'a [Tok],
    pos: usize,
    unknown_filter: &'a mut bool,
}

impl<'a> ExprParser<'a> {
    fn peek(&self) -> Option<&Tok> {
        self.toks.get(self.pos)
    }

    fn is_op(&self, op: &str) -> bool {
        matches!(self.peek(), Some(Tok::Op(o)) if *o == op)
    }

    fn eat_op(&mut self, op: &str) -> bool {
        if self.is_op(op) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn is_kw(&self, kw: &str) -> bool {
        matches!(self.peek(), Some(Tok::Name(n)) if &**n == kw)
    }

    fn eat_kw(&mut self, kw: &str) -> bool {
        if self.is_kw(kw) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn expect_op(&mut self, op: &str) -> Result<()> {
        if self.eat_op(op) {
            Ok(())
        } else {
            syntax("unexpected token")
        }
    }

    fn parse_expr(&mut self) -> Result<Expr> {
        self.parse_or()
    }

    fn parse_or(&mut self) -> Result<Expr> {
        let mut left = self.parse_and()?;
        while self.eat_kw("or") {
            let right = self.parse_and()?;
            left = Expr::Or(Box::new(left), Box::new(right));
        }
        Ok(left)
    }

    fn parse_and(&mut self) -> Result<Expr> {
        let mut left = self.parse_not()?;
        while self.eat_kw("and") {
            let right = self.parse_not()?;
            left = Expr::And(Box::new(left), Box::new(right));
        }
        Ok(left)
    }

    fn parse_not(&mut self) -> Result<Expr> {
        if self.eat_kw("not") {
            let e = self.parse_not()?;
            return Ok(Expr::Not(Box::new(e)));
        }
        self.parse_compare()
    }

    fn parse_compare(&mut self) -> Result<Expr> {
        let left = self.parse_additive()?;
        let mut rest = Vec::new();
        loop {
            let op = match self.peek() {
                Some(Tok::Op("==")) => CmpOp::Eq,
                Some(Tok::Op("!=")) => CmpOp::Ne,
                Some(Tok::Op("<")) => CmpOp::Lt,
                Some(Tok::Op("<=")) => CmpOp::Le,
                Some(Tok::Op(">")) => CmpOp::Gt,
                Some(Tok::Op(">=")) => CmpOp::Ge,
                Some(Tok::Name(n)) if &**n == "in" => CmpOp::In,
                Some(Tok::Name(n))
                    if &**n == "not"
                        && matches!(self.toks.get(self.pos + 1), Some(Tok::Name(m)) if &**m == "in") =>
                {
                    self.pos += 1;
                    CmpOp::NotIn
                }
                _ => break,
            };
            self.pos += 1;
            let right = self.parse_additive()?;
            rest.push((op, right));
        }
        if rest.is_empty() {
            Ok(left)
        } else {
            Ok(Expr::Compare(Box::new(left), rest))
        }
    }

    fn parse_additive(&mut self) -> Result<Expr> {
        let mut left = self.parse_concat()?;
        loop {
            let op = if self.is_op("+") {
                BinOp::Add
            } else if self.is_op("-") {
                BinOp::Sub
            } else {
                break;
            };
            self.pos += 1;
            let right = self.parse_concat()?;
            left = Expr::Binary(op, Box::new(left), Box::new(right));
        }
        Ok(left)
    }

    fn parse_concat(&mut self) -> Result<Expr> {
        let mut left = self.parse_term()?;
        while self.eat_op("~") {
            let right = self.parse_term()?;
            left = Expr::Binary(BinOp::Concat, Box::new(left), Box::new(right));
        }
        Ok(left)
    }

    fn parse_term(&mut self) -> Result<Expr> {
        let mut left = self.parse_power()?;
        loop {
            let op = match self.peek() {
                Some(Tok::Op("*")) => BinOp::Mul,
                Some(Tok::Op("/")) => BinOp::Div,
                Some(Tok::Op("//")) => BinOp::FloorDiv,
                Some(Tok::Op("%")) => BinOp::Mod,
                _ => break,
            };
            self.pos += 1;
            let right = self.parse_power()?;
            left = Expr::Binary(op, Box::new(left), Box::new(right));
        }
        Ok(left)
    }

    fn parse_power(&mut self) -> Result<Expr> {
        let mut left = self.parse_filtered()?;
        while self.eat_op("**") {
            let right = self.parse_filtered()?;
            left = Expr::Binary(BinOp::Pow, Box::new(left), Box::new(right));
        }
        Ok(left)
    }

    fn parse_filtered(&mut self) -> Result<Expr> {
        let mut e = self.parse_unary()?;
        loop {
            if self.eat_op("|") {
                let name = match self.peek() {
                    Some(Tok::Name(n)) => n.clone(),
                    _ => return syntax("expected filter name"),
                };
                self.pos += 1;
                let mut args = Vec::new();
                if self.eat_op("(") && !self.eat_op(")") {
                    loop {
                        args.push(self.parse_expr()?);
                        if self.eat_op(",") {
                            continue;
                        }
                        self.expect_op(")")?;
                        break;
                    }
                }
                let filter = Filter::from_name(&name);
                if filter.is_none() {
                    *self.unknown_filter = true;
                }
                e = Expr::Filter(Box::new(e), filter, args);
            } else if self.eat_kw("is") {
                let negate = self.eat_kw("not");
                if !self.eat_kw("defined") {
                    return syntax("unknown test");
                }
                e = Expr::IsDefined(Box::new(e), negate);
            } else {
                break;
            }
        }
        Ok(e)
    }

    fn parse_unary(&mut self) -> Result<Expr> {
        if self.eat_op("-") {
            let e = self.parse_unary()?;
            return Ok(Expr::Neg(Box::new(e)));
        }
        self.parse_postfix()
    }

    fn parse_postfix(&mut self) -> Result<Expr> {
        let mut e = self.parse_primary()?;
        loop {
            if self.eat_op(".") {
                match self.peek() {
                    Some(Tok::Name(n)) => {
                        let n = n.clone();
                        self.pos += 1;
                        e = Expr::Attr(Box::new(e), n);
                    }
                    _ => return syntax("expected attribute name"),
                }
            } else if self.eat_op("[") {
                let idx = self.parse_expr()?;
                self.expect_op("]")?;
                e = Expr::Index(Box::new(e), Box::new(idx));
            } else if self.eat_op("(") {
                let (args, kwargs) = self.parse_call_args()?;
                e = Expr::Call {
                    callee: Box::new(e),
                    args,
                    kwargs,
                };
            } else {
                break;
            }
        }
        Ok(e)
    }

    fn parse_call_args(&mut self) -> Result<CallArgs> {
        let mut args = Vec::new();
        let mut kwargs: Vec<(Rc<str>, Expr)> = Vec::new();
        if self.eat_op(")") {
            return Ok((args, kwargs));
        }
        loop {
            let is_kw = matches!(self.peek(), Some(Tok::Name(n)) if !KEYWORDS.contains(&&**n))
                && matches!(self.toks.get(self.pos + 1), Some(Tok::Op("=")));
            if is_kw {
                let Some(Tok::Name(n)) = self.peek() else {
                    unreachable!()
                };
                let n = n.clone();
                self.pos += 2;
                if kwargs.iter().any(|(k, _)| *k == n) {
                    return syntax("duplicate keyword argument");
                }
                let v = self.parse_expr()?;
                kwargs.push((n, v));
            } else {
                if !kwargs.is_empty() {
                    return syntax("positional argument after keyword argument");
                }
                args.push(self.parse_expr()?);
            }
            if self.eat_op(",") {
                continue;
            }
            self.expect_op(")")?;
            return Ok((args, kwargs));
        }
    }

    fn parse_primary(&mut self) -> Result<Expr> {
        let tok = match self.peek() {
            Some(t) => t.clone(),
            None => return syntax("unexpected end of expression"),
        };
        self.pos += 1;
        match tok {
            Tok::Int(i) => Ok(Expr::Const(Value::Int(i))),
            Tok::Float(f) => Ok(Expr::Const(Value::Float(f))),
            Tok::Str(s) => Ok(Expr::Const(Value::str(s))),
            Tok::Name(n) => match &*n {
                "true" => Ok(Expr::Const(Value::Bool(true))),
                "false" => Ok(Expr::Const(Value::Bool(false))),
                "none" => Ok(Expr::Const(Value::None)),
                k if KEYWORDS.contains(&k) => syntax("unexpected keyword"),
                _ => Ok(Expr::Name(n)),
            },
            Tok::Op("[") => {
                let mut items = Vec::new();
                if !self.eat_op("]") {
                    loop {
                        items.push(self.parse_expr()?);
                        if self.eat_op(",") {
                            continue;
                        }
                        self.expect_op("]")?;
                        break;
                    }
                }
                Ok(Expr::List(items))
            }
            Tok::Op("(") => {
                let e = self.parse_expr()?;
                self.expect_op(")")?;
                Ok(e)
            }
            Tok::Op(_) => syntax("unexpected operator"),
        }
    }
}
