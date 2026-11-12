//! The tree-walking interpreter.
//!
//! An [`Engine`] owns the context and the named template sources. Templates
//! are lexed, parsed and filter-checked lazily, once, the first time they
//! are needed. Rendering walks the syntax trees with a chain of lexical
//! scopes; inheritance keeps, per rendering, a map from block name to its
//! chain of bodies.

use crate::ast::{Expr, MacroDef, Node, Template};
use crate::error::{Error, ErrorKind, Result};
use crate::ops;
use crate::parser::parse_template;
use crate::scope::{Rendering, Scope};
use crate::value::{Dict, MacroVal, Num, SuperRef, Value};
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

/// Renders named templates against a JSON-like context.
pub struct Engine {
    context: Dict,
    sources: HashMap<String, String>,
    loaded: RefCell<HashMap<String, Rc<Template>>>,
    loop_keys: [Rc<str>; 5],
    loop_name: Rc<str>,
    super_name: Rc<str>,
}

impl Engine {
    /// Creates an engine from a context (which must be a dict; its members
    /// become the initial variables) and `(name, source)` template pairs.
    pub fn new<I>(context: Value, templates: I) -> Result<Engine>
    where
        I: IntoIterator<Item = (String, String)>,
    {
        let context = match context {
            Value::Dict(d) => Rc::try_unwrap(d).unwrap_or_else(|rc| (*rc).clone()),
            _ => return Err(Error::syntax("the context must be an object")),
        };
        Ok(Engine {
            context,
            sources: templates.into_iter().collect(),
            loaded: RefCell::new(HashMap::new()),
            loop_keys: ["index", "index0", "first", "last", "length"].map(Rc::from),
            loop_name: Rc::from("loop"),
            super_name: Rc::from("super"),
        })
    }

    /// Renders the template called `name`.
    ///
    /// Rendering is all-or-nothing: on error no partial output is returned.
    pub fn render(&self, name: &str) -> Result<String> {
        let template = self.load(name)?;
        let mut vars = Dict::new();
        vars.insert(Rc::from("range"), Value::Range);
        for (k, v) in self.context.iter() {
            vars.insert(k.clone(), v.clone());
        }
        let root = Scope::root(vars);
        let scope = Scope::child(&root);
        let rendering = Rendering::new(scope.clone());
        let mut out = String::new();
        self.run_template(&template, &scope, &rendering, &mut out)?;
        Ok(out)
    }

    /// Loads (lexes, parses, filter-checks) a template at most once.
    fn load(&self, name: &str) -> Result<Rc<Template>> {
        if let Some(t) = self.loaded.borrow().get(name) {
            return Ok(t.clone());
        }
        let src = self
            .sources
            .get(name)
            .ok_or_else(|| Error::new(ErrorKind::Template, format!("no template named '{}'", name)))?;
        let template = Rc::new(parse_template(src)?);
        self.loaded.borrow_mut().insert(name.to_string(), template.clone());
        Ok(template)
    }

    /// Resolves the template named by an `include`/`extends` expression.
    fn load_named(&self, name: &Value) -> Result<Rc<Template>> {
        match name {
            Value::Str(s) => self.load(s),
            Value::Undefined => Err(Error::undefined("template name is undefined")),
            other => Err(Error::type_error(format!("template name must be a string, not {}", other.kind_name()))),
        }
    }

    /// Appends a template's blocks to the rendering's chains.
    fn register_blocks(rendering: &Rendering, template: &Template) {
        let mut chains = rendering.chains.borrow_mut();
        for (name, body) in &template.blocks {
            chains.entry(name.clone()).or_default().push(body.clone());
        }
    }

    /// Runs a template's top level (and, after `extends`, its parents').
    fn run_template(
        &self,
        template: &Rc<Template>,
        scope: &Rc<Scope>,
        rendering: &Rc<Rendering>,
        out: &mut String,
    ) -> Result<()> {
        Self::register_blocks(rendering, template);
        let mut current = template.clone();
        loop {
            let mut parent: Option<Rc<Template>> = None;
            for node in &current.body {
                if parent.is_some() {
                    // After `extends` only `set` and `macro` still take effect.
                    if matches!(node, Node::Set(..) | Node::Macro(_)) {
                        self.exec(node, scope, rendering, out)?;
                    }
                    continue;
                }
                if let Node::Extends(e) = node {
                    let name = self.eval(e, scope)?;
                    let p = self.load_named(&name)?;
                    Self::register_blocks(rendering, &p);
                    parent = Some(p);
                } else {
                    self.exec(node, scope, rendering, out)?;
                }
            }
            match parent {
                Some(p) => current = p,
                None => return Ok(()),
            }
        }
    }

    fn exec_all(&self, nodes: &[Node], scope: &Rc<Scope>, rendering: &Rc<Rendering>, out: &mut String) -> Result<()> {
        for node in nodes {
            self.exec(node, scope, rendering, out)?;
        }
        Ok(())
    }

