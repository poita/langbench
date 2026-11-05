package kbl

type expr interface{}

type (
	intLit  struct{ v int64 }
	boolLit struct{ v bool }
	// strLit is a string literal: constant text and/or interpolations.
	strLit struct {
		parts []strPart
	}
	varRef  struct{ name string }
	listLit struct{ elems []expr }
	unary   struct {
		op string
		x  expr
	}
	binary struct {
		op   string
		l, r expr
	}
	indexExpr struct{ x, i expr }
	call      struct {
		name string
		args []expr
	}
)

type strPart struct {
	lit  string
	e    expr // nil for a literal part
	isEx bool
}

type stmt interface{}

type (
	letStmt struct {
		name string
		e    expr
	}
	setStmt struct {
		name string
		e    expr
	}
	includeStmt struct{ e expr }
	abortStmt   struct{ e expr }
	defaultStmt struct{ e expr }
	phonyStmt   struct {
		name string
		e    expr
	}
	useStmt struct {
		name string
		args []useArg
	}
	whenStmt struct {
		conds     []expr
		bodies    [][]stmt
		otherwise []stmt
		hasOther  bool
	}
	eachStmt struct {
		index, name string // index is "" in the one-name form
		subject     expr
		body        []stmt
	}
	ruleStmt struct {
		name   string
		params []param
		body   []stmt
	}
	stepStmt struct{ fields []stepField }
)

type useArg struct {
	kw string // "" for positional
	e  expr
}

type param struct {
	name string
	def  expr // nil if required
}

type stepField struct {
	kind string // out in after cost depfile cmd
	e    expr   // for non-cmd fields
	cmd  string
	args []expr
}
