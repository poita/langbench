// Package ast defines the syntax tree of a Vellum module. The checker
// annotates nodes in place with the semantic objects they resolve to, and the
// bytecode compiler reads those annotations.
package ast

import (
	"langvm/diag"
	"langvm/types"
)

// Pos is a source position.
type Pos = diag.Pos

// Ident is a name with its position.
type Ident struct {
	Name string
	Pos  Pos
}

// Module is a parsed module body.
type Module struct {
	Name  string
	Items []Item
}

// ---------------------------------------------------------------- items

// Item is a top-level declaration.
type Item interface{ ItemPos() Pos }

// UseDecl is `use m [as k];`.
type UseDecl struct {
	Pos   Pos
	Name  Ident
	Alias *Ident
}

// GenParam is a generic parameter with its bounds.
type GenParam struct {
	Name   Ident
	Bounds []*TraitRef
}

// TraitRef is `Tr` or `m::Tr`.
type TraitRef struct {
	Pos  Pos
	Qual *Ident
	Name Ident
}

// Param is a typed function parameter.
type Param struct {
	Name Ident
	Type Type
}

// FnDecl is a function declaration.
type FnDecl struct {
	Pos      Pos
	Pub      bool
	Name     Ident
	Generics []*GenParam
	Params   []*Param
	Ret      Type // nil means Unit
	Body     *Block
	Func     *types.Func
}

// FieldDecl is a struct field declaration.
type FieldDecl struct {
	Name Ident
	Type Type
}

// StructDecl is a struct declaration.
type StructDecl struct {
	Pos      Pos
	Pub      bool
	Name     Ident
	Generics []*GenParam
	Fields   []*FieldDecl
	Decl     *types.Decl
}

// VariantDecl is one enum variant.
type VariantDecl struct {
	Name    Ident
	Payload []Type
}

// EnumDecl is an enum declaration.
type EnumDecl struct {
	Pos      Pos
	Pub      bool
	Name     Ident
	Generics []*GenParam
	Variants []*VariantDecl
	Decl     *types.Decl
}

// MethodDecl is a trait method signature (Body may be nil) or an impl method.
type MethodDecl struct {
	Pos    Pos // the `fn` keyword
	Name   Ident
	Params []*Param // excluding self
	Ret    Type
	Body   *Block
	Func   *types.Func
}

// TraitDecl is a trait declaration.
type TraitDecl struct {
	Pos     Pos
	Pub     bool
	Name    Ident
	Methods []*MethodDecl
	Trait   *types.Trait
}

// ImplDecl is an impl declaration.
type ImplDecl struct {
	Pos      Pos
	Generics []*GenParam
	Trait    *TraitRef
	Head     Type
	Methods  []*MethodDecl
	Impl     *types.Impl
}

func (d *UseDecl) ItemPos() Pos    { return d.Pos }
func (d *FnDecl) ItemPos() Pos     { return d.Pos }
func (d *StructDecl) ItemPos() Pos { return d.Pos }
func (d *EnumDecl) ItemPos() Pos   { return d.Pos }
func (d *TraitDecl) ItemPos() Pos  { return d.Pos }
func (d *ImplDecl) ItemPos() Pos   { return d.Pos }

// ---------------------------------------------------------------- types

// Type is a written type.
type Type interface{ TypePos() Pos }

// ListType is `[T]`.
type ListType struct {
	Pos  Pos
	Elem Type
}

// MapType is `#[K: V]`.
type MapType struct {
	Pos  Pos
	K, V Type
}

// TupleType is `(T1, T2, ...)`.
type TupleType struct {
	Pos   Pos
	Elems []Type
}

// FnType is `fn(T1, ...) -> R`.
type FnType struct {
	Pos    Pos
	Params []Type
	Ret    Type // nil means Unit
}

// PathType is `N`, `m::N`, optionally with type arguments.
type PathType struct {
	Pos     Pos
	Qual    *Ident
	Name    Ident
	Args    []Type
	HasArgs bool
}

