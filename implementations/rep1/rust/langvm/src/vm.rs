//! The stack virtual machine.

use crate::bytecode::{CompiledProgram, Instr};
use crate::value::*;
use std::cell::RefCell;
use std::rc::Rc;

/// Maximum number of simultaneously live call frames.
pub const MAX_FRAMES: usize = 20000;

/// A panic message (without the `panic: ` prefix).
pub type Panic = String;

pub(crate) struct Frame {
    pub func: u32,
    pub pc: usize,
    pub base: usize,
    pub ret_to: usize,
    pub closure: Option<Rc<Closure>>,
}

/// The virtual machine: a value stack, call frames and an output buffer.
pub struct Vm<'p> {
    pub(crate) prog: &'p CompiledProgram,
    pub(crate) stack: Vec<Value>,
    pub(crate) frames: Vec<Frame>,
    /// Everything the program has written so far (UTF-8).
    pub out: Vec<u8>,
}

fn ctor_of_value(v: &Value) -> usize {
    use crate::program::*;
    (match v {
        Value::Int(_) => CTOR_INT,
        Value::Float(_) => CTOR_FLOAT,
        Value::Bool(_) => CTOR_BOOL,
        Value::Char(_) => CTOR_CHAR,
        Value::Str(_) => CTOR_STR,
        Value::Unit => CTOR_UNIT,
        Value::List(_) => CTOR_LIST,
        Value::Map(_) => CTOR_MAP,
        Value::Struct(s) => CTOR_DECL_BASE + s.decl,
        Value::Enum(e) => CTOR_DECL_BASE + e.decl,
        Value::Tuple(_) | Value::Closure(_) => u32::MAX,
    }) as usize
}

