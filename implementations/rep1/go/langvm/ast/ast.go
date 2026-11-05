// Package ast defines the syntax tree of Vellum modules (SPEC section 4).
//
// Nodes carry source positions. Fields named Res, Info, Sem and similar are
// annotation slots filled in by the checker (package check) and read by the
// bytecode compiler; they are typed any to keep this package free of
// dependencies on later phases.
package ast

import "langvm/diag"

// Pos is a source position.
type Pos = diag.Pos

// Ident is a name with the position of its token.
type Ident struct {
	Name string
	Pos  Pos
}

// Module is a parsed module.
type Module struct {
	Name  string
	Items []Item
}

// Item is a top-level declaration.
type Item interface{ itemPos() Pos }

// UseDecl is `use m;` or `use m as k;`. Pos is the `use` keyword.
type UseDecl struct {
	Pos    Pos
	Module Ident
	Alias  *Ident
}

// GenParam is one generic parameter with its bounds.
type GenParam struct {
	Name   Ident
	Bounds []*TraitRef
}

// TraitRef names a trait: `Tr` or `m::Tr`. Pos is its first token.
type TraitRef struct {
	Pos  Pos
	Mod  *Ident
	Name Ident
}

// Param is a typed parameter.
type Param struct {
	Name Ident
	Type *TypeExpr
}

// FnDecl is a function, trait method signature or impl method. Pos is the `fn`
// keyword. Body is nil for a trait method without default body.
type FnDecl struct {
	Pos      Pos
	Pub      bool
	Name     Ident
	Generics []*GenParam
	Params   []*Param
	Ret      *TypeExpr // nil means Unit
	Body     *Block
	IsMethod bool // has a leading `self`
	Info     any
}

// Field is a struct field.
type Field struct {
	Name Ident
	Type *TypeExpr
}

// StructDecl declares a struct.
type StructDecl struct {
	Pos      Pos
	Pub      bool
	Name     Ident
	Generics []*GenParam
	Fields   []*Field
	Info     any
}

// Variant is an enum variant.
type Variant struct {
	Name    Ident
	Payload []*TypeExpr
}

// EnumDecl declares an enum.
type EnumDecl struct {
	Pos      Pos
	Pub      bool
	Name     Ident
	Generics []*GenParam
	Variants []*Variant
	Info     any
}

// TraitDecl declares a trait.
type TraitDecl struct {
	Pos     Pos
	Pub     bool
	Name    Ident
	Methods []*FnDecl
	Info    any
}

// ImplDecl is an impl block. Pos is the `impl` keyword.
type ImplDecl struct {
	Pos      Pos
	Generics []*GenParam
	Trait    *TraitRef
	Head     *TypeExpr
	Methods  []*FnDecl
	Info     any
}

func (d *UseDecl) itemPos() Pos    { return d.Pos }
func (d *FnDecl) itemPos() Pos     { return d.Pos }
func (d *StructDecl) itemPos() Pos { return d.Pos }
func (d *EnumDecl) itemPos() Pos   { return d.Pos }
func (d *TraitDecl) itemPos() Pos  { return d.Pos }
func (d *ImplDecl) itemPos() Pos   { return d.Pos }

// TypeKind distinguishes written type forms.
type TypeKind uint8

// Written type forms.
const (
	TList  TypeKind = iota // [T]: Args[0]
	TMap                   // #[K: V]: Args[0], Args[1]
	TTuple                 // (A, B, ...): Args
	TFn                    // fn(A, B) -> R: Args, Ret
	TPath                  // N, m::N, N<A, B>: Mod, Name, Args
)

// TypeExpr is a written type. Pos is its first token.
type TypeExpr struct {
	Kind TypeKind
	Pos  Pos
	Mod  *Ident
	Name Ident
	Args []*TypeExpr
	Ret  *TypeExpr
}

// ---------------------------------------------------------------- expressions

// Expr is an expression node.
type Expr interface{ Position() Pos }

// BinOp is a binary operator.
type BinOp uint8

// Binary operators.
const (
	OpOr BinOp = iota
	OpAnd
	OpEq
	OpNe
	OpLt
	OpLe
	OpGt
	OpGe
	OpBitOr
	OpBitXor
	OpBitAnd
	OpShl
	OpShr
	OpAdd
	OpSub
	OpConcat
	OpMul
	OpDiv
	OpMod
)

// UnOp is a prefix operator.
type UnOp uint8

// Prefix operators.
const (
	OpNeg UnOp = iota
	OpNot
	OpBitNot
)

