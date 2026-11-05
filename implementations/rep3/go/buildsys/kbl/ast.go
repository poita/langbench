package kbl

// Expr is an expression node.
type Expr interface{ exprNode() }

// Stmt is a statement node.
type Stmt interface{ stmtNode() }

type (
	// LitExpr is a constant.
	LitExpr struct{ Val Value }
	// TemplateExpr is a double-quoted literal with interpolations.
	TemplateExpr struct{ Parts []TemplatePart }
	// VarExpr is a variable reference.
	VarExpr struct{ Name string }
	// ListExpr is a list display.
	ListExpr struct{ Elems []Expr }
	// UnaryExpr is `!x` or `-x`.
	UnaryExpr struct {
		Op string
		X  Expr
	}
	// BinaryExpr is a binary operation.
	BinaryExpr struct {
		Op   string
		L, R Expr
	}
	// CallExpr is a built-in call. Fn is nil when the name is unknown, which
	// is only an error if the call is evaluated.
	CallExpr struct {
		Name string
		Fn   *builtin
		Args []Expr
	}
	// IndexExpr is `x[i]`.
	IndexExpr struct{ X, I Expr }
)

// TemplatePart is a literal chunk (Expr == nil) or an interpolated expression.
type TemplatePart struct {
	Lit  string
	Expr Expr
}

func (*LitExpr) exprNode()      {}
func (*TemplateExpr) exprNode() {}
func (*VarExpr) exprNode()      {}
func (*ListExpr) exprNode()     {}
func (*UnaryExpr) exprNode()    {}
func (*BinaryExpr) exprNode()   {}
func (*CallExpr) exprNode()     {}
func (*IndexExpr) exprNode()    {}

type (
	LetStmt struct {
		Name string
		X    Expr
	}
	SetStmt struct {
		Name string
		X    Expr
	}
	IncludeStmt struct{ X Expr }
	AbortStmt   struct{ X Expr }
	DefaultStmt struct{ X Expr }
	PhonyStmt   struct {
		Name string
		X    Expr
	}
	// UseStmt instantiates a rule; keyword arguments have a non-empty Name.
	UseStmt struct {
		Rule string
		Args []UseArg
	}
	WhenStmt struct {
		Branches []*Branch
		Else     *Branch // nil when absent
	}
	EachStmt struct {
		Index string // "" in the one-name form
		Name  string
		X     Expr
		Body  []Stmt
	}
	RuleStmt struct {
		Name   string
		Params []Param
		Body   []Stmt
	}
	StepStmt struct{ Fields []StepField }
)

// Branch is one arm of a when/elsewhen/otherwise chain.
type Branch struct {
	Cond Expr // nil for otherwise
	Body []Stmt
}

// UseArg is a positional (Name == "") or keyword argument.
type UseArg struct {
	Name string
	X    Expr
}

// Param is a rule parameter, with an optional default.
type Param struct {
	Name    string
	Default Expr
}

// StepField is one line of a step block.
type StepField struct {
	Kind    string // out in after cost depfile cmd
	X       Expr   // for all but cmd
	CmdName string
	Args    []Expr
}

func (*LetStmt) stmtNode()     {}
func (*SetStmt) stmtNode()     {}
func (*IncludeStmt) stmtNode() {}
func (*AbortStmt) stmtNode()   {}
func (*DefaultStmt) stmtNode() {}
func (*PhonyStmt) stmtNode()   {}
func (*UseStmt) stmtNode()     {}
func (*WhenStmt) stmtNode()    {}
func (*EachStmt) stmtNode()    {}
func (*RuleStmt) stmtNode()    {}
func (*StepStmt) stmtNode()    {}

// File is a parsed build file.
type File struct{ Body []Stmt }