func (t *ListType) TypePos() Pos  { return t.Pos }
func (t *MapType) TypePos() Pos   { return t.Pos }
func (t *TupleType) TypePos() Pos { return t.Pos }
func (t *FnType) TypePos() Pos    { return t.Pos }
func (t *PathType) TypePos() Pos  { return t.Pos }

// ---------------------------------------------------------------- statements

// Stmt is a statement.
type Stmt interface{ StmtPos() Pos }

// Block is `{ stmts [trailing] }`. It is also an expression.
type Block struct {
	Pos      Pos
	Stmts    []Stmt
	Trailing Expr

	divKnown, div bool
}

// LetStmt is `let p [: T] = e;`.
type LetStmt struct {
	Pos  Pos
	Pat  Pattern
	Type Type
	Init Expr
}

// VarStmt is `var x [: T] = e;`.
type VarStmt struct {
	Pos   Pos
	Name  Ident
	Type  Type
	Init  Expr
	Local *types.Local
}

// AssignStmt is `target = value;`.
type AssignStmt struct {
	Pos    Pos
	Target Expr
	Value  Expr
	Local  *types.Local // for an identifier target
}

// ExprStmt is an expression evaluated for effect.
type ExprStmt struct{ X Expr }

// ReturnStmt is `return [e];`.
type ReturnStmt struct {
	Pos Pos
	X   Expr
}

// WhileStmt is `while c { ... }`.
type WhileStmt struct {
	Pos  Pos
	Cond Expr
	Body *Block
}

// ForStmt is `for p in e [.. e2] { ... }`.
type ForStmt struct {
	Pos  Pos
	Pat  Pattern
	Iter Expr
	End  Expr // non-nil for a range loop
	Body *Block
}

// BreakStmt is `break;`.
type BreakStmt struct{ Pos Pos }

// ContinueStmt is `continue;`.
type ContinueStmt struct{ Pos Pos }

func (s *LetStmt) StmtPos() Pos      { return s.Pos }
func (s *VarStmt) StmtPos() Pos      { return s.Pos }
func (s *AssignStmt) StmtPos() Pos   { return s.Pos }
func (s *ExprStmt) StmtPos() Pos     { return s.X.ExprPos() }
func (s *ReturnStmt) StmtPos() Pos   { return s.Pos }
func (s *WhileStmt) StmtPos() Pos    { return s.Pos }
func (s *ForStmt) StmtPos() Pos      { return s.Pos }
func (s *BreakStmt) StmtPos() Pos    { return s.Pos }
func (s *ContinueStmt) StmtPos() Pos { return s.Pos }

// ---------------------------------------------------------------- expressions

// Expr is an expression.
type Expr interface{ ExprPos() Pos }

// IntLit is an integer literal.
type IntLit struct {
	Pos Pos
	Val int64
}

// FloatLit is a float literal.
type FloatLit struct {
	Pos Pos
	Val float64
}

// StrLit is a string literal.
type StrLit struct {
	Pos Pos
	Val []rune
}

// CharLit is a character literal.
type CharLit struct {
	Pos Pos
	Val rune
}

// BoolLit is `true` or `false`.
type BoolLit struct {
	Pos Pos
	Val bool
}

// SelfExpr is `self`.
type SelfExpr struct {
	Pos   Pos
	Local *types.Local
}

// RefKind says what a PathExpr resolved to.
type RefKind uint8

// Kinds of resolution of a value path.
const (
	RefNone RefKind = iota
	RefLocal
	RefFunc
	RefVariant
	RefTraitMethod
)

// PathExpr is a value path `x` or `m::x`.
type PathExpr struct {
	Pos     Pos // first token
	Qual    *Ident
	Name    Ident
	Kind    RefKind
	Local   *types.Local
	Func    *types.Func
	Variant *types.Variant
	Trait   *types.Trait // RefTraitMethod
	Method  int
}

// UnaryExpr is a prefix operator application.
type UnaryExpr struct {
	Pos   Pos
	Op    string // "-", "!", "~"
	X     Expr
	Float bool // "-" on a Float
}

