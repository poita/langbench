package tmpl

// ---- expressions ----

type expr any

type (
	litExpr  struct{ v Value }
	nameExpr struct{ name string }
	attrExpr struct {
		obj expr
		key string
	}
	indexExpr struct{ obj, idx expr }
	callExpr  struct {
		fn      expr
		args    []expr
		kwNames []string
		kwVals  []expr
	}
	filterExpr struct {
		x    expr
		code filterCode
		args []expr
	}
	definedExpr struct {
		x   expr
		neg bool
	}
	negExpr struct{ x expr }
	notExpr struct{ x expr }
	andExpr struct{ l, r expr }
	orExpr  struct{ l, r expr }
	binExpr struct {
		op   binOp
		l, r expr
	}
	cmpExpr struct {
		first expr
		ops   []cmpOp
		rest  []expr
	}
	listExpr struct{ elems []expr }
)

type binOp uint8

const (
	opAdd binOp = iota
	opSub
	opMul
	opDiv
	opFloorDiv
	opMod
	opPow
	opConcat
)

type cmpOp uint8

const (
	cmpEq cmpOp = iota
	cmpNe
	cmpLt
	cmpLe
	cmpGt
	cmpGe
	cmpIn
	cmpNotIn
)

// ---- statements ----

type stmt any

type (
	textStmt  struct{ text string }
	printStmt struct{ x expr }
	ifStmt    struct {
		conds    []expr
		bodies   [][]stmt
		elseBody []stmt
	}
	forStmt struct {
		name     string
		iter     expr
		body     []stmt
		elseBody []stmt
		reuse    bool // the body defines no macro, so one scope serves all iterations
	}
	setStmt struct {
		name string
		x    expr
	}
	includeStmt struct{ x expr }
	extendsStmt struct{ x expr }
)

type param struct {
	name string
	def  expr // nil when the parameter has no default
}

type macroDef struct {
	name   string
	params []param
	body   []stmt
}

type blockDef struct {
	name string
	body []stmt
}

// template is a parsed template.
type template struct {
	name   string
	body   []stmt
	blocks map[string]*blockDef
}