type (
	// IntLit is an integer literal.
	IntLit struct {
		P   Pos
		Val int64
	}
	// FloatLit is a float literal.
	FloatLit struct {
		P   Pos
		Val float64
	}
	// StrLit is a string literal.
	StrLit struct {
		P   Pos
		Val []rune
	}
	// CharLit is a character literal.
	CharLit struct {
		P   Pos
		Val rune
	}
	// BoolLit is true or false.
	BoolLit struct {
		P   Pos
		Val bool
	}
	// SelfExpr is `self`.
	SelfExpr struct {
		P   Pos
		Res any
	}
	// PathExpr is a value path `x` or `m::x`.
	PathExpr struct {
		P    Pos
		Mod  *Ident
		Name Ident
		Res  any
	}
	// Unary is a prefix operation.
	Unary struct {
		P   Pos
		Op  UnOp
		X   Expr
		Sem int
	}
	// Binary is an infix operation.
	Binary struct {
		Op   BinOp
		OpP  Pos
		L, R Expr
		Sem  int
	}
	// Call is `callee(args)`.
	Call struct {
		Callee Expr
		Args   []Expr
		Res    any
	}
	// MethodCall is `recv.name(args)`.
	MethodCall struct {
		Recv Expr
		Name Ident
		Args []Expr
		Res  any
	}
	// IndexExpr is `x[i]`.
	IndexExpr struct {
		X, Index Expr
		Sem      int
	}
	// FieldExpr is `x.f`.
	FieldExpr struct {
		X    Expr
		Name Ident
		Sem  int
	}
	// ListLit is `[a, b]`.
	ListLit struct {
		P     Pos
		Elems []Expr
	}
	// MapLit is `#[k: v, ...]`.
	MapLit struct {
		P          Pos
		Keys, Vals []Expr
	}
	// TupleLit is `(a, b, ...)`.
	TupleLit struct {
		P     Pos
		Elems []Expr
	}
	// LParam is a lambda parameter.
	LParam struct {
		Name Ident
		Type *TypeExpr
	}
	// Lambda is a closure expression; P is its opening bar.
	Lambda struct {
		P      Pos
		Params []*LParam
		Ret    *TypeExpr
		Body   Expr // *Block or an expression
		Info   any
	}
	// IfExpr is `if c {..} else ..`; Else is nil, *Block or *IfExpr.
	IfExpr struct {
		P    Pos
		Cond Expr
		Then *Block
		Else Expr
		Div  bool
	}
	// Arm is one match arm.
	Arm struct {
		Pat   Pattern
		Guard Expr
		Body  Expr
	}
	// MatchExpr is a match expression.
	MatchExpr struct {
		P     Pos
		Scrut Expr
		Arms  []*Arm
		Div   bool
	}
	// FieldInit is `name: expr` in a struct literal.
	FieldInit struct {
		Name Ident
		X    Expr
	}
	// StructLit is `P.{ f: e, ... }`.
	StructLit struct {
		P      Pos
		Mod    *Ident
		Name   Ident
		Fields []*FieldInit
		Res    any
	}
	// Block is `{ stmts tail }`. P is the opening brace.
	Block struct {
		P     Pos
		Stmts []Stmt
		Tail  Expr
		Div   bool
	}
)

func (e *IntLit) Position() Pos     { return e.P }
func (e *FloatLit) Position() Pos   { return e.P }
func (e *StrLit) Position() Pos     { return e.P }
func (e *CharLit) Position() Pos    { return e.P }
func (e *BoolLit) Position() Pos    { return e.P }
func (e *SelfExpr) Position() Pos   { return e.P }
func (e *PathExpr) Position() Pos   { return e.P }
func (e *Unary) Position() Pos      { return e.P }
func (e *Binary) Position() Pos     { return e.L.Position() }
func (e *Call) Position() Pos       { return e.Callee.Position() }
func (e *MethodCall) Position() Pos { return e.Recv.Position() }
func (e *IndexExpr) Position() Pos  { return e.X.Position() }
func (e *FieldExpr) Position() Pos  { return e.X.Position() }
func (e *ListLit) Position() Pos    { return e.P }
func (e *MapLit) Position() Pos     { return e.P }
func (e *TupleLit) Position() Pos   { return e.P }
func (e *Lambda) Position() Pos     { return e.P }
func (e *IfExpr) Position() Pos     { return e.P }
func (e *MatchExpr) Position() Pos  { return e.P }
func (e *StructLit) Position() Pos  { return e.P }
func (e *Block) Position() Pos      { return e.P }

// Diverges reports whether e is an if/match/block that cannot complete
// normally (SPEC 11.6).
func Diverges(e Expr) bool {
	switch n := e.(type) {
	case *Block:
		return n.Div
	case *IfExpr:
		return n.Div
	case *MatchExpr:
		return n.Div
	}
	return false
}

