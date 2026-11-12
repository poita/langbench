//! The bytecode compiler: checked IR to stack-machine code.

use crate::bytecode::{CompiledProgram, FuncCode, Instr};
use crate::ir::{self, Arith, Bit, Cmp, Const, Num, Pat, VarRef};
use crate::program::{DeclKind, Program, CTOR_DECL_BASE};
use crate::value::{EnumVal, Value};
use std::collections::HashMap;
use std::rc::Rc;

#[derive(PartialEq, Eq, Hash)]
enum ConstKey {
    Int(i64),
    Float(u64),
    Char(char),
    Str(Vec<char>),
}

struct Shared<'p> {
    prog: &'p Program,
    consts: Vec<Value>,
    const_map: HashMap<ConstKey, u32>,
}

impl<'p> Shared<'p> {
    fn constant(&mut self, c: &Const) -> u32 {
        let key = match c {
            Const::Int(i) => ConstKey::Int(*i),
            Const::Float(f) => ConstKey::Float(f.to_bits()),
            Const::Char(c) => ConstKey::Char(*c),
            Const::Str(s) => ConstKey::Str((**s).clone()),
            Const::Bool(_) => unreachable!("bool constants are pushed directly"),
        };
        if let Some(&i) = self.const_map.get(&key) {
            return i;
        }
        let v = match c {
            Const::Int(i) => Value::Int(*i),
            Const::Float(f) => Value::Float(*f),
            Const::Char(c) => Value::Char(*c),
            Const::Str(s) => Value::Str(s.clone()),
            Const::Bool(_) => unreachable!(),
        };
        let idx = self.consts.len() as u32;
        self.consts.push(v);
        self.const_map.insert(key, idx);
        idx
    }

    fn int_const(&mut self, i: i64) -> u32 {
        self.constant(&Const::Int(i))
    }
}

struct LoopCtx {
    depth: i32,
    break_patches: Vec<usize>,
    continue_target: Option<usize>,
    continue_patches: Vec<usize>,
}

struct FnCompiler<'a, 'p> {
    sh: &'a mut Shared<'p>,
    code: Vec<Instr>,
    depth: i32,
    next_temp: usize,
    max_slot: usize,
    loops: Vec<LoopCtx>,
}

/// Compiles the checked functions into a runnable program.
pub fn compile_program(prog: &Program, funcs: &[ir::Func]) -> CompiledProgram {
    let mut sh = Shared { prog, consts: Vec::new(), const_map: HashMap::new() };
    let mut out = Vec::with_capacity(funcs.len());
    for f in funcs {
        out.push(compile_func(&mut sh, f));
    }
    // impl tables
    let nctors = CTOR_DECL_BASE as usize + prog.decls.len();
    let mut impl_table: Vec<Vec<Option<Rc<[u32]>>>> = vec![vec![None; nctors]; prog.traits.len()];
    for imp in &prog.impls {
        let ctor = Program::ctor_of(&imp.head).unwrap() as usize;
        let methods: Vec<u32> = imp.table.iter().map(|m| m.unwrap_or(0)).collect();
        impl_table[imp.trait_id as usize][ctor] = Some(methods.into());
    }
    // nullary enum values
    let nullary: Vec<Vec<Value>> = prog
        .decls
        .iter()
        .enumerate()
        .map(|(d, decl)| match &decl.kind {
            DeclKind::Enum(vs) => vs
                .iter()
                .enumerate()
                .map(|(i, _)| {
                    Value::Enum(Rc::new(EnumVal { decl: d as u32, variant: i as u16, fields: vec![] }))
                })
                .collect(),
            _ => vec![],
        })
        .collect();
    CompiledProgram { consts: sh.consts, funcs: out, impl_table, nullary, main: prog.main_fn }
}

fn compile_func(sh: &mut Shared, f: &ir::Func) -> FuncCode {
    let mut c = FnCompiler {
        sh,
        code: Vec::new(),
        depth: 0,
        next_temp: f.nslots,
        max_slot: f.nslots,
        loops: Vec::new(),
    };
    c.block_value(&f.body);
    c.emit(Instr::Ret);
    FuncCode {
        name: f.name.clone(),
        code: c.code,
        nparams: f.nparams as u32,
        nslots: c.max_slot as u32,
    }
}

