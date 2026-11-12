package kbl

// Expr is an expression node.
type Expr interface{ exprNode() }

type (
	// IntLit is an integer literal.
	IntLit struct{ V int64 }
	// BoolLit is true or false.
	BoolLit struct{ V bool }
	// StrLit is a string literal; a literal without interpolation has a single
	// literal part.
	StrLit struct{ Parts []StrPart }
	// VarRef refers to a variable.
	VarRef struct{ Name string }
	// ListLit is a list display.
	ListLit struct{ Elems []Expr }
	// Unary is a prefix operator application ("!" or "-").
	Unary struct {
		Op string
		X  Expr
	}
	// Binary is a binary operator application.
	Binary struct {
		Op   string
		L, R Expr
	}
	// Call is a built-in function call; a pipe `a |> f(b)` is a Call f(a, b).
	Call struct {
		Name string
		Args []Expr
	}
	// Index is x[i].
	Index struct{ X, I Expr }
)

// StrPart is one part of a string literal: either literal bytes (X == nil) or
// an interpolated expression.
type StrPart struct {
	Lit string
	X   Expr
}

func (IntLit) exprNode()  {}
func (BoolLit) exprNode() {}
func (StrLit) exprNode()  {}
func (VarRef) exprNode()  {}
func (ListLit) exprNode() {}
func (Unary) exprNode()   {}
func (Binary) exprNode()  {}
func (Call) exprNode()    {}
func (Index) exprNode()   {}

// Stmt is a statement node.
type Stmt interface{ stmtNode() }

type (
	// Let is `let name = expr`.
	Let struct {
		Name string
		X    Expr
	}
	// Set is `set name = expr`.
	Set struct {
		Name string
		X    Expr
	}
	// Include is `include expr`.
	Include struct{ X Expr }
	// Abort is `abort expr`.
	Abort struct{ X Expr }
	// Default is `default expr`.
	Default struct{ X Expr }
	// Phony is `phony name = expr`.
	Phony struct {
		Name string
		X    Expr
	}
	// UseArg is one argument of a use statement; Name is empty for positional
	// arguments.
	UseArg struct {
		Name string
		X    Expr
	}
	// Use is `use rule(args)`.
	Use struct {
		Rule string
		Args []UseArg
	}
	// When is a when/elsewhen/otherwise chain. Bodies has one entry per
	// condition, followed by the otherwise body if HasElse.
	When struct {
		Conds   []Expr
		Bodies  [][]Stmt
		Else    []Stmt
		HasElse bool
	}
	// Each is a loop; Index is empty in the one-name form.
	Each struct {
		Index, Name string
		X           Expr
		Body        []Stmt
	}
	// Param is a rule parameter; Default is nil if it has none.
	Param struct {
		Name    string
		Default Expr
	}
	// Rule is a rule definition.
	Rule struct {
		Name   string
		Params []Param
		Body   []Stmt
	}
	// StepStmt is a step block.
	StepStmt struct{ Fields []StepField }
)

// StepField is one field line of a step block.
type StepField struct {
	// Kind is out, in, after, cost, depfile or cmd.
	Kind string
	X    Expr
	// Cmd and Args are set for the cmd field.
	Cmd  string
	Args []Expr
}

func (Let) stmtNode()      {}
func (Set) stmtNode()      {}
func (Include) stmtNode()  {}
func (Abort) stmtNode()    {}
func (Default) stmtNode()  {}
func (Phony) stmtNode()    {}
func (Use) stmtNode()      {}
func (When) stmtNode()     {}
func (Each) stmtNode()     {}
func (Rule) stmtNode()     {}
func (StepStmt) stmtNode() {}
