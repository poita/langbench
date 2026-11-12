//! The tree-walking interpreter: scopes, statements and expressions.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;

use super::ast::*;
use super::error::{Error, ErrorKind, Result};
use super::filters;
use super::ops;
use super::value::{Dict, MacroValue, SuperRef, Value};
use super::Environment;

/// A lexical scope: a set of bindings and a parent.
pub struct Scope {
    vars: RefCell<Dict>,
    parent: Option<Rc<Scope>>,
}

impl Scope {
    pub(crate) fn new(parent: Option<Rc<Scope>>) -> Rc<Scope> {
        Rc::new(Scope {
            vars: RefCell::new(Dict::new()),
            parent,
        })
    }

    pub(crate) fn with_vars(vars: Dict) -> Rc<Scope> {
        Rc::new(Scope {
            vars: RefCell::new(vars),
            parent: None,
        })
    }

    fn lookup(&self, name: &str) -> Value {
        let mut scope = self;
        loop {
            if let Some(v) = scope.vars.borrow().get(name) {
                return v.clone();
            }
            match &scope.parent {
                Some(p) => scope = p,
                None => return Value::Undefined,
            }
        }
    }

    fn bind(&self, name: &Rc<str>, value: Value) {
        self.vars.borrow_mut().insert(name.clone(), value);
    }
}

/// Per-rendering state: the block chains and the template scope.
struct Rendering {
    chains: RefCell<HashMap<Rc<str>, Vec<Rc<BlockDef>>>>,
    scope: Rc<Scope>,
}

impl Rendering {
    fn new(scope: Rc<Scope>) -> Rendering {
        Rendering {
            chains: RefCell::new(HashMap::new()),
            scope,
        }
    }

    /// Append a template's own blocks to the chains, least derived last.
    fn add_blocks(&self, tpl: &Template) {
        let mut chains = self.chains.borrow_mut();
        for (name, def) in &tpl.blocks {
            chains.entry(name.clone()).or_default().push(def.clone());
        }
    }
}

const MAX_INCLUDE_DEPTH: usize = 200;

pub(crate) struct Interp<'e> {
    env: &'e Environment,
    depth: Cell<usize>,
    super_name: Rc<str>,
    loop_name: Rc<str>,
    loop_keys: [Rc<str>; 5],
}

