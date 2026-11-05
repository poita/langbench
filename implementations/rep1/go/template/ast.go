package template

// Expr is an expression node. Evaluation dispatches through the method
// table of the concrete node type, so there is a single indirect call per
// node and no runtime type tests.
type Expr interface {
	eval(r *rendering, sc *scope) Value
}

// Stmt is a statement node.
type Stmt interface {
	exec(r *rendering, sc *scope, out *output)
}

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

type filterCode uint8

const (
	filterUnknown filterCode = iota
	filterUpper
	filterLower
	filterTrim
	filterEscape
	filterReplace
	filterLength
	filterInt
	filterJoin
	filterFirst
	filterLast
	filterReverse
	filterSort
	filterDefault
)

var filterCodes = map[string]filterCode{
	"upper": filterUpper, "lower": filterLower, "trim": filterTrim,
	"escape": filterEscape, "replace": filterReplace, "length": filterLength,
	"int": filterInt, "join": filterJoin, "first": filterFirst, "last": filterLast,
	"reverse": filterReverse, "sort": filterSort, "default": filterDefault,
}

// Expression nodes.
type (
	constExpr struct{ v Value }
	nameExpr  struct {
		name    string
		isRange bool
	}
	listExpr struct{ elems []Expr }
	negExpr  struct{ x Expr }
	notExpr  struct{ x Expr }
	andExpr  struct{ l, r Expr }
	orExpr   struct{ l, r Expr }
	binExpr  struct {
		op   binOp
		l, r Expr
	}
	cmpExpr struct {
		first Expr
		ops   []cmpOp
		rest  []Expr
	}
	filterExpr struct {
		x    Expr
		code filterCode
		args []Expr
	}
	definedExpr struct {
		x      Expr
		negate bool
	}
	attrExpr struct {
		x   Expr
		key Value // string, built once at parse time
	}
	indexExpr struct{ x, idx Expr }
	callExpr  struct {
		fn      Expr
		args    []Expr
		kwNames []string
		kwVals  []Expr
	}
)

// Statement nodes.
type (
	textStmt  struct{ s string }
	printStmt struct{ x Expr }
	ifStmt    struct {
		conds    []Expr
		bodies   [][]Stmt
		elseBody []Stmt
	}
	forStmt struct {
		name     string
		iter     Expr
		body     []Stmt
		elseBody []Stmt
	}
	setStmt struct {
		name string
		x    Expr
	}
	macroStmt   struct{ def *macroDef }
	includeStmt struct{ x Expr }
	extendsStmt struct{ x Expr }
	blockStmt   struct{ def *blockDef }
)

type macroDef struct {
	name     string
	params   []string
	defaults []Expr // parallel to params; nil where there is no default
	body     []Stmt
}

type blockDef struct {
	name string
	body []Stmt
}

// Template is a loaded (lexed, parsed and filter-checked) template.
type Template struct {
	name   string
	body   []Stmt
	blocks []*blockDef
}

// Name returns the template's name.
func (t *Template) Name() string { return t.name }
