//! Recursive-descent parser: template source to [`Template`].

use crate::ast::{BinOp, CmpOp, Expr, MacroDef, Node, Template};
use crate::error::{Error, ErrorKind, Result};
use crate::filters::Filter;
use crate::lexer::{lex, Item, Token};
use crate::value::Value;
use std::collections::HashSet;
use std::rc::Rc;

const KEYWORDS: [&str; 8] = ["and", "or", "not", "in", "is", "true", "false", "none"];

/// Lexes, parses and filter-checks a template.
///
/// Any lexing or parsing problem is a `syntax` error; if the template parses,
/// an unknown filter name anywhere in it is a `filter` error.
pub fn parse_template(src: &str) -> Result<Template> {
    let items = lex(src)?;
    let mut parser = Parser {
        items,
        pos: 0,
        unknown_filter: false,
        has_extends: false,
        blocks: Vec::new(),
        block_names: HashSet::new(),
    };
    let (body, stop) = parser.parse_body(&[], true)?;
    debug_assert!(stop.is_none());
    if parser.unknown_filter {
        return Err(Error::new(ErrorKind::Filter, "unknown filter"));
    }
    Ok(Template { body, blocks: parser.blocks })
}

struct Parser {
    items: Vec<Item>,
    pos: usize,
    unknown_filter: bool,
    has_extends: bool,
    blocks: Vec<(Rc<str>, Rc<Vec<Node>>)>,
    block_names: HashSet<Rc<str>>,
}

/// A closing tag that ended a body: its keyword and remaining tokens.
type Stop = (Rc<str>, Vec<Token>);

/// Positional and keyword arguments of a call.
type CallArgs = (Vec<Expr>, Vec<(Rc<str>, Expr)>);

const CLOSERS: [&str; 6] = ["elif", "else", "endif", "endfor", "endmacro", "endblock"];

impl Parser {
    /// Parses nodes until one of the `stops` keywords (returned) or, when
    /// `stops` is empty, the end of the template. `top` is true only for the
    /// template's top level (where `extends` is allowed).
    fn parse_body(&mut self, stops: &[&str], top: bool) -> Result<(Vec<Node>, Option<Stop>)> {
        let mut nodes = Vec::new();
        while self.pos < self.items.len() {
            let item = std::mem::replace(&mut self.items[self.pos], Item::Text(String::new()));
            self.pos += 1;
            match item {
                Item::Text(t) => nodes.push(Node::Text(t)),
                Item::Print(tokens) => {
                    let mut ep = ExprParser::new(&tokens, &mut self.unknown_filter);
                    let e = ep.expr()?;
                    ep.finish()?;
                    nodes.push(Node::Print(e));
                }
                Item::Stmt(tokens) => {
                    let Some(Token::Name(kw)) = tokens.first() else {
                        return Err(Error::syntax("empty or malformed statement"));
                    };
                    let kw = kw.clone();
                    if stops.contains(&&*kw) {
                        return Ok((nodes, Some((kw, tokens))));
                    }
                    if CLOSERS.contains(&&*kw) {
                        return Err(Error::syntax(format!("unexpected '{}'", kw)));
                    }
                    nodes.push(self.statement(&kw, &tokens, top)?);
                }
            }
        }
        if stops.is_empty() {
            Ok((nodes, None))
        } else {
            Err(Error::syntax("unexpected end of template"))
        }
    }

