package datalog

// term is a variable (a per-clause slot number) or a constant (an id into
// Program.consts). After Parse, constant ids are ranks in the language order.
type term struct {
	isVar bool
	id    int32
}

type atom struct {
	pred int32
	args []term
}

type cmpOp uint8

const (
	opLT cmpOp = iota
	opLE
	opGT
	opGE
	opEQ
	opNE
)

func (op cmpOp) holds(a, b int32) bool {
	switch op {
	case opLT:
		return a < b
	case opLE:
		return a <= b
	case opGT:
		return a > b
	case opGE:
		return a >= b
	case opEQ:
		return a == b
	}
	return a != b
}

type litKind uint8

const (
	litPos litKind = iota
	litNeg
	litCmp
)

type literal struct {
	kind litKind
	atom atom // litPos, litNeg
	op   cmpOp
	l, r term // litCmp
}

// rule is head :- body. A fact is a rule with an empty body.
type rule struct {
	head    atom
	body    []literal
	numVars int
}

type query struct {
	atom    atom
	numVars int
}

type predInfo struct {
	name  string
	arity int
}

// Program is a parsed Datalog program: facts, rules and queries with all
// predicates and constants interned. A Program is immutable after Parse and
// may be solved any number of times.
type Program struct {
	preds   []predInfo
	consts  []Value // sorted in language order; term ids index this slice
	rules   []rule
	queries []query
}

// NumQueries returns the number of queries in the program.
func (p *Program) NumQueries() int { return len(p.queries) }

// NumRules returns the number of clauses with a head, facts included.
func (p *Program) NumRules() int { return len(p.rules) }