// ----------------------------------------------------------------- statements

// Stmt is a statement node.
type Stmt interface{ stmtPos() Pos }

type (
	// LetStmt is `let pat [: T] = e;`.
	LetStmt struct {
		P    Pos
		Pat  Pattern
		Type *TypeExpr
		Init Expr
	}
	// VarStmt is `var x [: T] = e;`.
	VarStmt struct {
		P     Pos
		Name  Ident
		Type  *TypeExpr
		Init  Expr
		Local any
	}
	// AssignStmt is `target = value;`.
	AssignStmt struct {
		P      Pos
		Target Expr
		Value  Expr
		Sem    int
	}
	// ExprStmt is an expression statement.
	ExprStmt struct{ X Expr }
	// ReturnStmt is `return [e];`.
	ReturnStmt struct {
		P Pos
		X Expr
	}
	// WhileStmt is `while c {..}`.
	WhileStmt struct {
		P    Pos
		Cond Expr
		Body *Block
	}
	// ForStmt is `for pat in seq [.. hi] {..}`.
	ForStmt struct {
		P    Pos
		Pat  Pattern
		Seq  Expr
		Hi   Expr // non-nil for the range form
		Body *Block
		Sem  int
	}
	// BreakStmt is `break;`.
	BreakStmt struct{ P Pos }
	// ContinueStmt is `continue;`.
	ContinueStmt struct{ P Pos }
)

func (s *LetStmt) stmtPos() Pos      { return s.P }
func (s *VarStmt) stmtPos() Pos      { return s.P }
func (s *AssignStmt) stmtPos() Pos   { return s.P }
func (s *ExprStmt) stmtPos() Pos     { return s.X.Position() }
func (s *ReturnStmt) stmtPos() Pos   { return s.P }
func (s *WhileStmt) stmtPos() Pos    { return s.P }
func (s *ForStmt) stmtPos() Pos      { return s.P }
func (s *BreakStmt) stmtPos() Pos    { return s.P }
func (s *ContinueStmt) stmtPos() Pos { return s.P }

// StmtDiverges reports whether control cannot flow past s (SPEC 11.6).
func StmtDiverges(s Stmt) bool {
	switch n := s.(type) {
	case *ReturnStmt, *BreakStmt, *ContinueStmt:
		return true
	case *LetStmt:
		return Diverges(n.Init)
	case *VarStmt:
		return Diverges(n.Init)
	case *AssignStmt:
		return Diverges(n.Value)
	case *ExprStmt:
		return Diverges(n.X)
	}
	return false
}

// ------------------------------------------------------------------- patterns

// Pattern is a pattern node.
type Pattern interface{ PatPos() Pos }

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

type (
	// WildPat is `_`.
	WildPat struct{ P Pos }
	// NamePat is a bare `x` (binding or 0-payload variant) or `m::C`.
	NamePat struct {
		P     Pos
		Mod   *Ident
		Name  Ident
		Local any // *check.Local when a binding
		Var   any // *check.Variant when a variant
	}
	// LitPat is a literal pattern.
	LitPat struct {
		P    Pos
		Kind LitKind
		Neg  bool
		Int  int64
		Str  []rune
		Bool bool
	}
	// VariantPat is `C(p, ...)`.
	VariantPat struct {
		P    Pos
		Mod  *Ident
		Name Ident
		Args []Pattern
		Var  any
	}
	// FieldPat is one struct-pattern field; Pat is nil for the shorthand.
	FieldPat struct {
		Name  Ident
		Pat   Pattern
		Local any // binding for the shorthand
		Index int
	}
	// StructPat is `P.{ f: p, .. }`.
	StructPat struct {
		P      Pos
		Mod    *Ident
		Name   Ident
		Fields []*FieldPat
		Rest   bool
		Decl   any
	}
	// TuplePat is `(p, q, ...)`.
	TuplePat struct {
		P     Pos
		Elems []Pattern
	}
	// ListPat is `[p, q, ..rest]`.
	ListPat struct {
		P         Pos
		Elems     []Pattern
		HasRest   bool
		RestName  *Ident
		RestLocal any
	}
)

func (p *WildPat) PatPos() Pos    { return p.P }
func (p *NamePat) PatPos() Pos    { return p.P }
func (p *LitPat) PatPos() Pos     { return p.P }
func (p *VariantPat) PatPos() Pos { return p.P }
func (p *StructPat) PatPos() Pos  { return p.P }
func (p *TuplePat) PatPos() Pos   { return p.P }
func (p *ListPat) PatPos() Pos    { return p.P }