    fn statement(&mut self, kw: &str, tokens: &[Token], top: bool) -> Result<Node> {
        let mut ep = ExprParser::new(&tokens[1..], &mut self.unknown_filter);
        match kw {
            "if" => {
                let cond = ep.expr()?;
                ep.finish()?;
                let mut branches = Vec::new();
                let mut else_body = None;
                let mut cond = Some(cond);
                loop {
                    let (body, stop) = self.parse_body(&["elif", "else", "endif"], false)?;
                    branches.push((cond.take().expect("condition"), body));
                    let (word, toks) = stop.expect("stop");
                    match &*word {
                        "elif" => {
                            let mut ep = ExprParser::new(&toks[1..], &mut self.unknown_filter);
                            cond = Some(ep.expr()?);
                            ep.finish()?;
                        }
                        "else" => {
                            ExprParser::new(&toks[1..], &mut self.unknown_filter).finish()?;
                            let (body, stop) = self.parse_body(&["endif"], false)?;
                            ExprParser::new(&stop.expect("stop").1[1..], &mut self.unknown_filter).finish()?;
                            else_body = Some(body);
                            break;
                        }
                        _ => {
                            ExprParser::new(&toks[1..], &mut self.unknown_filter).finish()?;
                            break;
                        }
                    }
                }
                Ok(Node::If(branches, else_body))
            }
            "for" => {
                let var = ep.name()?;
                ep.keyword("in")?;
                let iter = ep.expr()?;
                ep.finish()?;
                let (body, stop) = self.parse_body(&["else", "endfor"], false)?;
                let (word, toks) = stop.expect("stop");
                ExprParser::new(&toks[1..], &mut self.unknown_filter).finish()?;
                let mut else_body = Vec::new();
                if &*word == "else" {
                    let (b, stop) = self.parse_body(&["endfor"], false)?;
                    ExprParser::new(&stop.expect("stop").1[1..], &mut self.unknown_filter).finish()?;
                    else_body = b;
                }
                Ok(Node::For { var, iter, body, else_body })
            }
            "set" => {
                let name = ep.name()?;
                ep.punct("=")?;
                let e = ep.expr()?;
                ep.finish()?;
                Ok(Node::Set(name, e))
            }
            "macro" => {
                let name = ep.name()?;
                ep.punct("(")?;
                let mut params: Vec<(Rc<str>, Option<Expr>)> = Vec::new();
                if !ep.eat_punct(")") {
                    loop {
                        let p = ep.name()?;
                        if params.iter().any(|(q, _)| *q == p) {
                            return Err(Error::syntax("duplicate macro parameter"));
                        }
                        let default = if ep.eat_punct("=") { Some(ep.expr()?) } else { None };
                        params.push((p, default));
                        if ep.eat_punct(")") {
                            break;
                        }
                        ep.punct(",")?;
                    }
                }
                ep.finish()?;
                let (body, stop) = self.parse_body(&["endmacro"], false)?;
                ExprParser::new(&stop.expect("stop").1[1..], &mut self.unknown_filter).finish()?;
                Ok(Node::Macro(Rc::new(MacroDef { name, params, body })))
            }
            "include" => {
                let e = ep.expr()?;
                ep.finish()?;
                Ok(Node::Include(e))
            }
            "extends" => {
                let e = ep.expr()?;
                ep.finish()?;
                if !top || self.has_extends {
                    return Err(Error::syntax("misplaced or repeated extends"));
                }
                self.has_extends = true;
                Ok(Node::Extends(e))
            }
            "block" => {
                let name = ep.name()?;
                ep.finish()?;
                if !self.block_names.insert(name.clone()) {
                    return Err(Error::syntax("duplicate block name"));
                }
                // Reserve the slot so blocks are listed in order of appearance.
                let slot = self.blocks.len();
                self.blocks.push((name.clone(), Rc::new(Vec::new())));
                let (body, stop) = self.parse_body(&["endblock"], false)?;
                let toks = stop.expect("stop").1;
                let mut end = ExprParser::new(&toks[1..], &mut self.unknown_filter);
                if !end.at_end() && end.name()? != name {
                    return Err(Error::syntax("endblock name mismatch"));
                }
                end.finish()?;
                let body = Rc::new(body);
                self.blocks[slot].1 = body.clone();
                Ok(Node::Block { name, body })
            }
            other => Err(Error::syntax(format!("unknown statement '{}'", other))),
        }
    }
}

/// Parser over the tokens of one tag.
struct ExprParser<'a> {
    toks: &'a [Token],
    pos: usize,
    unknown_filter: &'a mut bool,
}

impl<'a> ExprParser<'a> {
    fn new(toks: &'a [Token], unknown_filter: &'a mut bool) -> Self {
        ExprParser { toks, pos: 0, unknown_filter }
    }

