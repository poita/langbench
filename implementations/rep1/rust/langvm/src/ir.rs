//! The checked, resolved intermediate tree that the type checker produces and
//! the bytecode compiler consumes. Every name is already an id.

use crate::builtins::Builtin;
use crate::types::{DeclId, FnId, TraitId};
use std::rc::Rc;

/// Where a variable lives, relative to the function being compiled.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum VarRef {
    /// A local slot of the running frame.
    Local(u16),
    /// An upvalue of the running closure.
    Upval(u16),
}

/// A literal constant.
#[derive(Clone, Debug)]
pub enum Const {
    /// Integer.
    Int(i64),
    /// Float.
    Float(f64),
    /// Character.
    Char(char),
    /// String.
    Str(Rc<Vec<char>>),
    /// Boolean (patterns only).
    Bool(bool),
}

/// Numeric kind chosen by the checker for arithmetic.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum Num {
    /// `Int`
    I,
    /// `Float`
    F,
}

/// Arithmetic operators.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum Arith {
    /// `+`
    Add,
    /// `-`
    Sub,
    /// `*`
    Mul,
    /// `/`
    Div,
    /// `%`
    Rem,
}

/// Bitwise operators.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum Bit {
    /// `&`
    And,
    /// `|`
    Or,
    /// `^`
    Xor,
    /// `<<`
    Shl,
    /// `>>`
    Shr,
}

/// Comparison operators.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum Cmp {
    /// `==`
    Eq,
    /// `!=`
    Ne,
    /// `<`
    Lt,
    /// `<=`
    Le,
    /// `>`
    Gt,
    /// `>=`
    Ge,
}

/// A checked expression.
#[derive(Clone, Debug)]
pub enum Expr {
    /// A constant.
    Const(Const),
    /// A boolean literal.
    Bool(bool),
    /// The unit value.
    Unit,
    /// A variable read.
    Var(VarRef),
    /// Negation.
    Neg(Num, Box<Expr>),
    /// Logical not.
    Not(Box<Expr>),
    /// Bitwise complement.
    BitNot(Box<Expr>),
    /// Arithmetic.
    Arith(Arith, Num, Box<Expr>, Box<Expr>),
    /// Bitwise operation.
    Bit(Bit, Box<Expr>, Box<Expr>),
    /// Comparison.
    Cmp(Cmp, Box<Expr>, Box<Expr>),
    /// `++`
    Concat(Box<Expr>, Box<Expr>),
    /// `&&`
    And(Box<Expr>, Box<Expr>),
    /// `||`
    Or(Box<Expr>, Box<Expr>),
    /// Direct call of a user function.
    Call(FnId, Vec<Expr>),
    /// Call of a built-in.
    CallBuiltin(Builtin, Vec<Expr>),
    /// Call of a closure value.
    CallValue(Box<Expr>, Vec<Expr>),
    /// Trait method call: trait, method index, receiver, arguments.
    CallMethod(TraitId, u16, Box<Expr>, Vec<Expr>),
    /// Enum value construction.
    MakeEnum(DeclId, u16, Vec<Expr>),
    /// Struct construction: field values in written order paired with the
    /// field's declaration index; total number of fields.
    MakeStruct(DeclId, Vec<(usize, Expr)>, usize),
    /// List literal.
    List(Vec<Expr>),
    /// Map literal.
    Map(Vec<(Expr, Expr)>),
    /// Tuple literal.
    Tuple(Vec<Expr>),
    /// Field read.
    Field(Box<Expr>, usize),
    /// Index read.
    Index(Box<Expr>, Box<Expr>),
    /// Closure creation with the captured variables.
    Lambda(FnId, Vec<VarRef>),
    /// `if`
    If(Box<Expr>, Box<Block>, Option<Box<Expr>>),
    /// `match`
    Match(Box<Expr>, Vec<Arm>),
    /// A block as an expression.
    Block(Box<Block>),
}

/// A block.
#[derive(Clone, Debug, Default)]
pub struct Block {
    /// Statements.
    pub stmts: Vec<Stmt>,
    /// Trailing expression.
    pub tail: Option<Expr>,
}

/// A match arm.
#[derive(Clone, Debug)]
pub struct Arm {
    /// The pattern.
    pub pat: Pat,
    /// The guard.
    pub guard: Option<Expr>,
    /// The body.
    pub body: Expr,
}

/// A statement.
#[derive(Clone, Debug)]
pub enum Stmt {
    /// `let pat = e;`
    Let(Pat, Expr),
    /// Store into a local slot (`var` declaration or assignment).
    Set(u16, Expr),
    /// `a[i] = e;`
    SetIndex(Expr, Expr, Expr),
    /// An expression statement.
    Expr(Expr),
    /// `while`
    While(Expr, Block),
    /// `for` over a list or string: pattern, sequence, body.
    ForSeq(Pat, Expr, Block),
    /// `for` over a range: pattern, low, high, body.
    ForRange(Pat, Expr, Expr, Block),
    /// `return`
    Return(Option<Expr>),
    /// `break`
    Break,
    /// `continue`
    Continue,
}

/// A checked pattern.
#[derive(Clone, Debug)]
pub enum Pat {
    /// Matches anything.
    Wild,
    /// Binds to a slot.
    Bind(u16),
    /// A literal.
    Lit(Const),
    /// An enum variant with payload patterns.
    Variant(DeclId, u16, Vec<Pat>),
    /// A tuple.
    Tuple(Vec<Pat>),
    /// A struct: one pattern per field in declaration order.
    Struct(Vec<Pat>),
    /// A list pattern: elements, and the rest (`Some(Some(slot))` binds it).
    List(Vec<Pat>, Option<Option<u16>>),
}

/// A checked function body.
#[derive(Clone, Debug)]
pub struct Func {
    /// Name, for debugging.
    pub name: String,
    /// Number of parameters (including `self`).
    pub nparams: usize,
    /// Number of local slots used by the checker.
    pub nslots: usize,
    /// Number of upvalues (lambdas only).
    pub nupvals: usize,
    /// The body.
    pub body: Block,
}
