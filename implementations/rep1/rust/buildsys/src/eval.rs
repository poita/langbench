//! The KBL interpreter: evaluates build files into a [`Config`] (steps,
//! phony targets and default targets).

use crate::ast::*;
use crate::builtins;
use crate::command::{self, Command};
use crate::error::{Error, ErrorKind, Result};
use crate::parser::parse_file;
use crate::step::{check_reference, Phony, Step, StepBuilder};
use crate::value::Value;
use crate::workspace::{is_workspace_path, Workspace};
use std::cell::RefCell;
use std::cmp::Ordering;
use std::collections::HashMap;
use std::rc::Rc;

/// The maximum rule instantiation depth.
pub const MAX_RULE_DEPTH: usize = 64;

/// The root build file.
pub const MAIN_FILE: &[u8] = b"main.kiln";

/// The result of evaluating the build files.
#[derive(Debug, Default)]
pub struct Config {
    pub steps: Vec<Step>,
    pub phonies: Vec<Phony>,
    pub defaults: Vec<Vec<u8>>,
}

type ScopeRef = Rc<RefCell<Scope>>;

struct Scope {
    vars: HashMap<String, Value>,
    parent: Option<ScopeRef>,
}

fn new_scope(parent: Option<ScopeRef>) -> ScopeRef {
    Rc::new(RefCell::new(Scope { vars: HashMap::new(), parent }))
}

fn lookup_var(scope: &ScopeRef, name: &str) -> Option<Value> {
    let mut cur = Some(scope.clone());
    while let Some(s) = cur {
        let s = s.borrow();
        if let Some(v) = s.vars.get(name) {
            return Some(v.clone());
        }
        cur = s.parent.clone();
    }
    None
}

struct Rule {
    params: Vec<Param>,
    body: Rc<Vec<Stmt>>,
    scope: ScopeRef,
}

struct Evaluator<'a> {
    ws: &'a Workspace,
    config: Config,
    phony_index: HashMap<String, usize>,
    rules: HashMap<String, Rc<Rule>>,
    include_stack: Vec<Vec<u8>>,
    depth: usize,
}

/// Evaluates `main.kiln` (and everything it includes) against the workspace.
pub fn evaluate(ws: &Workspace) -> Result<Config> {
    if !ws.contains(MAIN_FILE) {
        return Err(Error::new(ErrorKind::NoBuildFile, "main.kiln"));
    }
    let mut ev = Evaluator {
        ws,
        config: Config::default(),
        phony_index: HashMap::new(),
        rules: HashMap::new(),
        include_stack: vec![MAIN_FILE.to_vec()],
        depth: 0,
    };
    let root = new_scope(None);
    let stmts = ev.parse(MAIN_FILE)?;
    ev.exec_block(&stmts, &root)?;
    Ok(ev.config)
}

impl<'a> Evaluator<'a> {
    fn parse(&self, path: &[u8]) -> Result<Vec<Stmt>> {
        let file = self.ws.get(path).expect("existence checked by the caller");
        parse_file(&file.content).map_err(|line| {
            let mut d = path.to_vec();
            d.extend_from_slice(format!(":{line}").as_bytes());
            Error::new(ErrorKind::Parse, d)
        })
    }

    // ---- expressions -----------------------------------------------------

