//! The bytecode: instruction set and the compiled-program container.

use crate::builtins::Builtin;
use crate::value::Value;
use std::rc::Rc;

/// One VM instruction. Operands are compile-time constants.
#[derive(Copy, Clone, Debug, PartialEq)]
pub enum Instr {
    /// Push constant `k`.
    Const(u32),
    /// Push `true`.
    PushTrue,
    /// Push `false`.
    PushFalse,
    /// Push the unit value.
    PushUnit,
    /// Push local slot `i`.
    Load(u16),
    /// Pop into local slot `i`.
    Store(u16),
    /// Push upvalue `i` of the running closure.
    LoadUp(u16),
    /// Increment the integer in local slot `i`.
    IncLocal(u16),
    /// Discard the top value.
    Pop,
    /// Pop `n` values as upvalues and push a closure over function `f`.
    MakeClosure(u32, u16),
    /// Call user function `f` with `argc` arguments.
    Call(u32, u8),
    /// Call the closure below `argc` arguments.
    CallValue(u8),
    /// Call a built-in with `argc` arguments.
    CallBuiltin(Builtin, u8),
    /// Call method `m` of trait `t`; `argc` includes the receiver.
    CallMethod(u16, u16, u8),
    /// Return the top value.
    Ret,
    /// Integer addition (wrapping).
    AddI,
    /// Integer subtraction.
    SubI,
    /// Integer multiplication.
    MulI,
    /// Integer division.
    DivI,
    /// Integer remainder.
    RemI,
    /// Integer negation.
    NegI,
    /// Bitwise complement.
    BNot,
    /// Bitwise and.
    BAnd,
    /// Bitwise or.
    BOr,
    /// Bitwise xor.
    BXor,
    /// Shift left.
    Shl,
    /// Arithmetic shift right.
    Shr,
    /// Float addition.
    AddF,
    /// Float subtraction.
    SubF,
    /// Float multiplication.
    MulF,
    /// Float division.
    DivF,
    /// Float negation.
    NegF,
    /// Logical not.
    NotB,
    /// Structural equality.
    Eq,
    /// Structural inequality.
    Ne,
    /// Less than.
    Lt,
    /// Less or equal.
    Le,
    /// Greater than.
    Gt,
    /// Greater or equal.
    Ge,
    /// `++` on strings or lists.
    Concat,
    /// Unconditional jump.
    Jump(u32),
    /// Pop a bool; jump if false.
    JumpIfFalse(u32),
    /// Pop a bool; jump if true.
    JumpIfTrue(u32),
    /// Pop `n` values into a list.
    MakeList(u32),
    /// Pop `2n` values into a map.
    MakeMap(u32),
    /// Pop `n` values into a tuple.
    MakeTuple(u8),
    /// Pop `n` values into a struct of declaration `d`.
    MakeStruct(u32, u8),
    /// Pop `n` payload values into variant `v` of enum `d`.
    MakeEnum(u32, u16, u8),
    /// Pop a struct, push field `i`.
    GetField(u16),
    /// Pop an enum value, push payload `i`.
    GetPayload(u16),
    /// Pop a tuple, push component `i`.
    GetTuple(u16),
    /// Pop an index and a container; push the element.
    IndexGet,
    /// Pop a value, an index and a container; store.
    IndexSet,
    /// Pop an enum value; push whether it is variant `v`.
    IsVariant(u16),
    /// Pop a list or string; push its length.
    SeqLen,
    /// Pop an index and a sequence; push the element.
    SeqGet,
    /// Pop a list; push a new list of its elements from index `i`.
    ListRest(u16),
    /// Panic: no match arm applied.
    NoMatch,
}

/// A compiled function.
#[derive(Debug)]
pub struct FuncCode {
    /// Name (debugging).
    pub name: String,
    /// The code.
    pub code: Vec<Instr>,
    /// Number of parameters.
    pub nparams: u32,
    /// Number of local slots (including parameters).
    pub nslots: u32,
}

/// A whole compiled program.
#[derive(Debug)]
pub struct CompiledProgram {
    /// The constant pool.
    pub consts: Vec<Value>,
    /// Every function, indexed by function id.
    pub funcs: Vec<FuncCode>,
    /// `impl_table[trait][ctor]` is the method table of that impl.
    pub impl_table: Vec<Vec<Option<Rc<[u32]>>>>,
    /// Pre-built nullary enum values: `nullary[decl][variant]`.
    pub nullary: Vec<Vec<Value>>,
    /// The function id of `main`.
    pub main: u32,
}