    fn exec(&self, node: &Node, scope: &Rc<Scope>, rendering: &Rc<Rendering>, out: &mut String) -> Result<()> {
        match node {
            Node::Text(t) => out.push_str(t),
            Node::Print(e) => self.eval(e, scope)?.write_str(out)?,
            Node::If(branches, else_body) => {
                for (cond, body) in branches {
                    if self.eval(cond, scope)?.truthy()? {
                        return self.exec_all(body, scope, rendering, out);
                    }
                }
                if let Some(body) = else_body {
                    self.exec_all(body, scope, rendering, out)?;
                }
            }
            Node::For { var, iter, body, else_body } => {
                let seq = self.eval(iter, scope)?.sequence()?;
                if seq.is_empty() {
                    return self.exec_all(else_body, scope, rendering, out);
                }
                let length = seq.len();
                for (i, item) in seq.iter().enumerate() {
                    let inner = Scope::child(scope);
                    inner.set(var.clone(), item.clone());
                    let mut info = Dict::new();
                    info.insert(self.loop_keys[0].clone(), Value::Int(i as i64 + 1));
                    info.insert(self.loop_keys[1].clone(), Value::Int(i as i64));
                    info.insert(self.loop_keys[2].clone(), Value::Bool(i == 0));
                    info.insert(self.loop_keys[3].clone(), Value::Bool(i + 1 == length));
                    info.insert(self.loop_keys[4].clone(), Value::Int(length as i64));
                    inner.set(self.loop_name.clone(), Value::dict(info));
                    self.exec_all(body, &inner, rendering, out)?;
                }
            }
            Node::Set(name, e) => {
                let v = self.eval(e, scope)?;
                scope.set(name.clone(), v);
            }
            Node::Macro(def) => {
                let m = MacroVal { def: def.clone(), scope: scope.clone(), rendering: rendering.clone() };
                scope.set(def.name.clone(), Value::Macro(Rc::new(m)));
            }
            Node::Include(e) => {
                let name = self.eval(e, scope)?;
                let template = self.load_named(&name)?;
                let inner = Scope::child(scope);
                let inner_rendering = Rendering::new(inner.clone());
                self.run_template(&template, &inner, &inner_rendering, out)?;
            }
            // Handled by `run_template`; `extends` is only legal at top level.
            Node::Extends(_) => {}
            Node::Block { name, body } => {
                let entry = rendering.chains.borrow().get(name).and_then(|c| c.first().cloned());
                let body = entry.unwrap_or_else(|| body.clone());
                self.render_block(rendering, name, 0, &body, out)?;
            }
        }
        Ok(())
    }

    /// Renders chain entry `index` of block `name` in a fresh block scope
    /// whose parent is the rendering's template scope.
    fn render_block(
        &self,
        rendering: &Rc<Rendering>,
        name: &Rc<str>,
        index: usize,
        body: &[Node],
        out: &mut String,
    ) -> Result<()> {
        let scope = Scope::child(&rendering.scope);
        let sup = SuperRef { rendering: rendering.clone(), name: name.clone(), index };
        scope.set(self.super_name.clone(), Value::Super(Rc::new(sup)));
        self.exec_all(body, &scope, rendering, out)
    }

    fn eval(&self, expr: &Expr, scope: &Rc<Scope>) -> Result<Value> {
        match expr {
            Expr::Lit(v) => Ok(v.clone()),
            Expr::Name(n) => Ok(scope.lookup(n)),
            Expr::List(items) => {
                let mut v = Vec::with_capacity(items.len());
                for e in items {
                    v.push(self.eval(e, scope)?);
                }
                Ok(Value::list(v))
            }
            Expr::Neg(e) => ops::neg(&self.eval(e, scope)?),
            Expr::Not(e) => Ok(Value::Bool(!self.eval(e, scope)?.truthy()?)),
            Expr::Bin(op, a, b) => {
                let a = self.eval(a, scope)?;
                let b = self.eval(b, scope)?;
                ops::binary(*op, &a, &b)
            }
            Expr::And(a, b) => {
                let l = self.eval(a, scope)?;
                if l.truthy()? {
                    self.eval(b, scope)
                } else {
                    Ok(l)
                }
            }
            Expr::Or(a, b) => {
                let l = self.eval(a, scope)?;
                if l.truthy()? {
                    Ok(l)
                } else {
                    self.eval(b, scope)
                }
            }
            Expr::Compare(first, rest) => {
                let mut left = self.eval(first, scope)?;
                for (op, e) in rest {
                    let right = self.eval(e, scope)?;
                    if !ops::compare(*op, &left, &right)? {
                        return Ok(Value::Bool(false));
                    }
                    left = right;
                }
                Ok(Value::Bool(true))
            }
            Expr::Filter(input, filter, args) => {
                let v = self.eval(input, scope)?;
                let mut values = Vec::with_capacity(args.len());
                for a in args {
                    values.push(self.eval(a, scope)?);
                }
                filter.apply(v, &values)
            }
            Expr::IsDefined(e, negated) => {
                let defined = !self.eval(e, scope)?.is_undefined();
                Ok(Value::Bool(defined != *negated))
            }
            Expr::Attr(e, name) => self.eval(e, scope)?.get_attr(name),
            Expr::Index(e, key) => {
                let base = self.eval(e, scope)?;
                let key = self.eval(key, scope)?;
                base.get_item(&key)
            }
            Expr::Call(callee, args, kwargs) => {
                let f = self.eval(callee, scope)?;
                let mut a = Vec::with_capacity(args.len());
                for e in args {
                    a.push(self.eval(e, scope)?);
                }
                let mut k = Vec::with_capacity(kwargs.len());
                for (name, e) in kwargs {
                    k.push((name.clone(), self.eval(e, scope)?));
                }
                self.call(f, a, k)
            }
        }
    }