// BinaryExpr is a binary operator application.
type BinaryExpr struct {
	Pos   Pos // position of the left operand
	Op    string
	OpPos Pos
	L, R  Expr
	Float bool // arithmetic on Floats
	List  bool // "++" on lists
}

// CallKind says how a call is performed.
type CallKind uint8

// Kinds of call.
const (
	CallNone CallKind = iota
	CallFunc
	CallBuiltin
	CallVariant
	CallValue
	CallMethod
)

// CallExpr is `callee(args)`. For `Tr::m(recv, ...)` the checker sets Kind to
// CallMethod and Callee remains the path.
type CallExpr struct {
	Pos     Pos
	Callee  Expr
	Args    []Expr
	Kind    CallKind
	Func    *types.Func
	Variant *types.Variant
	Trait   *types.Trait
	Method  int
}

// MethodCallExpr is `recv.m(args)`.
type MethodCallExpr struct {
	Pos    Pos // the receiver's first token
	Recv   Expr
	Name   Ident
	Args   []Expr
	Trait  *types.Trait
	Method int
}

// IndexExpr is `a[i]`.
type IndexExpr struct {
	Pos  Pos
	X, I Expr
}

// FieldExpr is `e.f`.
type FieldExpr struct {
	Pos   Pos
	X     Expr
	Name  Ident
	Index int
}

// FieldInit is `f: e` in a struct literal.
type FieldInit struct {
	Name  Ident
	Value Expr
}

// StructLit is `P.{ f: e, ... }`.
type StructLit struct {
	Pos    Pos
	Path   *PathExpr
	Fields []*FieldInit
	Decl   *types.Decl
	Order  []int // for each written field, its declaration index
}

// ListLit is `[a, b, ...]`.
type ListLit struct {
	Pos   Pos
	Elems []Expr
}

// MapEntry is `k: v`.
type MapEntry struct{ K, V Expr }

// MapLit is `#[k: v, ...]`.
type MapLit struct {
	Pos     Pos
	Entries []*MapEntry
}

// TupleLit is `(a, b, ...)`.
type TupleLit struct {
	Pos   Pos
	Elems []Expr
}

// LParam is a lambda parameter.
type LParam struct {
	Name  Ident
	Type  Type
	Local *types.Local
}

// Lambda is a closure expression.
type Lambda struct {
	Pos    Pos
	Params []*LParam
	Ret    Type
	Body   Expr // a *Block or an expression
	Func   *types.Func
}

// IfExpr is `if c b1 [else b2]`.
type IfExpr struct {
	Pos  Pos
	Cond Expr
	Then *Block
	Else Expr // *Block, *IfExpr or nil
}

// Arm is a match arm.
type Arm struct {
	Pat   Pattern
	Guard Expr
	Body  Expr // *Block or expression
}

// MatchExpr is `match s { arms }`.
type MatchExpr struct {
	Pos  Pos
	Scr  Expr
	Arms []*Arm
}

func (e *IntLit) ExprPos() Pos         { return e.Pos }
func (e *FloatLit) ExprPos() Pos       { return e.Pos }
func (e *StrLit) ExprPos() Pos         { return e.Pos }
func (e *CharLit) ExprPos() Pos        { return e.Pos }
func (e *BoolLit) ExprPos() Pos        { return e.Pos }
func (e *SelfExpr) ExprPos() Pos       { return e.Pos }
func (e *PathExpr) ExprPos() Pos       { return e.Pos }
func (e *UnaryExpr) ExprPos() Pos      { return e.Pos }
func (e *BinaryExpr) ExprPos() Pos     { return e.Pos }
func (e *CallExpr) ExprPos() Pos       { return e.Pos }
func (e *MethodCallExpr) ExprPos() Pos { return e.Pos }
func (e *IndexExpr) ExprPos() Pos      { return e.Pos }
func (e *FieldExpr) ExprPos() Pos      { return e.Pos }
func (e *StructLit) ExprPos() Pos      { return e.Pos }
func (e *ListLit) ExprPos() Pos        { return e.Pos }
func (e *MapLit) ExprPos() Pos         { return e.Pos }
func (e *TupleLit) ExprPos() Pos       { return e.Pos }
func (e *Lambda) ExprPos() Pos         { return e.Pos }
func (e *IfExpr) ExprPos() Pos         { return e.Pos }
func (e *MatchExpr) ExprPos() Pos      { return e.Pos }
func (e *Block) ExprPos() Pos          { return e.Pos }

