package kbl

// Expr is an expression node.
type Expr interface{}

type (
	intLit  struct{ v int64 }
	boolLit struct{ v bool }
	varRef  struct{ name string }
	listLit struct{ elems []Expr }
	strLit  struct{ parts []strPart }
	unary   struct {
		op string
		x  Expr
	}
	binary struct {
		op   string
		l, r Expr
	}
	index struct{ x, i Expr }
	call  struct {
		name string
		fn   *builtin // nil when the name is not a built-in
		args []Expr
	}
)

// strPart is a literal run (expr == nil) or an interpolation.
type strPart struct {
	lit  string
	expr Expr
}

// Stmt is a statement node.
type Stmt interface{}

type (
	letStmt struct {
		name string
		x    Expr
	}
	setStmt struct {
		name string
		x    Expr
	}
	includeStmt struct{ x Expr }
	abortStmt   struct{ x Expr }
	defaultStmt struct{ x Expr }
	phonyStmt   struct {
		name string
		x    Expr
	}
	useStmt struct {
		name string
		pos  []Expr
		kws  []kwArg
	}
	whenStmt struct {
		conds     []Expr
		bodies    [][]Stmt
		otherwise []Stmt
	}
	eachStmt struct {
		index, name string // index is "" in the one-name form
		x           Expr
		body        []Stmt
	}
	ruleStmt struct {
		name   string
		params []param
		body   []Stmt
	}
	stepStmt struct{ fields []stepField }
)

type kwArg struct {
	name string
	x    Expr
}

type param struct {
	name string
	def  Expr // nil when the parameter has no default
}

type fieldKind uint8

const (
	fOut fieldKind = iota
	fIn
	fAfter
	fCost
	fDepfile
	fCmd
)

type stepField struct {
	kind    fieldKind
	x       Expr   // for all but fCmd
	cmdName string // for fCmd
	args    []Expr // for fCmd
}

// File is a parsed build file.
type File struct {
	Name  string
	Stmts []Stmt
}