fn effect(i: &Instr) -> i32 {
    use Instr::*;
    match *i {
        Const(_) | PushTrue | PushFalse | PushUnit | Load(_) | LoadUp(_) => 1,
        Store(_) | Pop => -1,
        IncLocal(_) => 0,
        MakeClosure(_, n) => 1 - n as i32,
        Call(_, n) => 1 - n as i32,
        CallValue(n) => -(n as i32),
        CallBuiltin(_, n) => 1 - n as i32,
        CallMethod(_, _, n) => 1 - n as i32,
        Ret => -1,
        AddI | SubI | MulI | DivI | RemI | BAnd | BOr | BXor | Shl | Shr | AddF | SubF | MulF
        | DivF | Eq | Ne | Lt | Le | Gt | Ge | Concat => -1,
        NegI | BNot | NegF | NotB => 0,
        Jump(_) => 0,
        JumpIfFalse(_) | JumpIfTrue(_) => -1,
        MakeList(n) => 1 - n as i32,
        MakeMap(n) => 1 - 2 * n as i32,
        MakeTuple(n) => 1 - n as i32,
        MakeStruct(_, n) => 1 - n as i32,
        MakeEnum(_, _, n) => 1 - n as i32,
        GetField(_) | GetPayload(_) | GetTuple(_) => 0,
        IndexGet => -1,
        IndexSet => -3,
        IsVariant(_) | SeqLen | ListRest(_) => 0,
        SeqGet => -1,
        NoMatch => 0,
    }
}

impl<'a, 'p> FnCompiler<'a, 'p> {
    fn emit(&mut self, i: Instr) -> usize {
        self.depth += effect(&i);
        self.code.push(i);
        self.code.len() - 1
    }

    fn here(&self) -> u32 {
        self.code.len() as u32
    }

    fn patch(&mut self, at: usize, target: u32) {
        match &mut self.code[at] {
            Instr::Jump(t) | Instr::JumpIfFalse(t) | Instr::JumpIfTrue(t) => *t = target,
            _ => unreachable!("patching a non-jump"),
        }
    }

    fn patch_here(&mut self, at: usize) {
        let h = self.here();
        self.patch(at, h);
    }

    fn alloc_temp(&mut self) -> u16 {
        let t = self.next_temp;
        self.next_temp += 1;
        if self.next_temp > self.max_slot {
            self.max_slot = self.next_temp;
        }
        t as u16
    }

    // ------------------------------------------------------------- blocks

    /// Compiles a block leaving its value (or unit) on the stack.
    fn block_value(&mut self, b: &ir::Block) {
        for s in &b.stmts {
            self.stmt(s);
        }
        match &b.tail {
            Some(t) => self.expr(t),
            None => {
                self.emit(Instr::PushUnit);
            }
        }
    }

    /// Compiles a block for effect only (no value left).
    fn block_effect(&mut self, b: &ir::Block) {
        for s in &b.stmts {
            self.stmt(s);
        }
        if let Some(t) = &b.tail {
            self.expr(t);
            self.emit(Instr::Pop);
        }
    }

    // --------------------------------------------------------- statements

