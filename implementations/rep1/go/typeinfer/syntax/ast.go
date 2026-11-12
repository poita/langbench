// Package syntax implements the lexer, the abstract syntax tree and the
// recursive-descent parser of the small ML-like language accepted by
// typeinfer.
package syntax

// Expr is an expression node. The concrete types are [IntLit], [BoolLit],
// [UnitLit], [Var], [Lam], [App], [Let], [If], [Tuple], [List], [Cons] and
// [BinOp].
type Expr interface{ isExpr() }

// IntLit is an integer literal. Text is its digits; the value is irrelevant to
// type checking and may be arbitrarily long.
type IntLit struct{ Text string }

// BoolLit is true or false.
type BoolLit struct{ Value bool }

// UnitLit is ().
type UnitLit struct{}

// Var is a reference to a variable.
type Var struct{ Name string }

// Lam is a function of one parameter; fun x y -> e is nested Lams.
type Lam struct {
	Param string
	Body  Expr
}

// App is the application of Fn to Arg.
type App struct{ Fn, Arg Expr }

// Let is let Name = Value in Body, or let rec when Rec is set. Parameters are
// already desugared: let f x = e is Let{Name: f, Value: Lam{x, e}}. When Rec
// is set Value is always a Lam.
type Let struct {
	Name  string
	Rec   bool
	Value Expr
	Body  Expr
}

// If is if Cond then Then else Else.
type If struct{ Cond, Then, Else Expr }

// Tuple is a tuple of two or more elements.
type Tuple struct{ Elems []Expr }

// List is a list literal [e1; ...; en]; Elems may be empty.
type List struct{ Elems []Expr }

// Cons is Head :: Tail.
type Cons struct{ Head, Tail Expr }

// Op is a binary operator on ints or bools.
type Op uint8

// The binary operators.
const (
	OpAdd Op = iota // +
	OpSub           // -
	OpMul           // *
	OpDiv           // /
	OpEq            // =
	OpLt            // <
	OpGt            // >
	OpLe            // <=
	OpGe            // >=
	OpAnd           // &&
	OpOr            // ||
)

var opNames = [...]string{"+", "-", "*", "/", "=", "<", ">", "<=", ">=", "&&", "||"}

// String returns the operator's source text.
func (o Op) String() string { return opNames[o] }

// BinOp is L Op R.
type BinOp struct {
	Op   Op
	L, R Expr
}

func (*IntLit) isExpr()  {}
func (*BoolLit) isExpr() {}
func (*UnitLit) isExpr() {}
func (*Var) isExpr()     {}
func (*Lam) isExpr()     {}
func (*App) isExpr()     {}
func (*Let) isExpr()     {}
func (*If) isExpr()      {}
func (*Tuple) isExpr()   {}
func (*List) isExpr()    {}
func (*Cons) isExpr()    {}
func (*BinOp) isExpr()   {}

// Decl is a top-level declaration.
//
// For a binding (let or let rec) Name is the bound name and Expr its
// right-hand side (parameters desugared into Lams). For a bare expression Name
// is empty.
type Decl struct {
	Name string
	Rec  bool
	Expr Expr
}

// IsBinding reports whether d is a let or let rec declaration.
func (d Decl) IsBinding() bool { return d.Name != "" }