    fn eval(&self, e: &Expr, scope: &ScopeRef) -> Result<Value> {
        match e {
            Expr::Lit(v) => Ok(v.clone()),
            Expr::Interp(parts) => {
                let mut out = Vec::new();
                for p in parts {
                    match p {
                        Part::Lit(b) => out.extend_from_slice(b),
                        Part::Interp(x) => match self.eval(x, scope)? {
                            Value::Str(s) => out.extend_from_slice(&s),
                            Value::Int(n) => out.extend_from_slice(n.to_string().as_bytes()),
                            Value::Bool(b) => out.extend_from_slice(if b { b"true" } else { b"false" }),
                            Value::List(_) => return Err(Error::new(ErrorKind::Interp, "list")),
                        },
                    }
                }
                Ok(Value::str(out))
            }
            Expr::Var(name) => {
                lookup_var(scope, name).ok_or_else(|| Error::new(ErrorKind::UnknownVar, name.as_bytes()))
            }
            Expr::List(items) => {
                let mut v = Vec::with_capacity(items.len());
                for i in items {
                    v.push(self.eval(i, scope)?);
                }
                Ok(Value::list(v))
            }
            Expr::Unary(op, x) => {
                let v = self.eval(x, scope)?;
                match (op, v) {
                    (UnOp::Not, Value::Bool(b)) => Ok(Value::Bool(!b)),
                    (UnOp::Neg, Value::Int(n)) => Ok(Value::Int(n.wrapping_neg())),
                    (UnOp::Not, other) => Err(Error::type_error("operator !", "bool", other.type_name())),
                    (UnOp::Neg, other) => Err(Error::type_error("operator -", "int", other.type_name())),
                }
            }
            Expr::Binary(op, a, b) => self.eval_binary(*op, a, b, scope),
            Expr::Call(name, args) => {
                let spec = builtins::lookup(name).ok_or_else(|| Error::new(ErrorKind::UnknownFunc, name.as_bytes()))?;
                let mut vals = Vec::with_capacity(args.len());
                for a in args {
                    vals.push(self.eval(a, scope)?);
                }
                builtins::check_args(spec, &vals)?;
                builtins::call(spec.name, &vals, self.ws)
            }
            Expr::Index(x, i) => {
                let target = self.eval(x, scope)?;
                let idx = self.eval(i, scope)?;
                let Value::Int(n) = idx else {
                    return Err(Error::type_error("index", "int", idx.type_name()));
                };
                let len = match &target {
                    Value::Str(s) => s.len(),
                    Value::List(l) => l.len(),
                    other => return Err(Error::type_error("index target", "str|list", other.type_name())),
                };
                let pos = if n < 0 { n.checked_add(len as i64) } else { Some(n) };
                let pos = match pos {
                    Some(p) if p >= 0 && (p as u64) < len as u64 => p as usize,
                    _ => return Err(Error::arg("fn", "index", "out of range")),
                };
                Ok(match &target {
                    Value::Str(s) => Value::str(vec![s[pos]]),
                    Value::List(l) => l[pos].clone(),
                    _ => unreachable!("checked above"),
                })
            }
        }
    }

    fn eval_binary(&self, op: BinOp, a: &Expr, b: &Expr, scope: &ScopeRef) -> Result<Value> {
        let sym = op.symbol();
        if matches!(op, BinOp::Or | BinOp::And) {
            let l = self.eval(a, scope)?;
            let Value::Bool(lb) = l else {
                return Err(Error::type_error(&format!("operator {sym}"), "bool", l.type_name()));
            };
            if (op == BinOp::Or && lb) || (op == BinOp::And && !lb) {
                return Ok(Value::Bool(lb));
            }
            let r = self.eval(b, scope)?;
            return match r {
                Value::Bool(rb) => Ok(Value::Bool(rb)),
                other => Err(Error::type_error(&format!("operator {sym}"), "bool", other.type_name())),
            };
        }
        let l = self.eval(a, scope)?;
        let r = self.eval(b, scope)?;
        let site = format!("operator {sym}");
        match op {
            BinOp::Eq => Ok(Value::Bool(l == r)),
            BinOp::Ne => Ok(Value::Bool(l != r)),
            BinOp::Lt => Ok(Value::Bool(l.cmp(&r) == Ordering::Less)),
            BinOp::Le => Ok(Value::Bool(l.cmp(&r) != Ordering::Greater)),
            BinOp::Gt => Ok(Value::Bool(l.cmp(&r) == Ordering::Greater)),
            BinOp::Ge => Ok(Value::Bool(l.cmp(&r) != Ordering::Less)),
            BinOp::Concat => match (&l, &r) {
                (Value::List(x), Value::List(y)) => {
                    let mut v = Vec::with_capacity(x.len() + y.len());
                    v.extend(x.iter().cloned());
                    v.extend(y.iter().cloned());
                    Ok(Value::list(v))
                }
                (Value::List(_), other) | (other, _) => Err(Error::type_error(&site, "list", other.type_name())),
            },
            BinOp::StrCat => match (&l, &r) {
                (Value::Str(x), Value::Str(y)) => {
                    let mut v = Vec::with_capacity(x.len() + y.len());
                    v.extend_from_slice(x);
                    v.extend_from_slice(y);
                    Ok(Value::str(v))
                }
                (Value::Str(_), other) | (other, _) => Err(Error::type_error(&site, "str", other.type_name())),
            },
            _ => {
                let (Value::Int(x), Value::Int(y)) = (&l, &r) else {
                    let bad = if matches!(l, Value::Int(_)) { &r } else { &l };
                    return Err(Error::type_error(&site, "int", bad.type_name()));
                };
                let (x, y) = (*x, *y);
                Ok(Value::Int(match op {
                    BinOp::Add => x.wrapping_add(y),
                    BinOp::Sub => x.wrapping_sub(y),
                    BinOp::Mul => x.wrapping_mul(y),
                    BinOp::Div | BinOp::Rem => {
                        if y == 0 {
                            return Err(Error::bare(ErrorKind::DivZero));
                        }
                        if op == BinOp::Div {
                            x.wrapping_div(y)
                        } else {
                            x.wrapping_rem(y)
                        }
                    }
                    _ => unreachable!("handled above"),
                }))
            }
        }
    }

