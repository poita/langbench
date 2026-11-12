//! The tree-walking interpreter: runs a build file (and everything it
//! `include`s) over a chain of lexical scopes and produces the step list,
//! the phony table and the default targets.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use crate::ast::*;
use crate::builtins::{self, int_text};
use crate::command::{CmdArg, CmdKind, Command};
use crate::error::{Error, ErrorKind, Result};
use crate::lexer::Op;
use crate::parser::parse_file;
use crate::step::{check_reference, Phony, Step, StepDraft};
use crate::value::Value;
use crate::workspace::{is_workspace_path, Workspace};

/// The maximum rule instantiation depth.
const MAX_RULE_DEPTH: usize = 64;

/// The result of evaluating a build.
#[derive(Debug, Default)]
pub struct Evaluation {
    /// All steps, indexed by serial number.
    pub steps: Vec<Step>,
    /// All phony targets in declaration order.
    pub phonies: Vec<Phony>,
    /// The accumulated `default` targets (duplicates kept).
    pub defaults: Vec<Vec<u8>>,
}

/// Evaluates the build file at `main` (and its includes) against `ws`.
pub fn evaluate(ws: &Workspace, main: &str) -> Result<Evaluation> {
    let mut it = Interp {
        ws,
        steps: Vec::new(),
        phonies: Vec::new(),
        phony_names: HashMap::new(),
        rules: HashMap::new(),
        defaults: Vec::new(),
        include_stack: Vec::new(),
        depth: 0,
    };
    let root = Scope::new(None);
    it.run_file(main, &root)?;
    Ok(Evaluation {
        steps: it.steps,
        phonies: it.phonies,
        defaults: it.defaults,
    })
}

struct Scope {
    vars: HashMap<String, Value>,
    parent: Option<ScopeRef>,
}

type ScopeRef = Rc<RefCell<Scope>>;

impl Scope {
    fn new(parent: Option<ScopeRef>) -> ScopeRef {
        Rc::new(RefCell::new(Scope {
            vars: HashMap::new(),
            parent,
        }))
    }
}

fn lookup(scope: &ScopeRef, name: &str) -> Option<Value> {
    let mut cur = scope.clone();
    loop {
        let next = {
            let s = cur.borrow();
            if let Some(v) = s.vars.get(name) {
                return Some(v.clone());
            }
            s.parent.clone()
        };
        cur = next?;
    }
}

struct RuleInst {
    def: Rc<RuleDef>,
    scope: ScopeRef,
}

struct Interp<'a> {
    ws: &'a Workspace,
    steps: Vec<Step>,
    phonies: Vec<Phony>,
    phony_names: HashMap<String, usize>,
    rules: HashMap<String, Rc<RuleInst>>,
    defaults: Vec<Vec<u8>>,
    include_stack: Vec<String>,
    depth: usize,
}

/// Interprets a `str`, or a `list` of `str`, as a list of strings.
fn strlist(v: &Value, site: &str) -> Result<Vec<Vec<u8>>> {
    match v {
        Value::Str(s) => Ok(vec![s.to_vec()]),
        Value::List(l) => l
            .iter()
            .map(|e| match e {
                Value::Str(s) => Ok(s.to_vec()),
                other => Err(Error::type_mismatch(site, "strlist", other.type_name())),
            })
            .collect(),
        other => Err(Error::type_mismatch(site, "strlist", other.type_name())),
    }
}

fn expect_str(v: &Value, site: &str) -> Result<Vec<u8>> {
    match v {
        Value::Str(s) => Ok(s.to_vec()),
        other => Err(Error::type_mismatch(site, "str", other.type_name())),
    }
}

