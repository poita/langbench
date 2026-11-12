//! The syntax tree produced by the parser.

use crate::diag::Pos;
use std::rc::Rc;

/// An identifier with its position.
#[derive(Clone, Debug)]
pub struct Ident {
    /// The name.
    pub name: String,
    /// Where it appears.
    pub pos: Pos,
}

/// `name` or `qual::name`.
#[derive(Clone, Debug)]
pub struct Path {
    /// The module/trait qualifier, if any.
    pub qual: Option<Ident>,
    /// The final name.
    pub name: Ident,
}

impl Path {
    /// The position of the path's first token.
    pub fn pos(&self) -> Pos {
        self.qual.as_ref().map_or(self.name.pos, |q| q.pos)
    }
}

/// A type as written in the source.
#[derive(Clone, Debug)]
pub struct TypeExpr {
    /// Position of the first token.
    pub pos: Pos,
    /// The form.
    pub kind: TypeKind,
}

/// The forms of written types.
#[derive(Clone, Debug)]
pub enum TypeKind {
    /// `[T]`
    List(Box<TypeExpr>),
    /// `#[K: V]`
    Map(Box<TypeExpr>, Box<TypeExpr>),
    /// `(A, B, ...)`
    Tuple(Vec<TypeExpr>),
    /// `fn(A, B) -> R`
    Fn(Vec<TypeExpr>, Option<Box<TypeExpr>>),
    /// A (possibly qualified) name with optional type arguments.
    Path(Path, Vec<TypeExpr>),
}

/// A generic parameter with its bounds.
#[derive(Clone, Debug)]
pub struct GenParam {
    /// The parameter name.
    pub name: Ident,
    /// Its trait bounds.
    pub bounds: Vec<Path>,
}

/// A typed parameter.
#[derive(Clone, Debug)]
pub struct Param {
    /// The parameter name.
    pub name: Ident,
    /// Its declared type.
    pub ty: TypeExpr,
}

/// A function declaration.
#[derive(Clone, Debug)]
pub struct FnDecl {
    /// Position of the `fn` keyword.
    pub pos: Pos,
    /// Whether declared `pub`.
    pub is_pub: bool,
    /// The function name.
    pub name: Ident,
    /// Type parameters.
    pub generics: Vec<GenParam>,
    /// Parameters.
    pub params: Vec<Param>,
    /// Declared return type.
    pub ret: Option<TypeExpr>,
    /// The body.
    pub body: Block,
}

/// A struct declaration.
#[derive(Clone, Debug)]
pub struct StructDecl {
    /// Position of the `struct` keyword.
    pub pos: Pos,
    /// Whether declared `pub`.
    pub is_pub: bool,
    /// The struct name.
    pub name: Ident,
    /// Type parameters (no bounds).
    pub generics: Vec<GenParam>,
    /// Fields in declaration order.
    pub fields: Vec<Param>,
}

/// An enum variant.
#[derive(Clone, Debug)]
pub struct Variant {
    /// Variant name.
    pub name: Ident,
    /// Payload types.
    pub payload: Vec<TypeExpr>,
}

/// An enum declaration.
#[derive(Clone, Debug)]
pub struct EnumDecl {
    /// Position of the `enum` keyword.
    pub pos: Pos,
    /// Whether declared `pub`.
    pub is_pub: bool,
    /// The enum name.
    pub name: Ident,
    /// Type parameters (no bounds).
    pub generics: Vec<GenParam>,
    /// Variants.
    pub variants: Vec<Variant>,
}

/// A method signature in a trait or impl.
#[derive(Clone, Debug)]
pub struct MethodDecl {
    /// Position of the `fn` keyword.
    pub pos: Pos,
    /// Method name.
    pub name: Ident,
    /// Parameters after `self`.
    pub params: Vec<Param>,
    /// Declared return type.
    pub ret: Option<TypeExpr>,
    /// Body (always present in impls; optional in traits).
    pub body: Option<Block>,
}

/// A trait declaration.
#[derive(Clone, Debug)]
pub struct TraitDecl {
    /// Position of the `trait` keyword.
    pub pos: Pos,
    /// Whether declared `pub`.
    pub is_pub: bool,
    /// The trait name.
    pub name: Ident,
    /// Methods in declaration order.
    pub methods: Vec<MethodDecl>,
}

/// An impl declaration.
#[derive(Clone, Debug)]
pub struct ImplDecl {
    /// Position of the `impl` keyword.
    pub pos: Pos,
    /// Impl type parameters.
    pub generics: Vec<GenParam>,
    /// The implemented trait.
    pub trait_ref: Path,
    /// The head type after `for`.
    pub head: TypeExpr,
    /// The methods.
    pub methods: Vec<MethodDecl>,
}

/// A `use` declaration.
#[derive(Clone, Debug)]
pub struct UseDecl {
    /// Position of the `use` keyword.
    pub pos: Pos,
    /// The imported module name.
    pub module: Ident,
    /// The alias, if any.
    pub alias: Option<Ident>,
}

/// A top-level item.
#[derive(Clone, Debug)]
pub enum Item {
    /// `use m;`
    Use(UseDecl),
    /// A function.
    Fn(Rc<FnDecl>),
    /// A struct.
    Struct(Rc<StructDecl>),
    /// An enum.
    Enum(Rc<EnumDecl>),
    /// A trait.
    Trait(Rc<TraitDecl>),
    /// An impl.
    Impl(Rc<ImplDecl>),
}

/// A parsed module.
#[derive(Clone, Debug, Default)]
pub struct Module {
    /// The items in source order.
    pub items: Vec<Item>,
}