    fn call(&self, callee: Value, args: Vec<Value>, kwargs: Vec<(Rc<str>, Value)>) -> Result<Value> {
        match callee {
            Value::Undefined => Err(Error::undefined("calling an undefined value")),
            Value::Macro(m) => self.call_macro(&m, args, kwargs),
            Value::Super(s) => {
                if !args.is_empty() || !kwargs.is_empty() {
                    return Err(Error::type_error("super() takes no arguments"));
                }
                let next = s.index + 1;
                let body = s.rendering.chains.borrow().get(&s.name).and_then(|c| c.get(next).cloned());
                let body = body.ok_or_else(|| Error::undefined("super() with no less-derived block"))?;
                let mut buf = String::new();
                self.render_block(&s.rendering, &s.name, next, &body, &mut buf)?;
                Ok(Value::str(buf))
            }
            Value::Range => range(&args, &kwargs),
            other => Err(Error::type_error(format!("{} is not callable", other.kind_name()))),
        }
    }

    fn call_macro(&self, m: &MacroVal, args: Vec<Value>, kwargs: Vec<(Rc<str>, Value)>) -> Result<Value> {
        let def: &MacroDef = &m.def;
        let scope = Scope::child(&m.scope);
        if args.len() > def.params.len() {
            return Err(Error::type_error("too many positional arguments to macro"));
        }
        let mut bound: Vec<Option<Value>> = vec![None; def.params.len()];
        for (slot, v) in bound.iter_mut().zip(args) {
            *slot = Some(v);
        }
        for (name, v) in kwargs {
            let i = def
                .params
                .iter()
                .position(|(p, _)| *p == name)
                .ok_or_else(|| Error::type_error(format!("unknown keyword argument '{}'", name)))?;
            if bound[i].is_some() {
                return Err(Error::type_error(format!("argument '{}' given twice", name)));
            }
            bound[i] = Some(v);
        }
        // Supplied arguments first, then defaults in declaration order.
        let supplied: Vec<bool> = bound.iter().map(Option::is_some).collect();
        for ((name, _), v) in def.params.iter().zip(&mut bound) {
            if let Some(v) = v.take() {
                scope.set(name.clone(), v);
            }
        }
        for ((name, default), was_supplied) in def.params.iter().zip(supplied) {
            if was_supplied {
                continue;
            }
            let v = match default {
                Some(e) => self.eval(e, &scope)?,
                None => Value::Undefined,
            };
            scope.set(name.clone(), v);
        }
        let mut buf = String::new();
        self.exec_all(&def.body, &scope, &m.rendering, &mut buf)?;
        Ok(Value::str(buf))
    }
}

/// The built-in `range`.
fn range(args: &[Value], kwargs: &[(Rc<str>, Value)]) -> Result<Value> {
    if !kwargs.is_empty() {
        return Err(Error::type_error("range() takes no keyword arguments"));
    }
    if args.is_empty() || args.len() > 3 {
        return Err(Error::type_error("range() takes 1 to 3 arguments"));
    }
    let mut ints = Vec::with_capacity(3);
    for a in args {
        a.defined()?;
        match Num::of(a) {
            Some(Num::I(i)) => ints.push(i),
            _ => return Err(Error::type_error("range() arguments must be integers")),
        }
    }
    let (start, stop, step) = match ints[..] {
        [stop] => (0, stop, 1),
        [start, stop] => (start, stop, 1),
        [start, stop, step] => (start, stop, step),
        _ => unreachable!(),
    };
    if step == 0 {
        return Err(Error::type_error("range() step must not be zero"));
    }
    let mut items = Vec::new();
    let mut i = start;
    while (step > 0 && i < stop) || (step < 0 && i > stop) {
        items.push(Value::Int(i));
        match i.checked_add(step) {
            Some(n) => i = n,
            None => break,
        }
    }
    Ok(Value::list(items))
}
