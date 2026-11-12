package kbl

// Expressions.
type (
	expr interface{}

	intLit  struct{ v int64 }
	boolLit struct{ v bool }
	// strLit is a string literal: a sequence of literal and interpolated parts.
	strLit struct{ parts []strPart }
	varRef struct{ name string }
	list   struct{ elems []expr }
	unary  struct {
		op string
		x  expr
	}
	binary struct {
		op   string
		l, r expr
	}
	call struct {
		name string
		args []expr
	}
	index struct{ x, i expr }
)

// strPart is either literal text (e == nil) or an interpolated expression.
type strPart struct {
	lit string
	e   expr
}

// Statements.
type (
	stmt interface{}

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
		rule string
		args []useArg
	}
	whenStmt struct {
		conds    []expr
		bodies   [][]stmt
		other    []stmt
		hasOther bool
	}
	eachStmt struct {
		index   string // "" in the one-name form
		name    string
		subject expr
		body    []stmt
	}
	ruleStmt struct {
		name   string
		params []param
		body   []stmt
	}
	stepStmt struct{ fields []stepField }
)

type useArg struct {
	kw string // "" for a positional argument
	e  expr
}

type param struct {
	name string
	def  expr // nil when there is no default
}

// stepField is one line of a step block.
type stepField struct {
	kind string // out, in, after, cost, depfile, cmd
	e    expr   // the field expression (not for cmd)
	cmd  string // command name (cmd only)
	args []expr // command arguments (cmd only)
}