impl<'p> Vm<'p> {
    /// Creates a VM for a compiled program.
    pub fn new(prog: &'p CompiledProgram) -> Vm<'p> {
        Vm { prog, stack: Vec::with_capacity(1024), frames: Vec::with_capacity(256), out: Vec::new() }
    }

    /// Runs `main`. On a panic, appends the panic line to the output.
    pub fn run_main(&mut self) {
        let main = self.prog.main;
        let res = match self.enter(main, 0, None, 0) {
            Ok(()) => self.run(0),
            Err(e) => Err(e),
        };
        if let Err(msg) = res {
            self.out.extend_from_slice(b"panic: ");
            self.out.extend_from_slice(msg.as_bytes());
            self.out.push(b'\n');
        }
    }

    pub(crate) fn enter(
        &mut self,
        func: u32,
        argc: usize,
        closure: Option<Rc<Closure>>,
        ret_to: usize,
    ) -> Result<(), Panic> {
        if self.frames.len() >= MAX_FRAMES {
            return Err("call stack overflow".to_string());
        }
        let f = &self.prog.funcs[func as usize];
        let base = self.stack.len() - argc;
        let extra = f.nslots as usize - argc;
        for _ in 0..extra {
            self.stack.push(Value::Unit);
        }
        self.frames.push(Frame { func, pc: 0, base, ret_to, closure });
        Ok(())
    }

    /// Calls a closure value from native code and returns its result.
    pub(crate) fn call_closure(&mut self, f: &Value, args: &[Value]) -> Result<Value, Panic> {
        let clo = match f {
            Value::Closure(c) => c.clone(),
            _ => unreachable!("calling a non-closure"),
        };
        let ret_to = self.stack.len();
        for a in args {
            self.stack.push(a.clone());
        }
        let depth = self.frames.len();
        self.enter(clo.func, args.len(), Some(clo), ret_to)?;
        self.run(depth)?;
        Ok(self.stack.pop().unwrap())
    }

    fn pop(&mut self) -> Value {
        self.stack.pop().expect("stack underflow")
    }

    /// The interpreter loop; returns when the frame count drops to `stop_depth`.
    pub(crate) fn run(&mut self, stop_depth: usize) -> Result<(), Panic> {
        let prog = self.prog;
        let (mut code, mut pc, mut base) = {
            let fr = self.frames.last().unwrap();
            (&prog.funcs[fr.func as usize].code[..], fr.pc, fr.base)
        };
        macro_rules! pop_int {
            () => {
                match self.stack.pop() {
                    Some(Value::Int(i)) => i,
                    _ => unreachable!("expected int"),
                }
            };
        }
        macro_rules! pop_float {
            () => {
                match self.stack.pop() {
                    Some(Value::Float(i)) => i,
                    _ => unreachable!("expected float"),
                }
            };
        }
        macro_rules! reload {
            () => {{
                let fr = self.frames.last().unwrap();
                code = &prog.funcs[fr.func as usize].code[..];
                pc = fr.pc;
                base = fr.base;
            }};
        }
        macro_rules! cmp_op {
            ($p:pat) => {{
                let b = self.pop();
                let a = self.pop();
                let r = matches!(value_cmp(&a, &b), $p);
                self.stack.push(Value::Bool(r));
            }};
        }
        macro_rules! int_bin {
            ($f:expr) => {{
                let b = pop_int!();
                let a = pop_int!();
                self.stack.push(Value::Int($f(a, b)));
            }};
        }
        macro_rules! float_bin {
            ($op:tt) => {{
                let b = pop_float!();
                let a = pop_float!();
                self.stack.push(Value::Float(a $op b));
            }};
        }
        use std::cmp::Ordering::*;
        loop {
            let ins = code[pc];
            pc += 1;
            match ins {
                Instr::Const(k) => self.stack.push(prog.consts[k as usize].clone()),
                Instr::PushTrue => self.stack.push(Value::Bool(true)),
                Instr::PushFalse => self.stack.push(Value::Bool(false)),
                Instr::PushUnit => self.stack.push(Value::Unit),
                Instr::Load(i) => {
                    let v = self.stack[base + i as usize].clone();
                    self.stack.push(v);
                }
                Instr::Store(i) => {
                    let v = self.pop();
                    self.stack[base + i as usize] = v;
                }
                Instr::LoadUp(i) => {
                    let v = self.frames.last().unwrap().closure.as_ref().unwrap().upvals[i as usize].clone();
                    self.stack.push(v);
                }
                Instr::IncLocal(i) => {
                    if let Value::Int(x) = &mut self.stack[base + i as usize] {
                        *x = x.wrapping_add(1);
                    }
                }
                Instr::Pop => {
                    self.stack.pop();
                }
                Instr::MakeClosure(f, n) => {
                    let at = self.stack.len() - n as usize;
                    let upvals = self.stack.split_off(at);
                    self.stack.push(Value::Closure(Rc::new(Closure { func: f, upvals })));
                }
                Instr::Call(f, argc) => {
                    self.frames.last_mut().unwrap().pc = pc;
                    let ret_to = self.stack.len() - argc as usize;
                    self.enter(f, argc as usize, None, ret_to)?;
                    reload!();
                }
                Instr::CallValue(argc) => {
                    self.frames.last_mut().unwrap().pc = pc;
                    let at = self.stack.len() - argc as usize - 1;
                    let clo = match &self.stack[at] {
                        Value::Closure(c) => c.clone(),
                        _ => unreachable!("calling a non-closure"),
                    };
                    self.enter(clo.func, argc as usize, Some(clo), at)?;
                    reload!();
                }
                Instr::CallMethod(t, m, argc) => {
                    self.frames.last_mut().unwrap().pc = pc;
                    let at = self.stack.len() - argc as usize;
                    let ctor = ctor_of_value(&self.stack[at]);
                    let f = prog.impl_table[t as usize][ctor].as_ref().expect("impl exists")[m as usize];
                    self.enter(f, argc as usize, None, at)?;
                    reload!();
                }
                Instr::CallBuiltin(b, argc) => {
                    self.call_builtin(b, argc as usize)?;
                }
                Instr::Ret => {
                    let v = self.pop();
                    let fr = self.frames.pop().unwrap();
                    self.stack.truncate(fr.ret_to);
                    self.stack.push(v);
                    if self.frames.len() == stop_depth {
                        return Ok(());
                    }
                    reload!();
                }
                Instr::AddI => int_bin!(|a: i64, b: i64| a.wrapping_add(b)),
                Instr::SubI => int_bin!(|a: i64, b: i64| a.wrapping_sub(b)),
                Instr::MulI => int_bin!(|a: i64, b: i64| a.wrapping_mul(b)),
                Instr::DivI => {
                    let b = pop_int!();
                    let a = pop_int!();
                    if b == 0 {
                        return Err("divide by zero".to_string());
                    }
                    self.stack.push(Value::Int(a.wrapping_div(b)));
                }
                Instr::RemI => {
                    let b = pop_int!();
                    let a = pop_int!();
                    if b == 0 {
                        return Err("modulo by zero".to_string());
                    }
                    self.stack.push(Value::Int(a.wrapping_rem(b)));
                }
                Instr::NegI => {
                    let a = pop_int!();
                    self.stack.push(Value::Int(a.wrapping_neg()));
                }
                Instr::BNot => {
                    let a = pop_int!();
                    self.stack.push(Value::Int(!a));
                }
                Instr::BAnd => int_bin!(|a: i64, b: i64| a & b),
                Instr::BOr => int_bin!(|a: i64, b: i64| a | b),
                Instr::BXor => int_bin!(|a: i64, b: i64| a ^ b),
                Instr::Shl => {
                    let b = pop_int!();
                    let a = pop_int!();
                    if !(0..=63).contains(&b) {
                        return Err("shift amount out of range".to_string());
                    }
                    self.stack.push(Value::Int(a.wrapping_shl(b as u32)));
                }
                Instr::Shr => {
                    let b = pop_int!();
                    let a = pop_int!();
                    if !(0..=63).contains(&b) {
                        return Err("shift amount out of range".to_string());
                    }
                    self.stack.push(Value::Int(a >> b));
                }
                Instr::AddF => float_bin!(+),
                Instr::SubF => float_bin!(-),
                Instr::MulF => float_bin!(*),
                Instr::DivF => float_bin!(/),
                Instr::NegF => {
                    let a = pop_float!();
                    self.stack.push(Value::Float(-a));
                }
                Instr::NotB => {
                    let v = self.pop();
                    self.stack.push(Value::Bool(!matches!(v, Value::Bool(true))));
                }
                Instr::Eq => {
                    let b = self.pop();
                    let a = self.pop();
                    self.stack.push(Value::Bool(value_eq(&a, &b)));
                }
                Instr::Ne => {
                    let b = self.pop();
                    let a = self.pop();
                    self.stack.push(Value::Bool(!value_eq(&a, &b)));
                }
                Instr::Lt => cmp_op!(Some(Less)),
                Instr::Le => cmp_op!(Some(Less) | Some(Equal)),
                Instr::Gt => cmp_op!(Some(Greater)),
                Instr::Ge => cmp_op!(Some(Greater) | Some(Equal)),
                Instr::Concat => {
                    let b = self.pop();
                    let a = self.pop();
                    match (a, b) {
                        (Value::Str(x), Value::Str(y)) => {
                            let mut v = Vec::with_capacity(x.len() + y.len());
                            v.extend_from_slice(&x);
                            v.extend_from_slice(&y);
                            self.stack.push(Value::Str(Rc::new(v)));
                        }
                        (Value::List(x), Value::List(y)) => {
                            let mut v = x.borrow().clone();
                            v.extend(y.borrow().iter().cloned());
                            self.stack.push(Value::list_of(v));
                        }
                        _ => unreachable!("bad concat operands"),
                    }
                }
                Instr::Jump(t) => pc = t as usize,
                Instr::JumpIfFalse(t) => {
                    if !matches!(self.pop(), Value::Bool(true)) {
                        pc = t as usize;
                    }
                }
                Instr::JumpIfTrue(t) => {
                    if matches!(self.pop(), Value::Bool(true)) {
                        pc = t as usize;
                    }
                }
                Instr::MakeList(n) => {
                    let at = self.stack.len() - n as usize;
                    let items = self.stack.split_off(at);
                    self.stack.push(Value::list_of(items));
                }
                Instr::MakeMap(n) => {
                    let at = self.stack.len() - 2 * n as usize;
                    let items = self.stack.split_off(at);
                    let mut m = MapObj::new();
                    let mut it = items.into_iter();
                    while let (Some(k), Some(v)) = (it.next(), it.next()) {
                        m.insert(k, v);
                    }
                    self.stack.push(Value::Map(Rc::new(RefCell::new(m))));
                }
                Instr::MakeTuple(n) => {
                    let at = self.stack.len() - n as usize;
                    let items = self.stack.split_off(at);
                    self.stack.push(Value::Tuple(Rc::new(items)));
                }
                Instr::MakeStruct(d, n) => {
                    let at = self.stack.len() - n as usize;
                    let fields = self.stack.split_off(at);
                    self.stack.push(Value::Struct(Rc::new(StructVal { decl: d, fields })));
                }
                Instr::MakeEnum(d, v, n) => {
                    if n == 0 {
                        self.stack.push(prog.nullary[d as usize][v as usize].clone());
                    } else {
                        let at = self.stack.len() - n as usize;
                        let fields = self.stack.split_off(at);
                        self.stack.push(Value::Enum(Rc::new(EnumVal { decl: d, variant: v, fields })));
                    }
                }
                Instr::GetField(i) => {
                    let v = match self.pop() {
                        Value::Struct(s) => s.fields[i as usize].clone(),
                        _ => unreachable!("field of non-struct"),
                    };
                    self.stack.push(v);
                }
                Instr::GetPayload(i) => {
                    let v = match self.pop() {
                        Value::Enum(e) => e.fields[i as usize].clone(),
                        _ => unreachable!("payload of non-enum"),
                    };
                    self.stack.push(v);
                }
                Instr::GetTuple(i) => {
                    let v = match self.pop() {
                        Value::Tuple(t) => t[i as usize].clone(),
                        _ => unreachable!("component of non-tuple"),
                    };
                    self.stack.push(v);
                }
                Instr::IndexGet => {
                    let i = self.pop();
                    let c = self.pop();
                    let v = match (c, i) {
                        (Value::List(l), Value::Int(i)) => {
                            let l = l.borrow();
                            if i < 0 || i as u64 >= l.len() as u64 {
                                return Err("index out of bounds".to_string());
                            }
                            l[i as usize].clone()
                        }
                        (Value::Str(s), Value::Int(i)) => {
                            if i < 0 || i as u64 >= s.len() as u64 {
                                return Err("index out of bounds".to_string());
                            }
                            Value::Char(s[i as usize])
                        }
                        (Value::Map(m), k) => match m.borrow().get(&k) {
                            Some(v) => v.clone(),
                            None => return Err("missing key".to_string()),
                        },
                        _ => unreachable!("bad index operands"),
                    };
                    self.stack.push(v);
                }
                Instr::IndexSet => {
                    let v = self.pop();
                    let i = self.pop();
                    let c = self.pop();
                    match (c, i) {
                        (Value::List(l), Value::Int(i)) => {
                            let mut l = l.borrow_mut();
                            if i < 0 || i as u64 >= l.len() as u64 {
                                return Err("index out of bounds".to_string());
                            }
                            l[i as usize] = v;
                        }
                        (Value::Map(m), k) => m.borrow_mut().insert(k, v),
                        _ => unreachable!("bad index-assign operands"),
                    }
                }
                Instr::IsVariant(v) => {
                    let r = match self.pop() {
                        Value::Enum(e) => e.variant == v,
                        _ => unreachable!("variant test on non-enum"),
                    };
                    self.stack.push(Value::Bool(r));
                }
                Instr::SeqLen => {
                    let n = match self.pop() {
                        Value::List(l) => l.borrow().len(),
                        Value::Str(s) => s.len(),
                        _ => unreachable!("length of non-sequence"),
                    };
                    self.stack.push(Value::Int(n as i64));
                }
                Instr::SeqGet => {
                    let i = pop_int!() as usize;
                    let v = match self.pop() {
                        Value::List(l) => l.borrow()[i].clone(),
                        Value::Str(s) => Value::Char(s[i]),
                        _ => unreachable!("element of non-sequence"),
                    };
                    self.stack.push(v);
                }
                Instr::ListRest(i) => {
                    let v = match self.pop() {
                        Value::List(l) => l.borrow()[i as usize..].to_vec(),
                        _ => unreachable!("rest of non-list"),
                    };
                    self.stack.push(Value::list_of(v));
                }
                Instr::NoMatch => return Err("no match".to_string()),
            }
        }
    }
}
