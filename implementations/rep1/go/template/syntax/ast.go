// Package syntax lexes and parses template source into a syntax tree.
//
// [Parse] turns a template body into a [Template]: a tree of [Node]
// statements holding [Expr] expressions, plus the static table of its blocks
// and the list of filter names it uses. Every problem in the source is
// reported as a tplerr.Syntax error.
package syntax

import "example.com/template/value"

// Node is a statement or a piece of literal text.
type Node interface{ node() }

// Expr is an expression.
type Expr interface{ expr() }

// Template is a parsed template.
type Template struct {
	Name    string
	Body    []Node
	Blocks  map[string]*Block // every block in the template, by name
	Filters []string          // every filter name used anywhere, in source order
}

// Statement and text nodes.
type (
	// Text is literal output.
	Text struct{ Text string }
	// Print is {{ expr }}.
	Print struct{ X Expr }
	// If is an if/elif/else chain: Bodies[i] runs when Conds[i] is the first
	// truthy condition; Else runs when none is (and may be nil).
	If struct {
		Conds  []Expr
		Bodies [][]Node
		Else   []Node
	}
	// For is a for loop with an optional else body.
	For struct {
		Var  string
		Iter Expr
		Body []Node
		Else []Node
	}
	// Set is {% set Name = X %}.
	Set struct {
		Name string
		X    Expr
	}
	// MacroDef is a macro definition.
	MacroDef struct {
		Name   string
		Params []Param
		Body   []Node
	}
	// Include is {% include X %}.
	Include struct{ X Expr }
	// Extends is {% extends X %}.
	Extends struct{ X Expr }
	// Block is a named block.
	Block struct {
		Name string
		Body []Node
	}
)

// Param is a macro parameter; Default is nil when it has none.
type Param struct {
	Name    string
	Default Expr
}

// Kwarg is a keyword argument of a call.
type Kwarg struct {
	Name string
	X    Expr
}

// Expression nodes.
type (
	// Literal is a constant value.
	Literal struct{ Value value.Value }
	// Name is a variable reference.
	Name struct{ Name string }
	// ListLit is a list literal.
	ListLit struct{ Elems []Expr }
	// Neg is unary minus.
	Neg struct{ X Expr }
	// Not is logical negation.
	Not struct{ X Expr }
	// Binary is an arithmetic or concatenation operation.
	Binary struct {
		Op   value.Op
		L, R Expr
	}
	// Logic is `and` (Or false) or `or` (Or true); it yields an operand.
	Logic struct {
		Or   bool
		L, R Expr
	}
	// Compare is a chain First Ops[0] Rest[0] Ops[1] Rest[1] ...
	Compare struct {
		First Expr
		Ops   []value.CmpOp
		Rest  []Expr
	}
	// FilterExpr is X|Name(Args).
	FilterExpr struct {
		X    Expr
		Name string
		Args []Expr
	}
	// IsDefined is `X is defined` or, with Negate, `X is not defined`.
	IsDefined struct {
		X      Expr
		Negate bool
	}
	// Attr is X.Name.
	Attr struct {
		X    Expr
		Name string
	}
	// Index is X[Key].
	Index struct{ X, Key Expr }
	// Call is Fn(Args, Kwargs).
	Call struct {
		Fn     Expr
		Args   []Expr
		Kwargs []Kwarg
	}
)

func (*Text) node()     {}
func (*Print) node()    {}
func (*If) node()       {}
func (*For) node()      {}
func (*Set) node()      {}
func (*MacroDef) node() {}
func (*Include) node()  {}
func (*Extends) node()  {}
func (*Block) node()    {}

func (*Literal) expr()    {}
func (*Name) expr()       {}
func (*ListLit) expr()    {}
func (*Neg) expr()        {}
func (*Not) expr()        {}
func (*Binary) expr()     {}
func (*Logic) expr()      {}
func (*Compare) expr()    {}
func (*FilterExpr) expr() {}
func (*IsDefined) expr()  {}
func (*Attr) expr()       {}
func (*Index) expr()      {}
func (*Call) expr()       {}