/// A block: statements plus an optional trailing expression.
#[derive(Clone, Debug)]
pub struct Block {
    /// Position of the opening brace.
    pub pos: Pos,
    /// The statements.
    pub stmts: Vec<Stmt>,
    /// The trailing expression.
    pub tail: Option<Box<Expr>>,
}

/// A statement.
#[derive(Clone, Debug)]
pub struct Stmt {
    /// Position of the first token.
    pub pos: Pos,
    /// The form.
    pub kind: StmtKind,
}

/// Statement forms.
#[derive(Clone, Debug)]
pub enum StmtKind {
    /// `let pat [: T] = e;`
    Let(Pat, Option<TypeExpr>, Expr),
    /// `var x [: T] = e;`
    Var(Ident, Option<TypeExpr>, Expr),
    /// `target = e;`
    Assign(Expr, Expr),
    /// An expression statement.
    Expr(Expr),
    /// `return [e];`
    Return(Option<Expr>),
    /// `while c { }`
    While(Expr, Block),
    /// `for p in e [.. e2] { }`
    For(Pat, Expr, Option<Expr>, Block),
    /// `break;`
    Break,
    /// `continue;`
    Continue,
}

/// An expression.
#[derive(Clone, Debug)]
pub struct Expr {
    /// Position of the first token (parentheses do not count).
    pub pos: Pos,
    /// The form.
    pub kind: ExprKind,
}

/// A lambda parameter.
#[derive(Clone, Debug)]
pub struct LParam {
    /// Name.
    pub name: Ident,
    /// Optional annotation.
    pub ty: Option<TypeExpr>,
}

/// A lambda expression.
#[derive(Clone, Debug)]
pub struct Lambda {
    /// Parameters.
    pub params: Vec<LParam>,
    /// Declared return type.
    pub ret: Option<TypeExpr>,
    /// The body (an `ExprKind::Block` when written with braces).
    pub body: Expr,
}

/// A match arm.
#[derive(Clone, Debug)]
pub struct Arm {
    /// The pattern.
    pub pat: Pat,
    /// Optional guard.
    pub guard: Option<Expr>,
    /// The body.
    pub body: Expr,
}

/// Unary operators.
#[derive(Copy, Clone, PartialEq, Eq, Debug)]
pub enum UnOp {
    /// `-`
    Neg,
    /// `!`
    Not,
    /// `~`
    BitNot,
}

/// Binary operators.
#[derive(Copy, Clone, PartialEq, Eq, Debug)]
pub enum BinOp {
    /// `||`
    Or,
    /// `&&`
    And,
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
    /// `|`
    BitOr,
    /// `^`
    BitXor,
    /// `&`
    BitAnd,
    /// `<<`
    Shl,
    /// `>>`
    Shr,
    /// `+`
    Add,
    /// `-`
    Sub,
    /// `++`
    Concat,
    /// `*`
    Mul,
    /// `/`
    Div,
    /// `%`
    Rem,
}

/// Expression forms.
#[derive(Clone, Debug)]
pub enum ExprKind {
    /// Integer literal.
    Int(i64),
    /// Float literal.
    Float(f64),
    /// String literal.
    Str(Rc<Vec<char>>),
    /// Character literal.
    Char(char),
    /// `true` / `false`.
    Bool(bool),
    /// `self`.
    SelfVal,
    /// A value path.
    Path(Path),
    /// `Path.{ f: e, ... }`
    StructLit(Path, Vec<(Ident, Expr)>),
    /// Prefix operator.
    Unary(UnOp, Box<Expr>),
    /// Binary operator.
    Binary(BinOp, Box<Expr>, Box<Expr>),
    /// `callee(args)`
    Call(Box<Expr>, Vec<Expr>),
    /// `a[i]`
    Index(Box<Expr>, Box<Expr>),
    /// `e.f`
    Field(Box<Expr>, Ident),
    /// `recv.m(args)`
    MethodCall(Box<Expr>, Ident, Vec<Expr>),
    /// `[a, b]`
    List(Vec<Expr>),
    /// `#[k: v, ...]`
    Map(Vec<(Expr, Expr)>),
    /// `(a, b, ...)`
    Tuple(Vec<Expr>),
    /// A lambda.
    Lambda(Rc<Lambda>),
    /// `if c { } [else ...]`; the else part is a block or another `if`.
    If(Box<Expr>, Box<Block>, Option<Box<Expr>>),
    /// `match s { arms }`
    Match(Box<Expr>, Vec<Arm>),
    /// A block in expression position.
    Block(Box<Block>),
}

/// A pattern.
#[derive(Clone, Debug)]
pub struct Pat {
    /// Position of the first token.
    pub pos: Pos,
    /// The form.
    pub kind: PatKind,
}

/// Pattern forms.
#[derive(Clone, Debug)]
pub enum PatKind {
    /// `_`
    Wild,
    /// A bare identifier: a binding, or a zero-payload variant.
    Ident(String),
    /// Integer literal pattern (already negated when written `-n`).
    Int(i64),
    /// Float literal pattern (always rejected later).
    Float,
    /// String literal.
    Str(Rc<Vec<char>>),
    /// Character literal.
    Char(char),
    /// `true`/`false`.
    Bool(bool),
    /// `(p1, p2, ...)`
    Tuple(Vec<Pat>),
    /// `[p1, ..., ..rest]`; `rest` is `Some(None)` for `..` and
    /// `Some(Some(name))` for `..name`.
    List(Vec<Pat>, Option<Option<Ident>>),
    /// `P.{ f: p, f2, .. }`
    Struct(Path, Vec<(Ident, Option<Pat>)>, bool),
    /// `C`, `m::C` or `C(p, ...)`; `None` means no parenthesised list.
    Variant(Path, Option<Vec<Pat>>),
}
