//! The evaluator: a trampolined tree-walking interpreter.

use std::io::{self, Write};
use std::rc::Rc;

use crate::analyze::{analyze, LambdaDef, Node};
use crate::env::{self, Env, Frame, Globals};
use crate::error::{Error, Result};
use crate::primitives::{self, Imp};
use crate::reader::Reader;
use crate::value::{Closure, Symbol, Value};

/// A Scheme interpreter with its own global environment and output sink.
///
/// ```
/// use scheme::Interpreter;
///
/// let mut out = Vec::new();
/// let mut interp = Interpreter::new(&mut out);
/// interp.run("(define x 6) (display (* x 7))").unwrap();
/// drop(interp);
/// assert_eq!(String::from_utf8(out).unwrap(), "42");
/// ```
pub struct Interpreter<'a> {
    globals: Globals,
    out: Box<dyn Write + 'a>,
    io_error: Option<io::Error>,
}

/// What to do after setting up a procedure call.
enum Step {
    /// The call finished with a value (a primitive).
    Done(Value),
    /// Continue evaluating this node in this environment (a closure body).
    Continue(Rc<Node>, Env),
}

impl<'a> Interpreter<'a> {
    /// Creates an interpreter writing program output to `out`, with the
    /// standard primitives bound in the global environment.
    pub fn new(out: impl Write + 'a) -> Interpreter<'a> {
        let mut interp = Interpreter { globals: Globals::default(), out: Box::new(out), io_error: None };
        for p in primitives::PRIMITIVES {
            interp.globals.define(Symbol::new(p.name), Value::Prim(p));
        }
        interp
    }

    /// Reads, analyses and evaluates each form of `src` in order, writing the
    /// printed value of every non-void result to the output.
    ///
    /// Stops at the first error and returns it; output produced so far is kept.
    pub fn run(&mut self, src: &str) -> Result<()> {
        let mut reader = Reader::new(src);
        while let Some(datum) = reader.read()? {
            let v = self.eval_datum(&datum)?;
            if !matches!(v, Value::Void) {
                let mut s = crate::printer::write_string(&v);
                s.push('\n');
                self.write_str(&s);
            }
        }
        Ok(())
    }

    /// Analyses and evaluates one datum in the global environment.
    pub fn eval_datum(&mut self, datum: &Value) -> Result<Value> {
        let node = analyze(datum)?;
        self.eval(&node, &None)
    }

    /// Writes text to the program output.
    pub fn write_str(&mut self, s: &str) {
        if self.io_error.is_none() {
            if let Err(e) = self.out.write_all(s.as_bytes()) {
                self.io_error = Some(e);
            }
        }
    }

    /// Flushes the output, reporting the first I/O error encountered so far.
    pub fn flush(&mut self) -> io::Result<()> {
        if let Some(e) = self.io_error.take() {
            return Err(e);
        }
        self.out.flush()
    }

    fn eval(&mut self, node: &Rc<Node>, env: &Env) -> Result<Value> {
        // Fast paths that need neither a loop nor owned handles.
        match &**node {
            Node::Const(v) => return Ok(v.clone()),
            Node::Var(s) => return self.lookup(*s, env),
            _ => {}
        }
        self.eval_loop(node.clone(), env.clone())
    }

    fn lookup(&self, sym: Symbol, env: &Env) -> Result<Value> {
        env::lookup(&self.globals, env, sym).ok_or(Error::UnboundVariable)
    }

    /// Evaluates `node`; tail positions update `node`/`env` and loop instead
    /// of recursing, so tail calls use constant host stack.
    fn eval_loop(&mut self, mut node: Rc<Node>, mut env: Env) -> Result<Value> {
        loop {
            let (next_node, next_env): (Rc<Node>, Env) = match &*node {
                Node::Const(v) => return Ok(v.clone()),
                Node::Var(s) => return self.lookup(*s, &env),
                Node::If(test, then, alt) => {
                    if self.eval(test, &env)?.is_truthy() {
                        (then.clone(), env)
                    } else if let Some(alt) = alt {
                        (alt.clone(), env)
                    } else {
                        return Ok(Value::Void);
                    }
                }
                Node::Define(name, expr) => {
                    let v = self.eval(expr, &env)?;
                    env::define(&mut self.globals, &env, *name, v);
                    return Ok(Value::Void);
                }
                Node::Set(name, expr) => {
                    let v = self.eval(expr, &env)?;
                    if env::assign(&mut self.globals, &env, *name, v) {
                        return Ok(Value::Void);
                    }
                    return Err(Error::UnboundVariable);
                }
                Node::Lambda(def) => {
                    return Ok(Value::Closure(Rc::new(Closure { def: def.clone(), env })));
                }
                Node::Let(binds, body) => {
                    let mut vars = Vec::with_capacity(binds.len() + 1);
                    for (name, init) in binds {
                        vars.push((*name, self.eval(init, &env)?));
                    }
                    (body.clone(), Some(Frame::new(vars, env)))
                }
                Node::NamedLet(name, inits, def) => {
                    let mut args = Vec::with_capacity(inits.len());
                    for init in inits {
                        args.push(self.eval(init, &env)?);
                    }
                    let frame = Frame::new(Vec::new(), env);
                    let closure = Value::Closure(Rc::new(Closure {
                        def: def.clone(),
                        env: Some(frame.clone()),
                    }));
                    frame.define(*name, closure.clone());
                    match self.apply_step(closure, args)? {
                        Step::Done(v) => return Ok(v),
                        Step::Continue(n, e) => (n, e),
                    }
                }
                Node::LetStar(binds, body) => {
                    let mut cur = env;
                    if binds.is_empty() {
                        cur = Some(Frame::new(Vec::new(), cur));
                    }
                    for (name, init) in binds {
                        let v = self.eval(init, &cur)?;
                        cur = Some(Frame::new(vec![(*name, v)], cur));
                    }
                    (body.clone(), cur)
                }
                Node::Letrec(binds, body) => {
                    let frame = Frame::new(Vec::with_capacity(binds.len() + 1), env);
                    let cur = Some(frame.clone());
                    for (name, init) in binds {
                        let v = self.eval(init, &cur)?;
                        frame.define(*name, v);
                    }
                    (body.clone(), cur)
                }
                Node::Begin(forms) => {
                    let (last, init) = forms.split_last().expect("begin is never empty");
                    for f in init {
                        self.eval(f, &env)?;
                    }
                    (last.clone(), env)
                }
                Node::Cond(clauses) => {
                    let mut chosen = None;
                    for clause in clauses {
                        let hit = match &clause.test {
                            None => Some(Value::Bool(true)),
                            Some(t) => Some(self.eval(t, &env)?).filter(Value::is_truthy),
                        };
                        if let Some(test_value) = hit {
                            chosen = Some(match &clause.body {
                                Some(b) => Ok(b.clone()),
                                None => Err(test_value),
                            });
                            break;
                        }
                    }
                    match chosen {
                        None => return Ok(Value::Void),
                        Some(Err(v)) => return Ok(v),
                        Some(Ok(body)) => (body, env),
                    }
                }
                Node::And(forms) => match forms.split_last() {
                    None => return Ok(Value::Bool(true)),
                    Some((last, init)) => {
                        for f in init {
                            let v = self.eval(f, &env)?;
                            if !v.is_truthy() {
                                return Ok(v);
                            }
                        }
                        (last.clone(), env)
                    }
                },
                Node::Or(forms) => match forms.split_last() {
                    None => return Ok(Value::Bool(false)),
                    Some((last, init)) => {
                        for f in init {
                            let v = self.eval(f, &env)?;
                            if v.is_truthy() {
                                return Ok(v);
                            }
                        }
                        (last.clone(), env)
                    }
                },
                Node::App(fnode, argnodes) => {
                    let f = self.eval(fnode, &env)?;
                    let mut args = Vec::with_capacity(argnodes.len());
                    for a in argnodes {
                        args.push(self.eval(a, &env)?);
                    }
                    match self.apply_step(f, args)? {
                        Step::Done(v) => return Ok(v),
                        Step::Continue(n, e) => (n, e),
                    }
                }
            };
            node = next_node;
            env = next_env;
        }
    }

    /// Applies `f` to `args`. Closures are not run here: their body and new
    /// frame are returned so the caller's loop can continue in tail position.
    fn apply_step(&mut self, mut f: Value, mut args: Vec<Value>) -> Result<Step> {
        loop {
            match f {
                Value::Closure(c) => {
                    let frame = bind_args(&c, args)?;
                    return Ok(Step::Continue(c.def.body.clone(), Some(frame)));
                }
                Value::Prim(p) => {
                    p.check_arity(args.len())?;
                    match p.imp {
                        Imp::Fn(func) => return func(self, &args).map(Step::Done),
                        Imp::Apply => {
                            // (apply f a ... lst): spread `lst` and retry.
                            let last = args.pop().expect("arity checked");
                            let spread = last.list_to_vec().ok_or(Error::TypeError)?;
                            f = args.remove(0);
                            args.extend(spread);
                        }
                    }
                }
                _ => return Err(Error::TypeError),
            }
        }
    }
}

/// Builds the call frame for a closure, checking the argument count.
fn bind_args(closure: &Closure, mut args: Vec<Value>) -> Result<Rc<Frame>> {
    let def: &LambdaDef = &closure.def;
    let n = def.params.len();
    let rest_list = match def.rest {
        None if args.len() != n => return Err(Error::ArityError),
        Some(_) if args.len() < n => return Err(Error::ArityError),
        None => None,
        Some(_) => Some(Value::list(args.split_off(n))),
    };
    let mut vars = Vec::with_capacity(n + 2);
    vars.extend(def.params.iter().copied().zip(args));
    if let (Some(name), Some(list)) = (def.rest, rest_list) {
        vars.push((name, list));
    }
    Ok(Frame::new(vars, closure.env.clone()))
}