    fn stmt(&mut self, s: &ir::Stmt) {
        match s {
            ir::Stmt::Let(pat, e) => match pat {
                Pat::Bind(slot) => {
                    self.expr(e);
                    self.emit(Instr::Store(*slot));
                }
                Pat::Wild => {
                    self.expr(e);
                    self.emit(Instr::Pop);
                }
                _ => {
                    let mark = self.next_temp;
                    let t = self.alloc_temp();
                    self.expr(e);
                    self.emit(Instr::Store(t));
                    let mut fails = Vec::new();
                    self.pat(pat, t, &mut fails);
                    self.next_temp = mark;
                }
            },
            ir::Stmt::Set(slot, e) => {
                self.expr(e);
                self.emit(Instr::Store(*slot));
            }
            ir::Stmt::SetIndex(a, i, e) => {
                self.expr(a);
                self.expr(i);
                self.expr(e);
                self.emit(Instr::IndexSet);
            }
            ir::Stmt::Expr(e) => {
                self.expr(e);
                self.emit(Instr::Pop);
            }
            ir::Stmt::While(c, body) => {
                let top = self.here();
                self.expr(c);
                let exit = self.emit(Instr::JumpIfFalse(0));
                self.loops.push(LoopCtx {
                    depth: self.depth,
                    break_patches: vec![],
                    continue_target: Some(top as usize),
                    continue_patches: vec![],
                });
                self.block_effect(body);
                self.emit(Instr::Jump(top));
                let lp = self.loops.pop().unwrap();
                self.patch_here(exit);
                for b in lp.break_patches {
                    self.patch_here(b);
                }
            }
            ir::Stmt::ForSeq(pat, it, body) => {
                let mark = self.next_temp;
                let lst = self.alloc_temp();
                let idx = self.alloc_temp();
                self.expr(it);
                self.emit(Instr::Store(lst));
                let zero = self.sh.int_const(0);
                self.emit(Instr::Const(zero));
                self.emit(Instr::Store(idx));
                let top = self.here();
                self.emit(Instr::Load(idx));
                self.emit(Instr::Load(lst));
                self.emit(Instr::SeqLen);
                self.emit(Instr::Lt);
                let exit = self.emit(Instr::JumpIfFalse(0));
                self.emit(Instr::Load(lst));
                self.emit(Instr::Load(idx));
                self.emit(Instr::SeqGet);
                self.bind_top(pat);
                self.loops.push(LoopCtx {
                    depth: self.depth,
                    break_patches: vec![],
                    continue_target: None,
                    continue_patches: vec![],
                });
                self.block_effect(body);
                let lp = self.loops.pop().unwrap();
                for c in lp.continue_patches {
                    self.patch_here(c);
                }
                self.emit(Instr::IncLocal(idx));
                self.emit(Instr::Jump(top));
                self.patch_here(exit);
                for b in lp.break_patches {
                    self.patch_here(b);
                }
                self.next_temp = mark;
            }
            ir::Stmt::ForRange(pat, lo, hi, body) => {
                let mark = self.next_temp;
                let cur = self.alloc_temp();
                let hit = self.alloc_temp();
                self.expr(lo);
                self.emit(Instr::Store(cur));
                self.expr(hi);
                self.emit(Instr::Store(hit));
                let top = self.here();
                self.emit(Instr::Load(cur));
                self.emit(Instr::Load(hit));
                self.emit(Instr::Lt);
                let exit = self.emit(Instr::JumpIfFalse(0));
                self.emit(Instr::Load(cur));
                self.bind_top(pat);
                self.loops.push(LoopCtx {
                    depth: self.depth,
                    break_patches: vec![],
                    continue_target: None,
                    continue_patches: vec![],
                });
                self.block_effect(body);
                let lp = self.loops.pop().unwrap();
                for c in lp.continue_patches {
                    self.patch_here(c);
                }
                self.emit(Instr::IncLocal(cur));
                self.emit(Instr::Jump(top));
                self.patch_here(exit);
                for b in lp.break_patches {
                    self.patch_here(b);
                }
                self.next_temp = mark;
            }
            ir::Stmt::Return(e) => {
                match e {
                    Some(e) => self.expr(e),
                    None => {
                        self.emit(Instr::PushUnit);
                    }
                }
                self.emit(Instr::Ret);
            }
            ir::Stmt::Break => {
                let saved = self.depth;
                let target = self.loops.last().map(|l| l.depth).unwrap_or(saved);
                for _ in 0..(saved - target).max(0) {
                    self.emit(Instr::Pop);
                }
                let j = self.emit(Instr::Jump(0));
                self.loops.last_mut().unwrap().break_patches.push(j);
                self.depth = saved;
            }
            ir::Stmt::Continue => {
                let saved = self.depth;
                let target = self.loops.last().map(|l| l.depth).unwrap_or(saved);
                for _ in 0..(saved - target).max(0) {
                    self.emit(Instr::Pop);
                }
                match self.loops.last().unwrap().continue_target {
                    Some(t) => {
                        self.emit(Instr::Jump(t as u32));
                    }
                    None => {
                        let j = self.emit(Instr::Jump(0));
                        self.loops.last_mut().unwrap().continue_patches.push(j);
                    }
                }
                self.depth = saved;
            }
        }
    }