impl<'a> Interp<'a> {
    fn run_file(&mut self, path: &str, scope: &ScopeRef) -> Result<()> {
        let src = self
            .ws
            .read_shared(path)
            .ok_or_else(|| Error::new(ErrorKind::IncludeMissing, path))?;
        let stmts = parse_file(&src, path)?;
        self.include_stack.push(path.to_string());
        self.exec_block(&stmts, scope)?;
        self.include_stack.pop();
        Ok(())
    }

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
                    return Err(Error::new(ErrorKind::Redefine, name.as_str()));
                }
                s.vars.insert(name.clone(), v);
            }
            Stmt::Set(name, e) => {
                let v = self.eval(e, scope)?;
                let mut cur = scope.clone();
                loop {
                    if cur.borrow().vars.contains_key(name) {
                        cur.borrow_mut().vars.insert(name.clone(), v);
                        break;
                    }
                    let next = cur.borrow().parent.clone();
                    match next {
                        Some(p) => cur = p,
                        None => {
                            return Err(Error::new(ErrorKind::SetUndefined, name.as_str()))
                        }
                    }
                }
            }
            Stmt::Include(e) => {
                let v = self.eval(e, scope)?;
                let p = expect_str(&v, "include path")?;
                if !is_workspace_path(&p) {
                    return Err(Error::new(ErrorKind::BadPath, p));
                }
                let path = String::from_utf8_lossy(&p).into_owned();
                if !self.ws.contains(&path) {
                    return Err(Error::new(ErrorKind::IncludeMissing, path));
                }
                if self.include_stack.contains(&path) {
                    return Err(Error::new(ErrorKind::IncludeCycle, path));
                }
                self.run_file(&path, scope)?;
            }
            Stmt::Abort(e) => {
                let v = self.eval(e, scope)?;
                let m = expect_str(&v, "abort message")?;
                return Err(Error::new(ErrorKind::Abort, m));
            }
            Stmt::Default(e) => {
                let v = self.eval(e, scope)?;
                let l = strlist(&v, "default")?;
                self.defaults.extend(l);
            }
            Stmt::Phony(name, e) => {
                let v = self.eval(e, scope)?;
                let deps = strlist(&v, &format!("phony {name}"))?;
                let deps = deps
                    .iter()
                    .map(|d| check_reference(d))
                    .collect::<Result<Vec<_>>>()?;
                if self.phony_names.contains_key(name) {
                    return Err(Error::new(ErrorKind::DupPhony, name.as_str()));
                }
                self.phony_names.insert(name.clone(), self.phonies.len());
                self.phonies.push(Phony {
                    name: name.clone(),
                    deps,
                });
            }
            Stmt::When {
                branches,
                otherwise,
            } => {
                for (cond, body) in branches {
                    match self.eval(cond, scope)? {
                        Value::Bool(true) => {
                            let child = Scope::new(Some(scope.clone()));
                            return self.exec_block(body, &child);
                        }
                        Value::Bool(false) => {}
                        other => {
                            return Err(Error::type_mismatch(
                                "when condition",
                                "bool",
                                other.type_name(),
                            ))
                        }
                    }
                }
                if let Some(body) = otherwise {
                    let child = Scope::new(Some(scope.clone()));
                    self.exec_block(body, &child)?;
                }
            }
            Stmt::Each {
                index,
                name,
                subject,
                body,
            } => {
                let v = self.eval(subject, scope)?;
                let Value::List(list) = v else {
                    return Err(Error::type_mismatch(
                        "each subject",
                        "list",
                        v.type_name(),
                    ));
                };
                for (i, el) in list.iter().enumerate() {
                    let child = Scope::new(Some(scope.clone()));
                    {
                        let mut c = child.borrow_mut();
                        c.vars.insert(name.clone(), el.clone());
                        if let Some(ix) = index {
                            c.vars.insert(ix.clone(), Value::Int(i as i64));
                        }
                    }
                    self.exec_block(body, &child)?;
                }
            }
            Stmt::Rule(def) => {
                if self.rules.contains_key(&def.name) {
                    return Err(Error::new(ErrorKind::Redefine, def.name.as_str()));
                }
                self.rules.insert(
                    def.name.clone(),
                    Rc::new(RuleInst {
                        def: def.clone(),
                        scope: scope.clone(),
                    }),
                );
            }
            Stmt::Use { rule, args } => self.instantiate(rule, args, scope)?,
            Stmt::Step(fields) => self.exec_step(fields, scope)?,
        }
        Ok(())
    }

    fn instantiate(&mut self, rule: &str, args: &[Arg], scope: &ScopeRef) -> Result<()> {
        let inst = self
            .rules
            .get(rule)
            .cloned()
            .ok_or_else(|| Error::new(ErrorKind::UnknownRule, rule))?;
        if self.depth + 1 > MAX_RULE_DEPTH {
            return Err(Error::new(ErrorKind::RuleRecursion, rule));
        }
        let mut positional = Vec::new();
        let mut keywords = Vec::new();
        for a in args {
            match a {
                Arg::Pos(e) => positional.push(self.eval(e, scope)?),
                Arg::Kw(n, e) => keywords.push((n, self.eval(e, scope)?)),
            }
        }
        let params = &inst.def.params;
        let child = Scope::new(Some(inst.scope.clone()));
        if positional.len() > params.len() {
            return Err(Error::arity(
                "rule",
                rule,
                &params.len().to_string(),
                positional.len(),
            ));
        }
        let mut bound = vec![false; params.len()];
        for (i, v) in positional.into_iter().enumerate() {
            child.borrow_mut().vars.insert(params[i].name.clone(), v);
            bound[i] = true;
        }
        for (kw, v) in keywords {
            let Some(i) = params.iter().position(|p| p.name == *kw) else {
                return Err(Error::arg("rule", rule, &format!("unknown argument {kw}")));
            };
            if bound[i] {
                return Err(Error::arg("rule", rule, &format!("duplicate argument {kw}")));
            }
            child.borrow_mut().vars.insert(kw.clone(), v);
            bound[i] = true;
        }
        for (i, p) in params.iter().enumerate() {
            if bound[i] {
                continue;
            }
            match &p.default {
                Some(d) => {
                    let v = self.eval(d, &child)?;
                    child.borrow_mut().vars.insert(p.name.clone(), v);
                }
                None => {
                    return Err(Error::arg(
                        "rule",
                        rule,
                        &format!("missing argument {}", p.name),
                    ))
                }
            }
        }
        self.depth += 1;
        self.exec_block(&inst.def.body, &child)?;
        self.depth -= 1;
        Ok(())
    }

    fn exec_step(&mut self, fields: &[StepField], scope: &ScopeRef) -> Result<()> {
        let mut d = StepDraft::default();
        let dup = |what: &str| Error::new(ErrorKind::StepField, format!("duplicate {what}"));
        for f in fields {
            match f {
                StepField::Out(e) => {
                    let v = self.eval(e, scope)?;
                    d.outs.extend(strlist(&v, "field out")?);
                }
                StepField::In(e) => {
                    let v = self.eval(e, scope)?;
                    d.ins.extend(strlist(&v, "field in")?);
                }
                StepField::After(e) => {
                    let v = self.eval(e, scope)?;
                    d.after.extend(strlist(&v, "field after")?);
                }
                StepField::Cost(e) => {
                    if d.cost.is_some() {
                        return Err(dup("cost"));
                    }
                    match self.eval(e, scope)? {
                        Value::Int(n) if n >= 0 => d.cost = Some(n as u64),
                        Value::Int(_) => {
                            return Err(Error::arg("field", "cost", "negative"));
                        }
                        other => {
                            return Err(Error::type_mismatch(
                                "field cost",
                                "int",
                                other.type_name(),
                            ))
                        }
                    }
                }
                StepField::Depfile(e) => {
                    if d.depfile.is_some() {
                        return Err(dup("depfile"));
                    }
                    let v = self.eval(e, scope)?;
                    d.depfile = Some(expect_str(&v, "field depfile")?);
                }
                StepField::Cmd { name, args } => {
                    if d.command.is_some() {
                        return Err(dup("cmd"));
                    }
                    let kind = CmdKind::from_name(name)
                        .ok_or_else(|| Error::new(ErrorKind::UnknownCmd, name.as_str()))?;
                    let vals = args
                        .iter()
                        .map(|a| self.eval(a, scope))
                        .collect::<Result<Vec<_>>>()?;
                    let tys = kind.arg_types();
                    if vals.len() != tys.len() {
                        return Err(Error::arity(
                            "cmd",
                            name,
                            &tys.len().to_string(),
                            vals.len(),
                        ));
                    }
                    let mut cargs = Vec::new();
                    for (i, (v, ty)) in vals.iter().zip(tys).enumerate() {
                        let site = format!("cmd {name} argument {}", i + 1);
                        match (v, ty) {
                            (Value::Str(s), crate::command::ArgTy::Str) => {
                                cargs.push(CmdArg::Str(s.to_vec()))
                            }
                            (Value::Int(n), crate::command::ArgTy::Int) => {
                                cargs.push(CmdArg::Int(*n))
                            }
                            _ => {
                                return Err(Error::type_mismatch(
                                    &site,
                                    ty.token(),
                                    v.type_name(),
                                ))
                            }
                        }
                    }
                    d.command = Some(Command { kind, args: cargs });
                }
            }
        }
        let step = d.finish(self.steps.len())?;
        self.steps.push(step);
        Ok(())
    }

    // ---- expressions -------------------------------------------------

    fn eval(&mut self, e: &Expr, scope: &ScopeRef) -> Result<Value> {
        match e {
            Expr::Int(i) => Ok(Value::Int(*i)),
            Expr::Bool(b) => Ok(Value::Bool(*b)),
            Expr::Str(s) => Ok(Value::Str(s.clone())),
            Expr::Interp(parts) => {
                let mut out = Vec::new();
                for p in parts {
                    match p {
                        Part::Lit(l) => out.extend_from_slice(l),
                        Part::Expr(e) => match self.eval(e, scope)? {
                            Value::Str(s) => out.extend_from_slice(&s),
                            Value::Int(i) => out.extend_from_slice(&int_text(i)),
                            Value::Bool(b) => {
                                out.extend_from_slice(if b { b"true" } else { b"false" })
                            }
                            Value::List(_) => {
                                return Err(Error::new(ErrorKind::Interp, "list"))
                            }
                        },
                    }
                }
                Ok(Value::str(out))
            }
            Expr::Var(name) => lookup(scope, name)
                .ok_or_else(|| Error::new(ErrorKind::UnknownVar, name.as_str())),
            Expr::List(items) => {
                let mut out = Vec::with_capacity(items.len());
                for i in items {
                    out.push(self.eval(i, scope)?);
                }
                Ok(Value::list(out))
            }
            Expr::Unary(op, inner) => {
                let v = self.eval(inner, scope)?;
                match (op, &v) {
                    (Op::Not, Value::Bool(b)) => Ok(Value::Bool(!b)),
                    (Op::Minus, Value::Int(i)) => Ok(Value::Int(i.wrapping_neg())),
                    _ => Err(Error::type_mismatch(
                        &format!("operator {}", op.spelling()),
                        if *op == Op::Not { "bool" } else { "int" },
                        v.type_name(),
                    )),
                }
            }
            Expr::Binary(op, a, b) => self.eval_binary(*op, a, b, scope),
            Expr::Call(name, args) => {
                let Some(f) = builtins::lookup(name) else {
                    return Err(Error::new(ErrorKind::UnknownFunc, name.as_str()));
                };
                let mut vals = Vec::with_capacity(args.len());
                for a in args {
                    vals.push(self.eval(a, scope)?);
                }
                builtins::call(f, &vals, self.ws)
            }
            Expr::Index(target, idx) => {
                let t = self.eval(target, scope)?;
                let i = self.eval(idx, scope)?;
                let Value::Int(i) = i else {
                    return Err(Error::type_mismatch("index", "int", i.type_name()));
                };
                let len = match &t {
                    Value::Str(s) => s.len(),
                    Value::List(l) => l.len(),
                    other => {
                        return Err(Error::type_mismatch(
                            "index target",
                            "str|list",
                            other.type_name(),
                        ))
                    }
                } as i64;
                if i < -len || i >= len {
                    return Err(Error::arg("fn", "index", "out of range"));
                }
                let k = if i < 0 { i + len } else { i } as usize;
                Ok(match &t {
                    Value::Str(s) => Value::str(vec![s[k]]),
                    other => other.as_list()[k].clone(),
                })
            }
        }
    }

    fn eval_binary(&mut self, op: Op, a: &Expr, b: &Expr, scope: &ScopeRef) -> Result<Value> {
        let site = || format!("operator {}", op.spelling());
        if op == Op::Or || op == Op::And {
            let l = self.eval(a, scope)?;
            let Value::Bool(lb) = l else {
                return Err(Error::type_mismatch(&site(), "bool", l.type_name()));
            };
            if (op == Op::Or && lb) || (op == Op::And && !lb) {
                return Ok(Value::Bool(lb));
            }
            let r = self.eval(b, scope)?;
            let Value::Bool(rb) = r else {
                return Err(Error::type_mismatch(&site(), "bool", r.type_name()));
            };
            return Ok(Value::Bool(rb));
        }
        let l = self.eval(a, scope)?;
        let r = self.eval(b, scope)?;
        match op {
            Op::Eq => return Ok(Value::Bool(l == r)),
            Op::Ne => return Ok(Value::Bool(l != r)),
            Op::Lt => return Ok(Value::Bool(l < r)),
            Op::Le => return Ok(Value::Bool(l <= r)),
            Op::Gt => return Ok(Value::Bool(l > r)),
            Op::Ge => return Ok(Value::Bool(l >= r)),
            _ => {}
        }
        let expected = match op {
            Op::Concat => "list",
            Op::Tilde => "str",
            _ => "int",
        };
        for v in [&l, &r] {
            if v.type_name() != expected {
                return Err(Error::type_mismatch(&site(), expected, v.type_name()));
            }
        }
        match (op, &l, &r) {
            (Op::Concat, Value::List(x), Value::List(y)) => {
                let mut out = Vec::with_capacity(x.len() + y.len());
                out.extend(x.iter().cloned());
                out.extend(y.iter().cloned());
                Ok(Value::list(out))
            }
            (Op::Tilde, Value::Str(x), Value::Str(y)) => {
                let mut out = Vec::with_capacity(x.len() + y.len());
                out.extend_from_slice(x);
                out.extend_from_slice(y);
                Ok(Value::str(out))
            }
            (_, Value::Int(x), Value::Int(y)) => match op {
                Op::Plus => Ok(Value::Int(x.wrapping_add(*y))),
                Op::Minus => Ok(Value::Int(x.wrapping_sub(*y))),
                Op::Star => Ok(Value::Int(x.wrapping_mul(*y))),
                Op::Slash | Op::Percent => {
                    if *y == 0 {
                        return Err(Error::bare(ErrorKind::DivZero));
                    }
                    Ok(Value::Int(if op == Op::Slash {
                        x.wrapping_div(*y)
                    } else {
                        x.wrapping_rem(*y)
                    }))
                }
                _ => unreachable!("non-arithmetic operator"),
            },
            _ => unreachable!("operand types were checked"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Evaluates `src` as main.kiln and returns the rendered error, or the
    /// message of the `abort` it ends with.
    fn outcome(files: &[(&str, &str)], src: &str) -> String {
        let mut ws = Workspace::new();
        ws.write("main.kiln", src.as_bytes().to_vec());
        for (p, c) in files {
            ws.write(p, c.as_bytes().to_vec());
        }
        match evaluate(&ws, "main.kiln") {
            Ok(e) => format!("ok steps={} phonies={}", e.steps.len(), e.phonies.len()),
            Err(e) => e.to_string(),
        }
    }

    fn val(expr: &str) -> String {
        match outcome(&[], &format!("abort \"{{{expr}}}\"\n")) {
            m if m.starts_with("E_ABORT ") => m["E_ABORT ".len()..].to_string(),
            m => m,
        }
    }

    #[test]
    fn arithmetic_and_precedence() {
        assert_eq!(val("1 + 2 * 3"), "7");
        assert_eq!(val("(1 + 2) * 3"), "9");
        assert_eq!(val("-7 / 2"), "-3");
        assert_eq!(val("-7 % 3"), "-1");
        assert_eq!(val("7 % -3"), "1");
        assert_eq!(val("1 - 2 - 3"), "-4");
        assert_eq!(val("1 / 0"), "E_DIV_ZERO");
        assert_eq!(val("1 % 0"), "E_DIV_ZERO");
        assert_eq!(val("9223372036854775807 + 1"), "-9223372036854775808");
    }

    #[test]
    fn operator_levels() {
        assert_eq!(val("\"a\" ~ \"b\" == \"ab\""), "true");
        assert_eq!(val("len([1] ++ [2]) == 2 && true"), "true");
        assert_eq!(val("1 < 2 == true"), "true");
        assert_eq!(val("\"a\" < \"b\""), "true");
        assert_eq!(val("[1, 2] < [1, 3]"), "true");
        assert_eq!(val("true < 0"), "true");
        assert_eq!(val("\"x\" |> upper |> lower"), "x");
        assert_eq!(val("\"abc\" |> substr(1, 1)"), "b");
    }

    #[test]
    fn type_errors_check_left_then_right() {
        assert_eq!(val("\"a\" + [1]"), "E_TYPE operator +: expected int, got str");
        assert_eq!(val("1 + \"a\""), "E_TYPE operator +: expected int, got str");
        assert_eq!(val("!1"), "E_TYPE operator !: expected bool, got int");
        assert_eq!(val("-\"a\""), "E_TYPE operator -: expected int, got str");
        assert_eq!(val("5[\"a\"]"), "E_TYPE index: expected int, got str");
        assert_eq!(val("5[0]"), "E_TYPE index target: expected str|list, got int");
        assert_eq!(val("\"abc\"[3]"), "E_ARG fn index: out of range");
        assert_eq!(val("\"abc\"[-1]"), "c");
    }

    #[test]
    fn short_circuit() {
        assert_eq!(val("true || (1 / 0 == 1)"), "true");
        assert_eq!(val("false && (1 / 0 == 1)"), "false");
        assert_eq!(val("false || (1 / 0 == 1)"), "E_DIV_ZERO");
        assert_eq!(val("1 || true"), "E_TYPE operator ||: expected bool, got int");
        assert_eq!(val("true && 1"), "E_TYPE operator &&: expected bool, got int");
    }

    #[test]
    fn call_order() {
        assert_eq!(val("nope(undefined)"), "E_UNKNOWN_FUNC nope");
        assert_eq!(val("upper(undefined, 2)"), "E_UNKNOWN_VAR undefined");
        assert_eq!(val("upper(\"a\", 2)"), "E_ARITY fn upper: expected 1, got 2");
        assert_eq!(val("upper(1)"), "E_TYPE fn upper argument 1: expected str, got int");
        assert_eq!(val("1 |> cost"), "E_UNKNOWN_FUNC cost");
    }

    #[test]
    fn interpolation_of_lists_fails() {
        assert_eq!(
            outcome(&[], "let xs = [1]\nabort \"{xs}\"\n"),
            "E_INTERP list"
        );
    }

    #[test]
    fn scoping() {
        assert_eq!(outcome(&[], "let a = 1\nlet a = 2\n"), "E_REDEFINE a");
        assert_eq!(outcome(&[], "let a = 1\nwhen true {\nlet a = 2\nset a = 3\n}\nabort str(a)\n"), "E_ABORT 1");
        assert_eq!(outcome(&[], "set a = 1\n"), "E_SET_UNDEFINED a");
        assert_eq!(outcome(&[], "let a = a\n"), "E_UNKNOWN_VAR a");
        assert_eq!(
            outcome(&[], "let a = 1\nwhen true {\nset a = 3\n}\nabort str(a)\n"),
            "E_ABORT 3"
        );
        assert_eq!(
            outcome(&[], "each i, x in [5, 6] {\nlet y = i + x\n}\nabort str(i)\n"),
            "E_UNKNOWN_VAR i"
        );
    }

    #[test]
    fn rules_see_later_bindings_in_their_defining_scope() {
        let src = "let k = 1\nrule r() {\n set k = k + 1\n abort str(k)\n}\nuse r()\n";
        assert_eq!(outcome(&[], src), "E_ABORT 2");
        let src = "rule r() {\n abort str(late)\n}\nlet late = 7\nuse r()\n";
        assert_eq!(outcome(&[], src), "E_ABORT 7");
    }

    #[test]
    fn use_argument_binding() {
        let head = "rule r(a, b = a + 1) {\n abort \"{a},{b}\"\n}\n";
        let t = |call: &str| outcome(&[], &format!("{head}{call}\n"));
        assert_eq!(t("use r(1)"), "E_ABORT 1,2");
        assert_eq!(t("use r(1, 5)"), "E_ABORT 1,5");
        assert_eq!(t("use r(b = 9, a = 1)"), "E_ABORT 1,9");
        assert_eq!(t("use r()"), "E_ARG rule r: missing argument a");
        assert_eq!(t("use r(1, 2, 3)"), "E_ARITY rule r: expected 2, got 3");
        assert_eq!(t("use r(1, a = 2)"), "E_ARG rule r: duplicate argument a");
        assert_eq!(t("use r(1, c = 2)"), "E_ARG rule r: unknown argument c");
        assert_eq!(t("use nope(undefined)"), "E_UNKNOWN_RULE nope");
    }

    #[test]
    fn includes() {
        let files = [("a.kiln", "let x = 1\n"), ("loop.kiln", "include \"loop.kiln\"\n")];
        assert_eq!(outcome(&files, "include \"a.kiln\"\ninclude \"a.kiln\"\n"), "E_REDEFINE x");
        assert_eq!(outcome(&files, "include \"missing.kiln\"\n"), "E_INCLUDE_MISSING missing.kiln");
        assert_eq!(outcome(&files, "include \"loop.kiln\"\n"), "E_INCLUDE_CYCLE loop.kiln");
        assert_eq!(outcome(&files, "include \"a b\"\n"), "E_BAD_PATH a b");
        assert_eq!(outcome(&files, "include 1\n"), "E_TYPE include path: expected str, got int");
        assert_eq!(
            outcome(&[("bad.kiln", "let = 1\n")], "abort \"x\"\ninclude \"bad.kiln\"\n"),
            "E_ABORT x"
        );
        assert_eq!(
            outcome(&[("bad.kiln", "let = 1\n")], "include \"bad.kiln\"\n"),
            "E_PARSE bad.kiln:1"
        );
    }

    #[test]
    fn step_field_errors() {
        let t = |body: &str| outcome(&[], &format!("step {{\n{body}\n}}\n"));
        assert_eq!(t("out \"out/a\""), "E_STEP_FIELD missing cmd");
        assert_eq!(t("cmd copy()"), "E_STEP_FIELD missing out");
        assert_eq!(t("cmd copy()\ncmd copy()"), "E_STEP_FIELD duplicate cmd");
        assert_eq!(t("cost 1\ncost 1 / 0"), "E_STEP_FIELD duplicate cost");
        assert_eq!(t("cost -1"), "E_ARG field cost: negative");
        assert_eq!(t("out 5"), "E_TYPE field out: expected strlist, got int");
        assert_eq!(t("out [\"a\", 1]"), "E_TYPE field out: expected strlist, got int");
        assert_eq!(t("cmd frob()"), "E_UNKNOWN_CMD frob");
        assert_eq!(t("cmd grep()"), "E_ARITY cmd grep: expected 1, got 0");
        assert_eq!(t("cmd grep(1)"), "E_TYPE cmd grep argument 1: expected str, got int");
        assert_eq!(
            t("out \"out/a\"\nin \"x\"\ncmd indent(-1)"),
            "E_ARG cmd indent: negative"
        );
        assert_eq!(
            t("out \"out/a\"\nin \"x\"\ncmd replace(\"\", \"b\")"),
            "E_ARG cmd replace: empty pattern"
        );
    }

    #[test]
    fn phony_checks_order() {
        assert_eq!(outcome(&[], "phony a = []\nphony a = 1\n"), "E_TYPE phony a: expected strlist, got int");
        assert_eq!(outcome(&[], "phony a = []\nphony a = [\"bad path\"]\n"), "E_BAD_PATH bad path");
        assert_eq!(outcome(&[], "phony a = []\nphony a = []\n"), "E_DUP_PHONY a");
        assert_eq!(outcome(&[], "phony a = [\"@x\", \"src\"]\n"), "ok steps=0 phonies=1");
    }
}