    fn peek(&self) -> Option<&'a Token> {
        self.toks.get(self.pos)
    }

    fn at_end(&self) -> bool {
        self.pos >= self.toks.len()
    }

    fn finish(&self) -> Result<()> {
        if self.at_end() {
            Ok(())
        } else {
            Err(Error::syntax("unexpected tokens at end of tag"))
        }
    }

    fn is_punct(&self, p: &str) -> bool {
        matches!(self.peek(), Some(Token::Punct(q)) if *q == p)
    }

    fn eat_punct(&mut self, p: &str) -> bool {
        if self.is_punct(p) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn punct(&mut self, p: &str) -> Result<()> {
        if self.eat_punct(p) {
            Ok(())
        } else {
            Err(Error::syntax(format!("expected '{}'", p)))
        }
    }

    fn is_keyword(&self, k: &str) -> bool {
        matches!(self.peek(), Some(Token::Name(n)) if &**n == k)
    }

    fn eat_keyword(&mut self, k: &str) -> bool {
        if self.is_keyword(k) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn keyword(&mut self, k: &str) -> Result<()> {
        if self.eat_keyword(k) {
            Ok(())
        } else {
            Err(Error::syntax(format!("expected '{}'", k)))
        }
    }

    /// A non-keyword identifier.
    fn name(&mut self) -> Result<Rc<str>> {
        match self.peek() {
            Some(Token::Name(n)) if !KEYWORDS.contains(&&**n) => {
                self.pos += 1;
                Ok(n.clone())
            }
            _ => Err(Error::syntax("expected a name")),
        }
    }

    fn expr(&mut self) -> Result<Expr> {
        let mut left = self.and()?;
        while self.eat_keyword("or") {
            let right = self.and()?;
            left = Expr::Or(Box::new(left), Box::new(right));
        }
        Ok(left)
    }

    fn and(&mut self) -> Result<Expr> {
        let mut left = self.not()?;
        while self.eat_keyword("and") {
            let right = self.not()?;
            left = Expr::And(Box::new(left), Box::new(right));
        }
        Ok(left)
    }

    fn not(&mut self) -> Result<Expr> {
        if self.eat_keyword("not") {
            return Ok(Expr::Not(Box::new(self.not()?)));
        }
        self.compare()
    }

    fn cmp_op(&mut self) -> Option<CmpOp> {
        let op = match self.peek()? {
            Token::Punct("==") => CmpOp::Eq,
            Token::Punct("!=") => CmpOp::Ne,
            Token::Punct("<") => CmpOp::Lt,
            Token::Punct("<=") => CmpOp::Le,
            Token::Punct(">") => CmpOp::Gt,
            Token::Punct(">=") => CmpOp::Ge,
            Token::Name(n) if &**n == "in" => CmpOp::In,
            Token::Name(n) if &**n == "not" => {
                if matches!(self.toks.get(self.pos + 1), Some(Token::Name(m)) if &**m == "in") {
                    self.pos += 1;
                    CmpOp::NotIn
                } else {
                    return None;
                }
            }
            _ => return None,
        };
        self.pos += 1;
        Some(op)
    }

    fn compare(&mut self) -> Result<Expr> {
        let first = self.additive()?;
        let mut rest = Vec::new();
        while let Some(op) = self.cmp_op() {
            rest.push((op, self.additive()?));
        }
        Ok(if rest.is_empty() { first } else { Expr::Compare(Box::new(first), rest) })
    }

    fn additive(&mut self) -> Result<Expr> {
        let mut left = self.concat()?;
        loop {
            let op = if self.is_punct("+") {
                BinOp::Add
            } else if self.is_punct("-") {
                BinOp::Sub
            } else {
                return Ok(left);
            };
            self.pos += 1;
            let right = self.concat()?;
            left = Expr::Bin(op, Box::new(left), Box::new(right));
        }
    }

    fn concat(&mut self) -> Result<Expr> {
        let mut left = self.term()?;
        while self.eat_punct("~") {
            let right = self.term()?;
            left = Expr::Bin(BinOp::Concat, Box::new(left), Box::new(right));
        }
        Ok(left)
    }

    fn term(&mut self) -> Result<Expr> {
        let mut left = self.power()?;
        loop {
            let op = match self.peek() {
                Some(Token::Punct("*")) => BinOp::Mul,
                Some(Token::Punct("/")) => BinOp::Div,
                Some(Token::Punct("//")) => BinOp::FloorDiv,
                Some(Token::Punct("%")) => BinOp::Mod,
                _ => return Ok(left),
            };
            self.pos += 1;
            let right = self.power()?;
            left = Expr::Bin(op, Box::new(left), Box::new(right));
        }
    }

    fn power(&mut self) -> Result<Expr> {
        let mut left = self.filtered()?;
        while self.eat_punct("**") {
            let right = self.filtered()?;
            left = Expr::Bin(BinOp::Pow, Box::new(left), Box::new(right));
        }
        Ok(left)
    }

    fn filtered(&mut self) -> Result<Expr> {
        let mut e = self.unary()?;
        loop {
            if self.eat_punct("|") {
                let name = match self.peek() {
                    Some(Token::Name(n)) => n.clone(),
                    _ => return Err(Error::syntax("expected a filter name")),
                };
                self.pos += 1;
                let mut args = Vec::new();
                if self.eat_punct("(") && !self.eat_punct(")") {
                    loop {
                        args.push(self.expr()?);
                        if self.eat_punct(")") {
                            break;
                        }
                        self.punct(",")?;
                    }
                }
                match Filter::from_name(&name) {
                    Some(f) => e = Expr::Filter(Box::new(e), f, args),
                    None => {
                        // Reported as a `filter` error once the whole template parsed.
                        *self.unknown_filter = true;
                        e = Expr::Filter(Box::new(e), Filter::Default, args);
                    }
                }
            } else if self.eat_keyword("is") {
                let negated = self.eat_keyword("not");
                if !self.eat_keyword("defined") {
                    return Err(Error::syntax("unknown test"));
                }
                e = Expr::IsDefined(Box::new(e), negated);
            } else {
                return Ok(e);
            }
        }
    }

    fn unary(&mut self) -> Result<Expr> {
        if self.eat_punct("-") {
            return Ok(Expr::Neg(Box::new(self.unary()?)));
        }
        self.postfix()
    }

    fn postfix(&mut self) -> Result<Expr> {
        let mut e = self.primary()?;
        loop {
            if self.eat_punct(".") {
                match self.peek() {
                    Some(Token::Name(n)) => {
                        self.pos += 1;
                        e = Expr::Attr(Box::new(e), n.clone());
                    }
                    _ => return Err(Error::syntax("expected attribute name")),
                }
            } else if self.eat_punct("[") {
                let idx = self.expr()?;
                self.punct("]")?;
                e = Expr::Index(Box::new(e), Box::new(idx));
            } else if self.eat_punct("(") {
                let (args, kwargs) = self.call_args()?;
                e = Expr::Call(Box::new(e), args, kwargs);
            } else {
                return Ok(e);
            }
        }
    }

    fn call_args(&mut self) -> Result<CallArgs> {
        let mut args = Vec::new();
        let mut kwargs: Vec<(Rc<str>, Expr)> = Vec::new();
        if self.eat_punct(")") {
            return Ok((args, kwargs));
        }
        loop {
            let is_kw = matches!(
                (self.toks.get(self.pos), self.toks.get(self.pos + 1)),
                (Some(Token::Name(n)), Some(Token::Punct("="))) if !KEYWORDS.contains(&&**n)
            );
            if is_kw {
                let name = self.name()?;
                self.pos += 1; // '='
                if kwargs.iter().any(|(k, _)| *k == name) {
                    return Err(Error::syntax("repeated keyword argument"));
                }
                kwargs.push((name, self.expr()?));
            } else {
                if !kwargs.is_empty() {
                    return Err(Error::syntax("positional argument after keyword argument"));
                }
                args.push(self.expr()?);
            }
            if self.eat_punct(")") {
                return Ok((args, kwargs));
            }
            self.punct(",")?;
        }
    }

    fn primary(&mut self) -> Result<Expr> {
        let tok = self.peek().ok_or_else(|| Error::syntax("unexpected end of expression"))?;
        self.pos += 1;
        match tok {
            Token::Int(i) => Ok(Expr::Lit(Value::Int(*i))),
            Token::Float(f) => Ok(Expr::Lit(Value::Float(*f))),
            Token::Str(s) => Ok(Expr::Lit(Value::Str(s.clone()))),
            Token::Name(n) => match &**n {
                "true" => Ok(Expr::Lit(Value::Bool(true))),
                "false" => Ok(Expr::Lit(Value::Bool(false))),
                "none" => Ok(Expr::Lit(Value::None)),
                k if KEYWORDS.contains(&k) => Err(Error::syntax(format!("unexpected keyword '{}'", k))),
                _ => Ok(Expr::Name(n.clone())),
            },
            Token::Punct("[") => {
                let mut items = Vec::new();
                if !self.eat_punct("]") {
                    loop {
                        items.push(self.expr()?);
                        if self.eat_punct("]") {
                            break;
                        }
                        self.punct(",")?;
                    }
                }
                Ok(Expr::List(items))
            }
            Token::Punct("(") => {
                let e = self.expr()?;
                self.punct(")")?;
                Ok(e)
            }
            Token::Punct(p) => Err(Error::syntax(format!("unexpected '{}'", p))),
        }
    }
}