    /// A `str` or list-of-`str` value, as the `strlist` sites require.
    fn strlist(&self, v: Value, site: &str) -> Result<Vec<Vec<u8>>> {
        match v {
            Value::Str(s) => Ok(vec![s.as_ref().clone()]),
            Value::List(l) => {
                let mut out = Vec::with_capacity(l.len());
                for x in l.iter() {
                    match x {
                        Value::Str(s) => out.push(s.as_ref().clone()),
                        other => return Err(Error::type_error(site, "strlist", other.type_name())),
                    }
                }
                Ok(out)
            }
            other => Err(Error::type_error(site, "strlist", other.type_name())),
        }
    }

    // ---- statements ------------------------------------------------------

    fn exec_block(&mut self, stmts: &[Stmt], scope: &ScopeRef) -> Result<()> {
        for s in stmts {
            self.exec(s, scope)?;
        }
        Ok(())
    }

    fn exec(&mut self, stmt: &Stmt, scope: &ScopeRef) -> Result<()> {
        match stmt {
            Stmt::Let(name, e) => {
                let v = self.eval(e, scope)?;
                let mut s = scope.borrow_mut();
                if s.vars.contains_key(name) {
                    return Err(Error::new(ErrorKind::Redefine, name.as_bytes()));
                }
                s.vars.insert(name.clone(), v);
                Ok(())
            }
            Stmt::Set(name, e) => {
                let v = self.eval(e, scope)?;
                let mut cur = Some(scope.clone());
                while let Some(s) = cur {
                    if let Some(slot) = s.borrow_mut().vars.get_mut(name) {
                        *slot = v;
                        return Ok(());
                    }
                    cur = s.borrow().parent.clone();
                }
                Err(Error::new(ErrorKind::SetUndefined, name.as_bytes()))
            }
            Stmt::Include(e) => self.exec_include(e, scope),
            Stmt::Abort(e) => match self.eval(e, scope)? {
                Value::Str(s) => Err(Error::new(ErrorKind::Abort, s.as_ref().clone())),
                other => Err(Error::type_error("abort message", "str", other.type_name())),
            },
            Stmt::Default(e) => {
                let v = self.eval(e, scope)?;
                let names = self.strlist(v, "default")?;
                self.config.defaults.extend(names);
                Ok(())
            }
            Stmt::Phony(name, e) => {
                let v = self.eval(e, scope)?;
                let deps = self.strlist(v, &format!("phony {name}"))?;
                for d in &deps {
                    check_reference(d)?;
                }
                if self.phony_index.contains_key(name) {
                    return Err(Error::new(ErrorKind::DupPhony, name.as_bytes()));
                }
                self.phony_index.insert(name.clone(), self.config.phonies.len());
                self.config.phonies.push(Phony { name: name.clone(), deps });
                Ok(())
            }
            Stmt::Use { name, args } => self.exec_use(name, args, scope),
            Stmt::When { branches, otherwise } => {
                for (cond, body) in branches {
                    match self.eval(cond, scope)? {
                        Value::Bool(true) => {
                            let child = new_scope(Some(scope.clone()));
                            return self.exec_block(body, &child);
                        }
                        Value::Bool(false) => {}
                        other => return Err(Error::type_error("when condition", "bool", other.type_name())),
                    }
                }
                if let Some(body) = otherwise {
                    let child = new_scope(Some(scope.clone()));
                    self.exec_block(body, &child)?;
                }
                Ok(())
            }
            Stmt::Each { index, name, subject, body } => {
                let items = match self.eval(subject, scope)? {
                    Value::List(items) => items,
                    other => return Err(Error::type_error("each subject", "list", other.type_name())),
                };
                for (i, item) in items.iter().enumerate() {
                    let child = new_scope(Some(scope.clone()));
                    {
                        let mut c = child.borrow_mut();
                        if let Some(ix) = index {
                            c.vars.insert(ix.clone(), Value::Int(i as i64));
                        }
                        c.vars.insert(name.clone(), item.clone());
                    }
                    self.exec_block(body, &child)?;
                }
                Ok(())
            }
            Stmt::Rule { name, params, body } => {
                if self.rules.contains_key(name) {
                    return Err(Error::new(ErrorKind::Redefine, name.as_bytes()));
                }
                let rule = Rule { params: params.clone(), body: body.clone(), scope: scope.clone() };
                self.rules.insert(name.clone(), Rc::new(rule));
                Ok(())
            }
            Stmt::Step(fields) => self.exec_step(fields, scope),
        }
    }