impl<'e> Interp<'e> {
    pub(crate) fn new(env: &'e Environment) -> Interp<'e> {
        Interp {
            env,
            depth: Cell::new(0),
            super_name: Rc::from("super"),
            loop_name: Rc::from("loop"),
            loop_keys: [
                Rc::from("index"),
                Rc::from("index0"),
                Rc::from("first"),
                Rc::from("last"),
                Rc::from("length"),
            ],
        }
    }

    /// Render the main template with `root` as the root scope.
    pub(crate) fn render_main(&self, tpl: &Rc<Template>, root: Rc<Scope>) -> Result<String> {
        let scope = Scope::new(Some(root));
        let rc = Rendering::new(scope);
        rc.add_blocks(tpl);
        let mut out = String::new();
        self.run_template(tpl, &rc, &mut out)?;
        Ok(out)
    }

    fn run_template(&self, tpl: &Rc<Template>, rc: &Rendering, out: &mut String) -> Result<()> {
        let mut parent: Option<Rc<Template>> = None;
        let scope = rc.scope.clone();
        for node in &tpl.body {
            if parent.is_some() {
                if matches!(node, Node::Set(..) | Node::Macro(..)) {
                    self.exec_node(node, &scope, rc, out)?;
                }
                continue;
            }
            if let Node::Extends(e) = node {
                let name = self.eval(e, &scope, rc)?;
                let p = self.load_named(&name)?;
                rc.add_blocks(&p);
                parent = Some(p);
                continue;
            }
            self.exec_node(node, &scope, rc, out)?;
        }
        if let Some(p) = parent {
            self.run_template(&p, rc, out)?;
        }
        Ok(())
    }

    fn load_named(&self, name: &Value) -> Result<Rc<Template>> {
        match name {
            Value::Str(s) => self.env.load(s),
            Value::Undefined => Err(Error::undefined("undefined template name")),
            _ => Err(Error::type_error("template name is not a string")),
        }
    }

    fn exec_nodes(
        &self,
        nodes: &[Node],
        scope: &Rc<Scope>,
        rc: &Rendering,
        out: &mut String,
    ) -> Result<()> {
        for node in nodes {
            self.exec_node(node, scope, rc, out)?;
        }
        Ok(())
    }

    fn exec_node(
        &self,
        node: &Node,
        scope: &Rc<Scope>,
        rc: &Rendering,
        out: &mut String,
    ) -> Result<()> {
        match node {
            Node::Text(t) => out.push_str(t),
            Node::Print(e) => {
                let v = self.eval(e, scope, rc)?;
                if !v.write_to(out, false) {
                    return Err(Error::undefined("printing an undefined value"));
                }
            }
            Node::If {
                branches,
                otherwise,
            } => {
                for (cond, body) in branches {
                    let c = self.eval(cond, scope, rc)?;
                    if ops::truthy(&c)? {
                        return self.exec_nodes(body, scope, rc, out);
                    }
                }
                if let Some(body) = otherwise {
                    self.exec_nodes(body, scope, rc, out)?;
                }
            }
            Node::For {
                var,
                iter,
                body,
                otherwise,
            } => {
                let v = self.eval(iter, scope, rc)?;
                let seq = ops::seq_view(&v)?;
                if seq.is_empty() {
                    if let Some(body) = otherwise {
                        // Like Jinja2, the `else` body gets its own inner scope: it sees
                        // everything visible here but its `set`s and macros do not leak.
                        let s = Scope::new(Some(scope.clone()));
                        self.exec_nodes(body, &s, rc, out)?;
                    }
                    return Ok(());
                }
                let len = seq.len();
                for (i, item) in seq.iter().enumerate() {
                    let s = Scope::new(Some(scope.clone()));
                    s.bind(var, item.clone());
                    let mut l = Dict::new();
                    l.insert(self.loop_keys[0].clone(), Value::Int(i as i64 + 1));
                    l.insert(self.loop_keys[1].clone(), Value::Int(i as i64));
                    l.insert(self.loop_keys[2].clone(), Value::Bool(i == 0));
                    l.insert(self.loop_keys[3].clone(), Value::Bool(i + 1 == len));
                    l.insert(self.loop_keys[4].clone(), Value::Int(len as i64));
                    s.bind(&self.loop_name, Value::dict(l));
                    self.exec_nodes(body, &s, rc, out)?;
                }
            }
            Node::Set(name, e) => {
                let v = self.eval(e, scope, rc)?;
                scope.bind(name, v);
            }
            Node::Macro(def) => {
                let m = MacroValue {
                    def: def.clone(),
                    scope: Rc::downgrade(scope),
                };
                scope.bind(&def.name, Value::Macro(Rc::new(m)));
            }
            Node::Include(e) => {
                let name = self.eval(e, scope, rc)?;
                let tpl = self.load_named(&name)?;
                if self.depth.get() >= MAX_INCLUDE_DEPTH {
                    return Err(Error::new(
                        ErrorKind::Template,
                        "includes nested too deeply",
                    ));
                }
                self.depth.set(self.depth.get() + 1);
                let inc = Rendering::new(Scope::new(Some(scope.clone())));
                inc.add_blocks(&tpl);
                let r = self.run_template(&tpl, &inc, out);
                self.depth.set(self.depth.get() - 1);
                r?;
            }
            Node::Extends(_) => {}
            Node::Block(def) => {
                self.render_block(&def.name, 0, rc, out, Some(def))?;
            }
        }
        Ok(())
    }

    /// Render entry `index` of the chain for block `name`.
    fn render_block(
        &self,
        name: &Rc<str>,
        index: usize,
        rc: &Rendering,
        out: &mut String,
        fallback: Option<&Rc<BlockDef>>,
    ) -> Result<()> {
        let def = {
            let chains = rc.chains.borrow();
            chains.get(name).and_then(|c| c.get(index)).cloned()
        };
        let def = match def {
            Some(d) => d,
            None => match fallback {
                Some(f) => f.clone(),
                None => return Err(Error::undefined("super() without a less derived block")),
            },
        };
        let scope = Scope::new(Some(rc.scope.clone()));
        scope.bind(
            &self.super_name,
            Value::Super(Rc::new(SuperRef {
                name: name.clone(),
                index,
            })),
        );
        self.exec_nodes(&def.body, &scope, rc, out)
    }

    fn eval(&self, e: &Expr, scope: &Rc<Scope>, rc: &Rendering) -> Result<Value> {
        match e {
            Expr::Const(v) => Ok(v.clone()),
            Expr::Name(n) => Ok(scope.lookup(n)),
            Expr::List(items) => {
                let mut v = Vec::with_capacity(items.len());
                for i in items {
                    v.push(self.eval(i, scope, rc)?);
                }
                Ok(Value::list(v))
            }
            Expr::Attr(a, name) => {
                let a = self.eval(a, scope, rc)?;
                ops::get_attr(&a, name)
            }
            Expr::Index(a, k) => {
                let a = self.eval(a, scope, rc)?;
                let k = self.eval(k, scope, rc)?;
                ops::get_item(&a, &k)
            }
            Expr::Call {
                callee,
                args,
                kwargs,
            } => self.eval_call(callee, args, kwargs, scope, rc),
            Expr::Filter(input, filter, args) => {
                let v = self.eval(input, scope, rc)?;
                let mut argv = Vec::with_capacity(args.len());
                for a in args {
                    argv.push(self.eval(a, scope, rc)?);
                }
                match filter {
                    Some(f) => filters::apply(*f, v, &argv),
                    None => Err(Error::new(ErrorKind::Filter, "unknown filter")),
                }
            }
            Expr::IsDefined(inner, negate) => {
                let v = self.eval(inner, scope, rc)?;
                Ok(Value::Bool(v.is_undefined() == *negate))
            }
            Expr::Neg(inner) => {
                let v = self.eval(inner, scope, rc)?;
                ops::negate(&v)
            }
            Expr::Not(inner) => {
                let v = self.eval(inner, scope, rc)?;
                Ok(Value::Bool(!ops::truthy(&v)?))
            }
            Expr::Binary(op, l, r) => {
                let l = self.eval(l, scope, rc)?;
                let r = self.eval(r, scope, rc)?;
                ops::binary(*op, &l, &r)
            }
            Expr::And(l, r) => {
                let lv = self.eval(l, scope, rc)?;
                if !ops::truthy(&lv)? {
                    return Ok(lv);
                }
                self.eval(r, scope, rc)
            }
            Expr::Or(l, r) => {
                let lv = self.eval(l, scope, rc)?;
                if ops::truthy(&lv)? {
                    return Ok(lv);
                }
                self.eval(r, scope, rc)
            }
            Expr::Compare(first, rest) => {
                let mut left = self.eval(first, scope, rc)?;
                for (op, rhs) in rest {
                    let right = self.eval(rhs, scope, rc)?;
                    if !ops::compare(*op, &left, &right)? {
                        return Ok(Value::Bool(false));
                    }
                    left = right;
                }
                Ok(Value::Bool(true))
            }
        }
    }

    fn eval_call(
        &self,
        callee: &Expr,
        args: &[Expr],
        kwargs: &[(Rc<str>, Expr)],
        scope: &Rc<Scope>,
        rc: &Rendering,
    ) -> Result<Value> {
        let is_range_name = matches!(callee, Expr::Name(n) if &**n == "range");
        let f = self.eval(callee, scope, rc)?;
        let mut argv = Vec::with_capacity(args.len());
        for a in args {
            argv.push(self.eval(a, scope, rc)?);
        }
        let mut kwv = Vec::with_capacity(kwargs.len());
        for (k, v) in kwargs {
            kwv.push((k.clone(), self.eval(v, scope, rc)?));
        }
        match f {
            Value::Undefined if is_range_name => call_range(&argv, &kwv),
            Value::Undefined => Err(Error::undefined("calling an undefined value")),
            Value::Macro(m) => self.call_macro(&m, argv, kwv, rc),
            Value::Super(s) => {
                if !argv.is_empty() || !kwv.is_empty() {
                    return Err(Error::type_error("super() takes no arguments"));
                }
                let mut buf = String::new();
                self.render_block(&s.name, s.index + 1, rc, &mut buf, None)?;
                Ok(Value::from(buf))
            }
            _ => Err(Error::type_error("value is not callable")),
        }
    }

    fn call_macro(
        &self,
        m: &MacroValue,
        argv: Vec<Value>,
        kwv: Vec<(Rc<str>, Value)>,
        rc: &Rendering,
    ) -> Result<Value> {
        let def = &m.def;
        let parent = m
            .scope
            .upgrade()
            .ok_or_else(|| Error::undefined("macro called outside its defining scope"))?;
        if argv.len() > def.params.len() {
            return Err(Error::type_error("too many arguments for macro"));
        }
        let scope = Scope::new(Some(parent));
        let mut bound = vec![false; def.params.len()];
        for (i, v) in argv.into_iter().enumerate() {
            scope.bind(&def.params[i].0, v);
            bound[i] = true;
        }
        for (k, v) in kwv {
            match def.params.iter().position(|(n, _)| *n == k) {
                Some(i) if !bound[i] => {
                    scope.bind(&def.params[i].0, v);
                    bound[i] = true;
                }
                _ => return Err(Error::type_error("unknown or repeated keyword argument")),
            }
        }
        for (i, (name, default)) in def.params.iter().enumerate() {
            if bound[i] {
                continue;
            }
            let v = match default {
                Some(e) => self.eval(e, &scope, rc)?,
                None => Value::Undefined,
            };
            scope.bind(name, v);
        }
        let mut buf = String::new();
        self.exec_nodes(&def.body, &scope, rc, &mut buf)?;
        Ok(Value::from(buf))
    }
}

fn call_range(argv: &[Value], kwv: &[(Rc<str>, Value)]) -> Result<Value> {
    if !kwv.is_empty() {
        return Err(Error::type_error("range takes no keyword arguments"));
    }
    if argv.is_empty() || argv.len() > 3 {
        return Err(Error::type_error("range takes one to three arguments"));
    }
    let mut ints = Vec::with_capacity(3);
    for a in argv {
        match a {
            Value::Int(i) => ints.push(*i),
            Value::Bool(b) => ints.push(*b as i64),
            Value::Undefined => return Err(Error::undefined("undefined range argument")),
            _ => return Err(Error::type_error("range arguments must be integers")),
        }
    }
    let (start, stop, step) = match ints.as_slice() {
        [stop] => (0, *stop, 1),
        [start, stop] => (*start, *stop, 1),
        [start, stop, step] => (*start, *stop, *step),
        _ => unreachable!(),
    };
    if step == 0 {
        return Err(Error::type_error("range step must not be zero"));
    }
    let mut v = Vec::new();
    let mut i = start;
    while (step > 0 && i < stop) || (step < 0 && i > stop) {
        v.push(Value::Int(i));
        i = match i.checked_add(step) {
            Some(n) => n,
            None => break,
        };
    }
    Ok(Value::list(v))
}
