//! The analyser: converts datums into a tree of evaluable [`Node`]s.
//!
//! Every form (including every `lambda` body) is analysed exactly once,
//! before it first runs; the evaluator never looks at raw datums.

use std::rc::Rc;

use crate::error::{Error, Result};
use crate::value::{self, Symbol, Value};

/// An analysed procedure definition.
pub struct LambdaDef {
    /// Names of the required parameters.
    pub params: Vec<Symbol>,
    /// Name collecting the extra arguments, if any.
    pub rest: Option<Symbol>,
    /// The analysed body.
    pub body: Rc<Node>,
}

/// One clause of a `cond`.
pub struct CondClause {
    /// The test; `None` for an `else` clause.
    pub test: Option<Rc<Node>>,
    /// The body; `None` for a `(test)` clause that yields the test's value.
    pub body: Option<Rc<Node>>,
}

/// An analysed expression.
pub enum Node {
    /// A literal or quoted datum.
    Const(Value),
    /// A variable reference, resolved by name at run time.
    Var(Symbol),
    /// `(if test then [else])`.
    If(Rc<Node>, Rc<Node>, Option<Rc<Node>>),
    /// `(define name expr)`.
    Define(Symbol, Rc<Node>),
    /// `(set! name expr)`.
    Set(Symbol, Rc<Node>),
    /// `(lambda ...)`.
    Lambda(Rc<LambdaDef>),
    /// `(let ((v init) ...) body...)`.
    Let(Vec<(Symbol, Rc<Node>)>, Rc<Node>),
    /// `(let name ((v init) ...) body...)`; the lambda has the `v`s as parameters.
    NamedLet(Symbol, Vec<Rc<Node>>, Rc<LambdaDef>),
    /// `(let* ((v init) ...) body...)`.
    LetStar(Vec<(Symbol, Rc<Node>)>, Rc<Node>),
    /// `(letrec ((v init) ...) body...)`.
    Letrec(Vec<(Symbol, Rc<Node>)>, Rc<Node>),
    /// `(begin form...)`; also used for multi-form bodies.
    Begin(Vec<Rc<Node>>),
    /// `(cond clause...)`.
    Cond(Vec<CondClause>),
    /// `(and form...)`.
    And(Vec<Rc<Node>>),
    /// `(or form...)`.
    Or(Vec<Rc<Node>>),
    /// A procedure application.
    App(Rc<Node>, Vec<Rc<Node>>),
}

/// Analyses one datum into an evaluable tree.
pub fn analyze(datum: &Value) -> Result<Rc<Node>> {
    match datum {
        Value::Sym(s) => Ok(Rc::new(Node::Var(*s))),
        Value::Pair(p) => {
            if let Value::Sym(head) = &p.car {
                if let Some(node) = special_form(*head, &p.cdr)? {
                    return Ok(Rc::new(node));
                }
            }
            let items = items(datum)?;
            let f = analyze(&items[0])?;
            let args = items[1..].iter().map(analyze).collect::<Result<Vec<_>>>()?;
            Ok(Rc::new(Node::App(f, args)))
        }
        other => Ok(Rc::new(Node::Const(other.clone()))),
    }
}

/// The elements of a proper list, or a syntax error.
fn items(list: &Value) -> Result<Vec<Value>> {
    list.list_to_vec().ok_or_else(|| Error::syntax("improper list in form"))
}

fn analyze_all(forms: &[Value]) -> Result<Vec<Rc<Node>>> {
    forms.iter().map(analyze).collect()
}

/// Analyses a body (a sequence of forms) into a single node.
fn body(forms: &[Value]) -> Result<Rc<Node>> {
    let mut nodes = analyze_all(forms)?;
    Ok(match nodes.len() {
        0 => Rc::new(Node::Const(Value::Void)),
        1 => nodes.pop().unwrap(),
        _ => Rc::new(Node::Begin(nodes)),
    })
}

fn symbol_of(v: &Value) -> Result<Symbol> {
    match v {
        Value::Sym(s) => Ok(*s),
        _ => Err(Error::syntax("expected a symbol")),
    }
}