    /// Binds the value on top of the stack to an irrefutable pattern
    /// (consuming it).
    fn bind_top(&mut self, pat: &Pat) {
        match pat {
            Pat::Bind(slot) => {
                self.emit(Instr::Store(*slot));
            }
            Pat::Wild => {
                self.emit(Instr::Pop);
            }
            _ => {
                let mark = self.next_temp;
                let t = self.alloc_temp();
                self.emit(Instr::Store(t));
                let mut fails = Vec::new();
                self.pat(pat, t, &mut fails);
                self.next_temp = mark;
            }
        }
    }

    // ----------------------------------------------------------- patterns

    /// Emits the test-and-bind code for `pat` against the value in `src`;
    /// failure jumps are collected in `fails`.
    fn pat(&mut self, pat: &Pat, src: u16, fails: &mut Vec<usize>) {
        match pat {
            Pat::Wild => {}
            Pat::Bind(slot) => {
                self.emit(Instr::Load(src));
                self.emit(Instr::Store(*slot));
            }
            Pat::Lit(c) => {
                self.emit(Instr::Load(src));
                match c {
                    Const::Bool(true) => {
                        self.emit(Instr::PushTrue);
                    }
                    Const::Bool(false) => {
                        self.emit(Instr::PushFalse);
                    }
                    other => {
                        let k = self.sh.constant(other);
                        self.emit(Instr::Const(k));
                    }
                }
                self.emit(Instr::Eq);
                let j = self.emit(Instr::JumpIfFalse(0));
                fails.push(j);
            }
            Pat::Variant(d, v, subs) => {
                let nvariants = match &self.sh.prog.decls[*d as usize].kind {
                    DeclKind::Enum(vs) => vs.len(),
                    _ => 1,
                };
                if nvariants > 1 {
                    self.emit(Instr::Load(src));
                    self.emit(Instr::IsVariant(*v));
                    let j = self.emit(Instr::JumpIfFalse(0));
                    fails.push(j);
                }
                for (i, sp) in subs.iter().enumerate() {
                    self.sub(sp, src, fails, |_| Instr::GetPayload(i as u16));
                }
            }
            Pat::Tuple(subs) => {
                for (i, sp) in subs.iter().enumerate() {
                    self.sub(sp, src, fails, |_| Instr::GetTuple(i as u16));
                }
            }
            Pat::Struct(subs) => {
                for (i, sp) in subs.iter().enumerate() {
                    self.sub(sp, src, fails, |_| Instr::GetField(i as u16));
                }
            }
            Pat::List(elems, rest) => {
                if !(elems.is_empty() && rest.is_some()) {
                    self.emit(Instr::Load(src));
                    self.emit(Instr::SeqLen);
                    let k = self.sh.int_const(elems.len() as i64);
                    self.emit(Instr::Const(k));
                    self.emit(if rest.is_some() { Instr::Ge } else { Instr::Eq });
                    let j = self.emit(Instr::JumpIfFalse(0));
                    fails.push(j);
                }
                for (i, sp) in elems.iter().enumerate() {
                    if matches!(sp, Pat::Wild) {
                        continue;
                    }
                    self.emit(Instr::Load(src));
                    let ik = self.sh.int_const(i as i64);
                    self.emit(Instr::Const(ik));
                    self.emit(Instr::SeqGet);
                    self.sub_bind(sp, fails);
                }
                if let Some(Some(slot)) = rest {
                    self.emit(Instr::Load(src));
                    self.emit(Instr::ListRest(elems.len() as u16));
                    self.emit(Instr::Store(*slot));
                }
            }
        }
    }

    fn sub(
        &mut self,
        sp: &Pat,
        src: u16,
        fails: &mut Vec<usize>,
        get: impl Fn(()) -> Instr,
    ) {
        if matches!(sp, Pat::Wild) {
            return;
        }
        self.emit(Instr::Load(src));
        self.emit(get(()));
        self.sub_bind(sp, fails);
    }

