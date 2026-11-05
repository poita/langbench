// Package formula parses spreadsheet formulas into a compact AST.
//
// The AST is stored as a flat slice of nodes that refer to their children by
// index, so evaluating a formula never chases heap pointers. Cell references
// are first recorded by cell key (see package cellref); a host engine then
// calls Expr.Resolve to bind them to its own dense cell handles.
package formula

// Kind is the type of an AST node.
type Kind uint8

// Node kinds.
const (
	KindNum   Kind = iota // numeric literal: Num
	KindStr               // string literal: Str
	KindRef               // single cell: Key, Cell (after Resolve)
	KindRange             // rectangle: Key..Key2, Cells (after Resolve); only as an aggregate argument
	KindNeg               // unary minus: A
	KindBin               // binary operator: Op (a BinOp), A, B
	KindIf                // IF(A, B, C)
	KindAgg               // aggregate: Op (an AggFn), Args
)

// BinOp is a binary operator.
type BinOp uint8

// Binary operators.
const (
	OpAdd BinOp = iota
	OpSub
	OpMul
	OpDiv
	OpCat
	OpEq
	OpNe
	OpLt
	OpGt
	OpLe
	OpGe
)

// AggFn is an aggregate function.
type AggFn uint8

// Aggregate functions.
const (
	FnSum AggFn = iota
	FnMin
	FnMax
	FnAvg
	FnCount
)

// Node is one AST node. Which fields are meaningful depends on Kind.
type Node struct {
	Kind  Kind
	Op    uint8 // BinOp for KindBin, AggFn for KindAgg
	Num   float64
	Str   string
	Key   int32   // KindRef: cell key; KindRange: first corner key
	Key2  int32   // KindRange: second corner key
	Cell  int32   // KindRef: handle assigned by Resolve
	Cells []int32 // KindRange: handles in row-major order, assigned by Resolve
	A     int32   // child indices
	B     int32
	C     int32
	Args  []int32 // KindAgg: argument node indices
}

// Expr is a parsed formula.
type Expr struct {
	Nodes []Node
	Root  int32
	// Invalid is set when the formula contains an invalid cell reference
	// (for example AAA1 or A0). Such a formula evaluates to #REF! and has no
	// dependencies; its Nodes must not be resolved.
	Invalid bool
}

// Resolve binds every reference in the formula to a handle obtained from
// handle, which is called with a cell key. Ranges are expanded in row-major
// order. Resolve does nothing for an invalid formula.
func (e *Expr) Resolve(handle func(key int32) int32) {
	if e.Invalid {
		return
	}
	for i := range e.Nodes {
		n := &e.Nodes[i]
		switch n.Kind {
		case KindRef:
			n.Cell = handle(n.Key)
		case KindRange:
			c1, r1 := splitKey(n.Key)
			c2, r2 := splitKey(n.Key2)
			if c1 > c2 {
				c1, c2 = c2, c1
			}
			if r1 > r2 {
				r1, r2 = r2, r1
			}
			cells := make([]int32, 0, (c2-c1+1)*(r2-r1+1))
			for r := r1; r <= r2; r++ {
				for c := c1; c <= c2; c++ {
					cells = append(cells, handle(int32(joinKey(c, r))))
				}
			}
			n.Cells = cells
		}
	}
}

// Deps appends the handle of every cell the (resolved) formula refers to,
// including every cell covered by a range, to dst. Duplicates are not
// removed.
func (e *Expr) Deps(dst []int32) []int32 {
	if e.Invalid {
		return dst
	}
	for i := range e.Nodes {
		n := &e.Nodes[i]
		switch n.Kind {
		case KindRef:
			dst = append(dst, n.Cell)
		case KindRange:
			dst = append(dst, n.Cells...)
		}
	}
	return dst
}