/// Parses a parameter specification: `(a b)`, `(a b . rest)` or `rest`.
fn params(spec: &Value) -> Result<(Vec<Symbol>, Option<Symbol>)> {
    let mut names = Vec::new();
    let mut cur = spec;
    loop {
        match cur {
            Value::Nil => return Ok((names, None)),
            Value::Sym(s) => return Ok((names, Some(*s))),
            Value::Pair(p) => {
                names.push(symbol_of(&p.car)?);
                cur = &p.cdr;
            }
            _ => return Err(Error::syntax("bad parameter list")),
        }
    }
}

fn lambda(spec: &Value, body_forms: &[Value]) -> Result<Rc<LambdaDef>> {
    let (params, rest) = params(spec)?;
    Ok(Rc::new(LambdaDef { params, rest, body: body(body_forms)? }))
}

/// Parses `((v init) ...)` into names and analysed inits.
fn bindings(spec: &Value) -> Result<Vec<(Symbol, Rc<Node>)>> {
    items(spec)?
        .iter()
        .map(|b| {
            let parts = items(b)?;
            if parts.len() != 2 {
                return Err(Error::syntax("binding must be (name init)"));
            }
            Ok((symbol_of(&parts[0])?, analyze(&parts[1])?))
        })
        .collect()
}

/// Analyses `(head . rest)` if `head` is a special-form keyword.
fn special_form(head: Symbol, rest: &Value) -> Result<Option<Node>> {
    if head.index() >= value::ELSE.index() {
        return Ok(None);
    }
    let args = items(rest)?;
    let need = |n: usize| -> Result<()> {
        if args.len() < n {
            Err(Error::syntax(format!("`{head}` needs at least {n} operand(s)")))
        } else {
            Ok(())
        }
    };
    let node = match head {
        value::QUOTE => {
            need(1)?;
            Node::Const(args[0].clone())
        }
        value::IF => {
            need(2)?;
            let alt = args.get(2).map(analyze).transpose()?;
            Node::If(analyze(&args[0])?, analyze(&args[1])?, alt)
        }
        value::DEFINE => {
            need(1)?;
            match &args[0] {
                Value::Pair(target) => {
                    let name = symbol_of(&target.car)?;
                    Node::Define(name, Rc::new(Node::Lambda(lambda(&target.cdr, &args[1..])?)))
                }
                name => {
                    need(2)?;
                    Node::Define(symbol_of(name)?, analyze(&args[1])?)
                }
            }
        }
        value::SET => {
            need(2)?;
            Node::Set(symbol_of(&args[0])?, analyze(&args[1])?)
        }
        value::LAMBDA => {
            need(1)?;
            Node::Lambda(lambda(&args[0], &args[1..])?)
        }
        value::LET => {
            need(1)?;
            if let Value::Sym(name) = &args[0] {
                need(2)?;
                let binds = bindings(&args[1])?;
                let (names, inits): (Vec<_>, Vec<_>) = binds.into_iter().unzip();
                let def = Rc::new(LambdaDef {
                    params: names,
                    rest: None,
                    body: body(&args[2..])?,
                });
                Node::NamedLet(*name, inits, def)
            } else {
                Node::Let(bindings(&args[0])?, body(&args[1..])?)
            }
        }
        value::LET_STAR => {
            need(1)?;
            Node::LetStar(bindings(&args[0])?, body(&args[1..])?)
        }
        value::LETREC => {
            need(1)?;
            Node::Letrec(bindings(&args[0])?, body(&args[1..])?)
        }
        value::BEGIN => {
            let nodes = analyze_all(&args)?;
            if nodes.is_empty() {
                Node::Const(Value::Void)
            } else {
                Node::Begin(nodes)
            }
        }
        value::COND => {
            let clauses = args
                .iter()
                .map(|c| {
                    let parts = items(c)?;
                    if parts.is_empty() {
                        return Err(Error::syntax("empty cond clause"));
                    }
                    let is_else = matches!(&parts[0], Value::Sym(s) if *s == value::ELSE);
                    let test = if is_else { None } else { Some(analyze(&parts[0])?) };
                    let body = if parts.len() > 1 {
                        Some(body(&parts[1..])?)
                    } else if is_else {
                        Some(Rc::new(Node::Const(Value::Void)))
                    } else {
                        None
                    };
                    Ok(CondClause { test, body })
                })
                .collect::<Result<Vec<_>>>()?;
            Node::Cond(clauses)
        }
        value::AND => Node::And(analyze_all(&args)?),
        value::OR => Node::Or(analyze_all(&args)?),
        _ => return Ok(None),
    };
    Ok(Some(node))
}