    /// The sub-value is on top of the stack: bind or test it.
    fn sub_bind(&mut self, sp: &Pat, fails: &mut Vec<usize>) {
        match sp {
            Pat::Bind(slot) => {
                self.emit(Instr::Store(*slot));
            }
            _ => {
                let mark = self.next_temp;
                let t = self.alloc_temp();
                self.emit(Instr::Store(t));
                self.pat(sp, t, fails);
                // keep the temp allocated until the enclosing pattern is done
                // is unnecessary: sub-patterns only read their own temp
                self.next_temp = mark;
            }
        }
    }

    // -------------------------------------------------------- expressions

    fn load_var(&mut self, v: VarRef) {
        match v {
            VarRef::Local(s) => self.emit(Instr::Load(s)),
            VarRef::Upval(i) => self.emit(Instr::LoadUp(i)),
        };
    }

    fn expr(&mut self, e: &ir::Expr) {
        use ir::Expr as E;
        match e {
            E::Const(c) => {
                let k = self.sh.constant(c);
                self.emit(Instr::Const(k));
            }
            E::Bool(true) => {
                self.emit(Instr::PushTrue);
            }
            E::Bool(false) => {
                self.emit(Instr::PushFalse);
            }
            E::Unit => {
                self.emit(Instr::PushUnit);
            }
            E::Var(v) => self.load_var(*v),
            E::Neg(n, x) => {
                self.expr(x);
                self.emit(if *n == Num::I { Instr::NegI } else { Instr::NegF });
            }
            E::Not(x) => {
                self.expr(x);
                self.emit(Instr::NotB);
            }
            E::BitNot(x) => {
                self.expr(x);
                self.emit(Instr::BNot);
            }
            E::Arith(op, n, l, r) => {
                self.expr(l);
                self.expr(r);
                let i = match (n, op) {
                    (Num::I, Arith::Add) => Instr::AddI,
                    (Num::I, Arith::Sub) => Instr::SubI,
                    (Num::I, Arith::Mul) => Instr::MulI,
                    (Num::I, Arith::Div) => Instr::DivI,
                    (Num::I, Arith::Rem) => Instr::RemI,
                    (Num::F, Arith::Add) => Instr::AddF,
                    (Num::F, Arith::Sub) => Instr::SubF,
                    (Num::F, Arith::Mul) => Instr::MulF,
                    (Num::F, Arith::Div) => Instr::DivF,
                    (Num::F, Arith::Rem) => unreachable!("float remainder is rejected"),
                };
                self.emit(i);
            }
            E::Bit(op, l, r) => {
                self.expr(l);
                self.expr(r);
                self.emit(match op {
                    Bit::And => Instr::BAnd,
                    Bit::Or => Instr::BOr,
                    Bit::Xor => Instr::BXor,
                    Bit::Shl => Instr::Shl,
                    Bit::Shr => Instr::Shr,
                });
            }
            E::Cmp(op, l, r) => {
                self.expr(l);
                self.expr(r);
                self.emit(match op {
                    Cmp::Eq => Instr::Eq,
                    Cmp::Ne => Instr::Ne,
                    Cmp::Lt => Instr::Lt,
                    Cmp::Le => Instr::Le,
                    Cmp::Gt => Instr::Gt,
                    Cmp::Ge => Instr::Ge,
                });
            }
            E::Concat(l, r) => {
                self.expr(l);
                self.expr(r);
                self.emit(Instr::Concat);
            }
            E::And(l, r) => {
                self.expr(l);
                let jf = self.emit(Instr::JumpIfFalse(0));
                let d = self.depth;
                self.expr(r);
                let je = self.emit(Instr::Jump(0));
                self.depth = d;
                self.patch_here(jf);
                self.emit(Instr::PushFalse);
                self.patch_here(je);
            }
            E::Or(l, r) => {
                self.expr(l);
                let jt = self.emit(Instr::JumpIfTrue(0));
                let d = self.depth;
                self.expr(r);
                let je = self.emit(Instr::Jump(0));
                self.depth = d;
                self.patch_here(jt);
                self.emit(Instr::PushTrue);
                self.patch_here(je);
            }
            E::Call(f, args) => {
                for a in args {
                    self.expr(a);
                }
                self.emit(Instr::Call(*f, args.len() as u8));
            }
            E::CallBuiltin(b, args) => {
                for a in args {
                    self.expr(a);
                }
                self.emit(Instr::CallBuiltin(*b, args.len() as u8));
            }
            E::CallValue(c, args) => {
                self.expr(c);
                for a in args {
                    self.expr(a);
                }
                self.emit(Instr::CallValue(args.len() as u8));
            }
            E::CallMethod(t, m, recv, args) => {
                self.expr(recv);
                for a in args {
                    self.expr(a);
                }
                self.emit(Instr::CallMethod(*t as u16, *m, args.len() as u8 + 1));
            }
            E::MakeEnum(d, v, args) => {
                if args.is_empty() {
                    self.emit(Instr::MakeEnum(*d, *v, 0));
                } else {
                    for a in args {
                        self.expr(a);
                    }
                    self.emit(Instr::MakeEnum(*d, *v, args.len() as u8));
                }
            }
            E::MakeStruct(d, written, n) => {
                let in_order = written.iter().enumerate().all(|(i, (idx, _))| i == *idx);
                if in_order {
                    for (_, a) in written {
                        self.expr(a);
                    }
                } else {
                    let mark = self.next_temp;
                    let temps: Vec<u16> = (0..*n).map(|_| self.alloc_temp()).collect();
                    for (idx, a) in written {
                        self.expr(a);
                        self.emit(Instr::Store(temps[*idx]));
                    }
                    for t in &temps {
                        self.emit(Instr::Load(*t));
                    }
                    self.next_temp = mark;
                }
                self.emit(Instr::MakeStruct(*d, *n as u8));
            }
            E::List(items) => {
                for a in items {
                    self.expr(a);
                }
                self.emit(Instr::MakeList(items.len() as u32));
            }
            E::Map(entries) => {
                for (k, v) in entries {
                    self.expr(k);
                    self.expr(v);
                }
                self.emit(Instr::MakeMap(entries.len() as u32));
            }
            E::Tuple(items) => {
                for a in items {
                    self.expr(a);
                }
                self.emit(Instr::MakeTuple(items.len() as u8));
            }
            E::Field(x, i) => {
                self.expr(x);
                self.emit(Instr::GetField(*i as u16));
            }
            E::Index(a, i) => {
                self.expr(a);
                self.expr(i);
                self.emit(Instr::IndexGet);
            }
            E::Lambda(f, caps) => {
                for c in caps {
                    self.load_var(*c);
                }
                self.emit(Instr::MakeClosure(*f, caps.len() as u16));
            }
            E::If(c, then, els) => {
                self.expr(c);
                let jf = self.emit(Instr::JumpIfFalse(0));
                let d = self.depth;
                self.block_value(then);
                let je = self.emit(Instr::Jump(0));
                self.depth = d;
                self.patch_here(jf);
                match els {
                    Some(e) => self.expr(e),
                    None => {
                        self.emit(Instr::PushUnit);
                    }
                }
                self.patch_here(je);
            }
            E::Block(b) => self.block_value(b),
            E::Match(s, arms) => self.match_expr(s, arms),
        }
    }

    fn match_expr(&mut self, scrut: &ir::Expr, arms: &[ir::Arm]) {
        let mark = self.next_temp;
        let t = self.alloc_temp();
        self.expr(scrut);
        self.emit(Instr::Store(t));
        let d = self.depth;
        let mut ends = Vec::new();
        for arm in arms {
            let mut fails = Vec::new();
            self.pat(&arm.pat, t, &mut fails);
            if let Some(g) = &arm.guard {
                self.expr(g);
                let j = self.emit(Instr::JumpIfFalse(0));
                fails.push(j);
            }
            self.expr(&arm.body);
            ends.push(self.emit(Instr::Jump(0)));
            self.depth = d;
            for f in fails {
                self.patch_here(f);
            }
        }
        self.emit(Instr::NoMatch);
        self.depth = d + 1;
        for e in ends {
            self.patch_here(e);
        }
        self.next_temp = mark;
    }
}