    fn exec_include(&mut self, e: &Expr, scope: &ScopeRef) -> Result<()> {
        let path = match self.eval(e, scope)? {
            Value::Str(s) => s,
            other => return Err(Error::type_error("include path", "str", other.type_name())),
        };
        if !is_workspace_path(&path) {
            return Err(Error::new(ErrorKind::BadPath, path.as_ref().clone()));
        }
        if !self.ws.contains(&path) {
            return Err(Error::new(ErrorKind::IncludeMissing, path.as_ref().clone()));
        }
        if self.include_stack.iter().any(|p| p.as_slice() == path.as_slice()) {
            return Err(Error::new(ErrorKind::IncludeCycle, path.as_ref().clone()));
        }
        let stmts = self.parse(&path)?;
        self.include_stack.push(path.as_ref().clone());
        let r = self.exec_block(&stmts, scope);
        self.include_stack.pop();
        r
    }

    fn exec_use(&mut self, name: &str, args: &[Arg], scope: &ScopeRef) -> Result<()> {
        let rule = self
            .rules
            .get(name)
            .cloned()
            .ok_or_else(|| Error::new(ErrorKind::UnknownRule, name.as_bytes()))?;
        if self.depth + 1 > MAX_RULE_DEPTH {
            return Err(Error::new(ErrorKind::RuleRecursion, name.as_bytes()));
        }
        let mut positional: Vec<Value> = Vec::new();
        let mut keywords: Vec<(&str, Value)> = Vec::new();
        for a in args {
            match a {
                Arg::Positional(e) => positional.push(self.eval(e, scope)?),
                Arg::Keyword(k, e) => keywords.push((k.as_str(), self.eval(e, scope)?)),
            }
        }
        let inst = new_scope(Some(rule.scope.clone()));
        if positional.len() > rule.params.len() {
            return Err(Error::new(
                ErrorKind::Arity,
                format!("rule {name}: expected {}, got {}", rule.params.len(), positional.len()),
            ));
        }
        let mut bound: Vec<Option<Value>> = vec![None; rule.params.len()];
        for (i, v) in positional.into_iter().enumerate() {
            bound[i] = Some(v);
        }
        for (k, v) in keywords {
            let Some(i) = rule.params.iter().position(|p| p.name == k) else {
                return Err(Error::arg("rule", name, &format!("unknown argument {k}")));
            };
            if bound[i].is_some() {
                return Err(Error::arg("rule", name, &format!("duplicate argument {k}")));
            }
            bound[i] = Some(v);
        }
        for (i, p) in rule.params.iter().enumerate() {
            let v = match bound[i].take() {
                Some(v) => v,
                None => match &p.default {
                    Some(d) => self.eval(d, &inst)?,
                    None => return Err(Error::arg("rule", name, &format!("missing argument {}", p.name))),
                },
            };
            inst.borrow_mut().vars.insert(p.name.clone(), v);
        }
        self.depth += 1;
        let r = self.exec_block(&rule.body, &inst);
        self.depth -= 1;
        r
    }