// ---------------------------------------------------------------- patterns

// Pattern is a pattern.
type Pattern interface{ PatPos() Pos }

// WildPat is `_`.
type WildPat struct{ Pos Pos }

// IdentPat is a bare identifier: a binding, or a 0-payload variant. The
// checker sets Variant in the latter case and Local in the former.
type IdentPat struct {
	Pos     Pos
	Name    string
	Variant *types.Variant
	Local   *types.Local
}

// LitKind is the kind of a literal pattern.
type LitKind uint8

// Literal pattern kinds.
const (
	LitInt LitKind = iota
	LitFloat
	LitStr
	LitChar
	LitBool
)

// LitPat is a literal pattern.
type LitPat struct {
	Pos  Pos
	Kind LitKind
	Int  int64 // int (already negated), char, bool (0/1)
	Str  []rune
}

// TuplePat is `(p1, p2, ...)`.
type TuplePat struct {
	Pos   Pos
	Elems []Pattern
}

// ListPat is `[p1, ..., ..rest]`.
type ListPat struct {
	Pos     Pos
	Elems   []Pattern
	HasRest bool
	Rest    *Ident // optional name
	Local   *types.Local
}

// FieldPat is `f` or `f: p` in a struct pattern.
type FieldPat struct {
	Name  Ident
	Pat   Pattern // nil for shorthand
	Local *types.Local
	Index int // declaration index of the field
}

// StructPat is `P.{ f: p, ..., .. }`.
type StructPat struct {
	Pos     Pos
	Path    *PathExpr
	Fields  []*FieldPat
	HasRest bool
	Decl    *types.Decl
}

// VariantPat is `C(p1, ...)` or `m::C`.
type VariantPat struct {
	Pos     Pos
	Path    *PathExpr
	Args    []Pattern
	Variant *types.Variant
}

func (p *WildPat) PatPos() Pos    { return p.Pos }
func (p *IdentPat) PatPos() Pos   { return p.Pos }
func (p *LitPat) PatPos() Pos     { return p.Pos }
func (p *TuplePat) PatPos() Pos   { return p.Pos }
func (p *ListPat) PatPos() Pos    { return p.Pos }
func (p *StructPat) PatPos() Pos  { return p.Pos }
func (p *VariantPat) PatPos() Pos { return p.Pos }

// Diverges reports whether the block diverges (SPEC.md section 11.6).
func (b *Block) Diverges() bool {
	if !b.divKnown {
		b.divKnown = true
		b.div = false
		for _, s := range b.Stmts {
			if StmtDiverges(s) {
				b.div = true
				break
			}
		}
		if !b.div && b.Trailing != nil {
			b.div = ExprDiverges(b.Trailing)
		}
	}
	return b.div
}

// StmtDiverges reports whether control cannot flow past the statement.
func StmtDiverges(s Stmt) bool {
	switch s := s.(type) {
	case *ReturnStmt, *BreakStmt, *ContinueStmt:
		return true
	case *LetStmt:
		return ExprDiverges(s.Init)
	case *VarStmt:
		return ExprDiverges(s.Init)
	case *AssignStmt:
		return ExprDiverges(s.Value)
	case *ExprStmt:
		return ExprDiverges(s.X)
	}
	return false
}

// ExprDiverges reports whether the expression diverges.
func ExprDiverges(e Expr) bool {
	switch e := e.(type) {
	case *Block:
		return e.Diverges()
	case *IfExpr:
		if e.Else == nil {
			return false
		}
		return e.Then.Diverges() && ExprDiverges(e.Else)
	case *MatchExpr:
		if len(e.Arms) == 0 {
			return false
		}
		for _, a := range e.Arms {
			if !ExprDiverges(a.Body) {
				return false
			}
		}
		return true
	}
	return false
}