    fn exec_step(&mut self, fields: &[Field], scope: &ScopeRef) -> Result<()> {
        let mut b = StepBuilder::default();
        for f in fields {
            match f {
                Field::Out(e) => {
                    let v = self.eval(e, scope)?;
                    b.outputs.extend(self.strlist(v, "field out")?);
                }
                Field::In(e) => {
                    let v = self.eval(e, scope)?;
                    b.inputs.extend(self.strlist(v, "field in")?);
                }
                Field::After(e) => {
                    let v = self.eval(e, scope)?;
                    b.after.extend(self.strlist(v, "field after")?);
                }
                Field::Cost(e) => {
                    if b.cost.is_some() {
                        return Err(Error::new(ErrorKind::StepField, "duplicate cost"));
                    }
                    match self.eval(e, scope)? {
                        Value::Int(n) if n >= 0 => b.cost = Some(n),
                        Value::Int(_) => return Err(Error::arg("field", "cost", "negative")),
                        other => return Err(Error::type_error("field cost", "int", other.type_name())),
                    }
                }
                Field::Depfile(e) => {
                    if b.depfile.is_some() {
                        return Err(Error::new(ErrorKind::StepField, "duplicate depfile"));
                    }
                    match self.eval(e, scope)? {
                        Value::Str(s) => b.depfile = Some(s.as_ref().clone()),
                        other => return Err(Error::type_error("field depfile", "str", other.type_name())),
                    }
                }
                Field::Cmd { name, args } => {
                    if b.command.is_some() {
                        return Err(Error::new(ErrorKind::StepField, "duplicate cmd"));
                    }
                    let spec = command::lookup(name)
                        .ok_or_else(|| Error::new(ErrorKind::UnknownCmd, name.as_bytes()))?;
                    let mut vals = Vec::with_capacity(args.len());
                    for a in args {
                        vals.push(self.eval(a, scope)?);
                    }
                    b.command = Some(Command::new(spec, vals)?);
                }
            }
        }
        let step = b.finish(self.config.steps.len())?;
        self.config.steps.push(step);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ws_with(files: &[(&str, &str)]) -> Workspace {
        let mut ws = Workspace::new();
        for (p, c) in files {
            ws.write(p.as_bytes(), c.as_bytes().to_vec());
        }
        ws
    }

    fn eval_err(main: &str) -> String {
        let ws = ws_with(&[("main.kiln", main)]);
        match evaluate(&ws) {
            Ok(_) => "ok".to_string(),
            Err(e) => e.to_string(),
        }
    }

    #[test]
    fn expression_errors() {
        assert_eq!(eval_err("let x = \"a\" + [1]\n"), "E_TYPE operator +: expected int, got str");
        assert_eq!(eval_err("let x = 5[\"a\"]\n"), "E_TYPE index: expected int, got str");
        assert_eq!(eval_err("let x = 5[0]\n"), "E_TYPE index target: expected str|list, got int");
        assert_eq!(eval_err("let x = [1][3]\n"), "E_ARG fn index: out of range");
        assert_eq!(eval_err("let x = [1][-2]\n"), "E_ARG fn index: out of range");
        assert_eq!(eval_err("let x = 1 / 0\n"), "E_DIV_ZERO");
        assert_eq!(eval_err("let x = true || (1 / 0)\n"), "ok");
        assert_eq!(eval_err("let x = false && (1 / 0)\n"), "ok");
        assert_eq!(eval_err("let x = 1 || true\n"), "E_TYPE operator ||: expected bool, got int");
        assert_eq!(eval_err("let x = \"{[1]}\"\n"), "E_INTERP list");
        assert_eq!(eval_err("let x = nope(undefined)\n"), "E_UNKNOWN_FUNC nope");
        assert_eq!(eval_err("let x = upper(undefined, 2)\n"), "E_UNKNOWN_VAR undefined");
        assert_eq!(eval_err("let x = 1 |> cost\n"), "E_UNKNOWN_FUNC cost");
    }

    #[test]
    fn scoping() {
        assert_eq!(eval_err("let x = 1\nlet x = 2\n"), "E_REDEFINE x");
        assert_eq!(eval_err("let x = 1\nwhen true {\nlet x = 2\n}\n"), "ok");
        assert_eq!(eval_err("set y = 1\n"), "E_SET_UNDEFINED y");
        assert_eq!(eval_err("let x = 1\neach i in [1] {\nset x = x + i\n}\nabort str(x)\n"), "E_ABORT 2");
        assert_eq!(eval_err("each x in [1] {\nlet x = 2\n}\n"), "E_REDEFINE x");
    }

    #[test]
    fn rules() {
        let pre = "rule r(a, b = a ~ \"!\") {\nabort b\n}\n";
        assert_eq!(eval_err(&format!("{pre}use r(\"x\")\n")), "E_ABORT x!");
        assert_eq!(eval_err(&format!("{pre}use r(1, 2, 3)\n")), "E_ARITY rule r: expected 2, got 3");
        assert_eq!(eval_err(&format!("{pre}use r(c = 1)\n")), "E_ARG rule r: unknown argument c");
        assert_eq!(eval_err(&format!("{pre}use r(1, a = 1)\n")), "E_ARG rule r: duplicate argument a");
        assert_eq!(eval_err(&format!("{pre}use r()\n")), "E_ARG rule r: missing argument a");
        assert_eq!(eval_err("use nope(undefined)\n"), "E_UNKNOWN_RULE nope");
        assert_eq!(eval_err("rule r() {\n}\nrule r() {\n}\n"), "E_REDEFINE r");
        assert_eq!(eval_err("rule r() {\nuse r()\n}\nuse r()\n"), "E_RULE_RECURSION r");
    }

    #[test]
    fn rule_scope_is_definition_scope() {
        let src = "let n = 1\nrule r() {\nabort str(n)\n}\nwhen true {\nlet n = 2\nuse r()\n}\n";
        assert_eq!(eval_err(src), "E_ABORT 1");
    }

    #[test]
    fn include() {
        let ws = ws_with(&[("main.kiln", "include \"a.kiln\"\nabort str(v)\n"), ("a.kiln", "let v = 7\n")]);
        assert_eq!(evaluate(&ws).unwrap_err().to_string(), "E_ABORT 7");
        let ws = ws_with(&[("main.kiln", "include \"a.kiln\"\n"), ("a.kiln", "include \"main.kiln\"\n")]);
        assert_eq!(evaluate(&ws).unwrap_err().to_string(), "E_INCLUDE_CYCLE main.kiln");
        let ws = ws_with(&[("main.kiln", "include \"nope.kiln\"\n")]);
        assert_eq!(evaluate(&ws).unwrap_err().to_string(), "E_INCLUDE_MISSING nope.kiln");
        let ws = ws_with(&[("main.kiln", "include \"a.kiln\"\ninclude \"a.kiln\"\n"), ("a.kiln", "let v = 7\n")]);
        assert_eq!(evaluate(&ws).unwrap_err().to_string(), "E_REDEFINE v");
        let ws = ws_with(&[("main.kiln", "let x = 1\ninclude \"a.kiln\"\n"), ("a.kiln", "let x = = 1\n")]);
        assert_eq!(evaluate(&ws).unwrap_err().to_string(), "E_PARSE a.kiln:1");
    }

    #[test]
    fn step_validation() {
        assert_eq!(eval_err("step {\nout \"out/a\"\n}\n"), "E_STEP_FIELD missing cmd");
        assert_eq!(eval_err("step {\ncmd write(\"x\")\n}\n"), "E_STEP_FIELD missing out");
        assert_eq!(eval_err("step {\nout \"a\"\ncmd write(\"x\")\n}\n"), "E_OUTPUT_PATH a");
        assert_eq!(eval_err("step {\nout \"a b\"\ncmd write(\"x\")\n}\n"), "E_BAD_PATH a b");
        assert_eq!(eval_err("step {\nout \"out/a\"\ncmd nope()\n}\n"), "E_UNKNOWN_CMD nope");
        assert_eq!(eval_err("step {\nout \"out/a\"\ncmd write()\n}\n"), "E_ARITY cmd write: expected 1, got 0");
        assert_eq!(
            eval_err("step {\nout \"out/a\"\ncmd write(1)\n}\n"),
            "E_TYPE cmd write argument 1: expected str, got int"
        );
        assert_eq!(eval_err("step {\nout \"out/a\"\ncmd copy()\n}\n"), "E_CMD_SHAPE copy: expected inputs 1-1, got 0");
        assert_eq!(
            eval_err("step {\nout \"out/a\"\nin \"x\"\ncmd concat()\ncost 1\ncost undefined\n}\n"),
            "E_STEP_FIELD duplicate cost"
        );
        assert_eq!(
            eval_err("step {\nout \"out/a\"\ncmd write(\"x\")\ndepfile \"out/d\"\n}\n"),
            "E_CMD_SHAPE write: depfile not allowed"
        );
        assert_eq!(
            eval_err("step {\nout \"out/a\"\nin \"x\"\ncmd preprocess()\n}\n"),
            "E_CMD_SHAPE preprocess: depfile required"
        );
        assert_eq!(eval_err("step {\nout \"out/a\"\ncmd write(\"x\")\ncost -1\n}\n"), "E_ARG field cost: negative");
        assert_eq!(eval_err("step {\nout [\"out/a\", 1]\ncmd write(\"x\")\n}\n"), "E_TYPE field out: expected strlist, got int");
    }

    #[test]
    fn phony() {
        assert_eq!(eval_err("phony a = []\nphony a = []\n"), "E_DUP_PHONY a");
        assert_eq!(eval_err("phony a = [\"@\"]\n"), "E_BAD_PATH @");
        assert_eq!(eval_err("phony a = 1\n"), "E_TYPE phony a: expected strlist, got int");
    }
}
