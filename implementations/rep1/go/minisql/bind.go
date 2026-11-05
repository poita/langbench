package minisql

// Binding turns a parsed statement into an executable form: every column
// reference is resolved to a (FROM slot, column index) pair, aggregate calls
// are assigned accumulator slots, and every semantic check is run. Nothing
// here touches table data, so a statement that fails to bind has no effect.

type source struct {
	name string // effective name: the alias if given, else the table name
	tbl  *Table
}

type scope struct{ srcs []source }

// resolve finds the column for a possibly qualified reference.
func (s *scope) resolve(qual, name string) (slot, col int) {
	if qual != "" {
		for i, src := range s.srcs {
			if src.name == qual {
				if c := src.tbl.colIndex(name); c >= 0 {
					return i, c
				}
				semErr("no such column: %s.%s", qual, name)
			}
		}
		semErr("no such table: %s", qual)
	}
	slot, col = -1, -1
	for i, src := range s.srcs {
		if c := src.tbl.colIndex(name); c >= 0 {
			if slot >= 0 {
				semErr("ambiguous column: %s", name)
			}
			slot, col = i, c
		}
	}
	if slot < 0 {
		semErr("no such column: %s", name)
	}
	return slot, col
}

type aggFn uint8

const (
	aggCount aggFn = iota
	aggSum
	aggMin
	aggMax
	aggAvg
)

type aggSpec struct {
	fn   aggFn
	star bool
	arg  *bexpr
}

// binder binds expressions within a scope.
type binder struct {
	sc        *scope
	aggs      *[]aggSpec // nil: aggregate functions are not allowed
	grouped   bool       // aggregate query: bare columns must be grouping columns
	groupCols map[[2]int]bool
	inAgg     bool
}

var binOps = map[string]bkind{
	"+": bAdd, "-": bSub, "*": bMul, "/": bDiv, "%": bMod,
	"=": bEq, "!=": bNe, "<": bLt, "<=": bLe, ">": bGt, ">=": bGe,
	"and": bAnd, "or": bOr,
}

var aggFns = map[string]aggFn{
	"count": aggCount, "sum": aggSum, "min": aggMin, "max": aggMax, "avg": aggAvg,
}

func (b *binder) bind(e *expr) *bexpr {
	switch e.kind {
	case eInt:
		return &bexpr{kind: bConst, c: Int(e.ival)}
	case eStr:
		return &bexpr{kind: bConst, c: Text(e.sval)}
	case eNull:
		return &bexpr{kind: bConst}
	case eCol:
		slot, col := b.sc.resolve(e.qual, e.name)
		if b.grouped && !b.inAgg && !b.groupCols[[2]int{slot, col}] {
			semErr("column %s must appear in GROUP BY or an aggregate", e.name)
		}
		return &bexpr{kind: bCol, slot: slot, col: col}
	case eNeg:
		return &bexpr{kind: bNeg, l: b.bind(e.l)}
	case eNot:
		return &bexpr{kind: bNot, l: b.bind(e.l)}
	case eBin:
		return &bexpr{kind: binOps[e.op], l: b.bind(e.l), r: b.bind(e.r)}
	case eIsNull:
		k := bIsNull
		if e.neg {
			k = bIsNotNull
		}
		return &bexpr{kind: k, l: b.bind(e.l)}
	case eLike:
		k := bLike
		if e.neg {
			k = bNotLike
		}
		return &bexpr{kind: k, l: b.bind(e.l), r: b.bind(e.r)}
	case eAgg:
		if b.aggs == nil {
			semErr("aggregate function not allowed here")
		}
		if b.inAgg {
			semErr("nested aggregate function")
		}
		spec := aggSpec{fn: aggFns[e.fn], star: e.star}
		if !e.star {
			inner := *b
			inner.inAgg = true
			spec.arg = inner.bind(e.arg)
		}
		*b.aggs = append(*b.aggs, spec)
		return &bexpr{kind: bAgg, idx: len(*b.aggs) - 1}
	}
	panic("unreachable")
}

func hasAgg(e *expr) bool {
	if e == nil {
		return false
	}
	return e.kind == eAgg || hasAgg(e.l) || hasAgg(e.r)
}

// ---- SELECT ----

type orderSpec struct {
	out  int    // output column to sort by, or -1
	e    *bexpr // otherwise: expression to evaluate
	desc bool
}

type selectPlan struct {
	tables []*Table

	// Row filters. For a join, filterA/filterB read only the first/second
	// table (filterA also holds constant conjuncts), keyA[i] = keyB[i] are
	// the cross-table equalities, and resid the other cross-table conjuncts.
	filterA, filterB []*bexpr
	keyA, keyB       []*bexpr
	resid            []*bexpr

	items     []*bexpr
	aggQuery  bool
	groupCols [][2]int
	aggs      []aggSpec
	having    *bexpr
	order     []orderSpec
	limit     int64 // -1: no limit
	offset    int64
}

func (db *DB) lookup(name string) *Table {
	t := db.tables[name]
	if t == nil {
		semErr("no such table: %s", name)
	}
	return t
}

func (db *DB) bindSelect(s *selectStmt) *selectPlan {
	p := &selectPlan{limit: s.limit, offset: s.offset}
	sc := &scope{}
	for _, ref := range s.from {
		src := source{name: ref.effective(), tbl: db.lookup(ref.name)}
		for _, o := range sc.srcs {
			if o.name == src.name {
				semErr("duplicate table name: %s", src.name)
			}
		}
		sc.srcs = append(sc.srcs, src)
		p.tables = append(p.tables, src.tbl)
	}

	groupSet := map[[2]int]bool{}
	for _, g := range s.groupBy {
		slot, col := sc.resolve(g.qual, g.name)
		groupSet[[2]int{slot, col}] = true
		p.groupCols = append(p.groupCols, [2]int{slot, col})
	}
	p.aggQuery = len(s.groupBy) > 0 || hasAgg(s.having)
	for _, it := range s.items {
		p.aggQuery = p.aggQuery || hasAgg(it.e)
	}
	for _, t := range s.order {
		p.aggQuery = p.aggQuery || hasAgg(t.e)
	}

	// WHERE / ON: no aggregates.
	plain := &binder{sc: sc}
	var conj []*bexpr
	if s.on != nil {
		conj = splitAnd(plain.bind(s.on), conj)
	}
	if s.where != nil {
		conj = splitAnd(plain.bind(s.where), conj)
	}
	p.planFilters(conj)

	eb := &binder{sc: sc, aggs: &p.aggs, grouped: p.aggQuery, groupCols: groupSet}

	// Select list; '*' expands to columns of every table in FROM order.
	aliasOut := map[string]int{}
	for _, it := range s.items {
		if it.star {
			if len(sc.srcs) == 0 {
				semErr("no tables specified")
			}
			for slot, src := range sc.srcs {
				for col := range src.tbl.cols {
					if eb.grouped && !groupSet[[2]int{slot, col}] {
						semErr("column %s must appear in GROUP BY or an aggregate", src.tbl.cols[col])
					}
					p.items = append(p.items, &bexpr{kind: bCol, slot: slot, col: col})
				}
			}
			continue
		}
		if it.alias != "" {
			if _, dup := aliasOut[it.alias]; !dup {
				aliasOut[it.alias] = len(p.items)
			}
		}
		p.items = append(p.items, eb.bind(it.e))
	}

	if s.having != nil {
		p.having = eb.bind(s.having)
	}

	for _, t := range s.order {
		spec := orderSpec{out: -1, desc: t.desc}
		switch {
		case t.ordinal:
			if t.ival < 1 || t.ival > int64(len(p.items)) {
				semErr("ORDER BY position %d out of range", t.ival)
			}
			spec.out = int(t.ival) - 1
		case t.ident != "":
			if i, ok := aliasOut[t.ident]; ok {
				spec.out = i
			} else {
				spec.e = eb.bind(t.e)
			}
		default:
			spec.e = eb.bind(t.e)
		}
		p.order = append(p.order, spec)
	}

	return p
}

// planFilters classifies the conjuncts of ON and WHERE by the tables they read.
func (p *selectPlan) planFilters(conj []*bexpr) {
	if len(p.tables) < 2 {
		p.filterA = conj
		return
	}
	for _, c := range conj {
		switch c.usedSlots() {
		case 0, 1:
			p.filterA = append(p.filterA, c)
		case 2:
			p.filterB = append(p.filterB, c)
		default:
			if c.kind == bEq {
				lm, rm := c.l.usedSlots(), c.r.usedSlots()
				if lm == 1 && rm == 2 {
					p.keyA, p.keyB = append(p.keyA, c.l), append(p.keyB, c.r)
					continue
				}
				if lm == 2 && rm == 1 {
					p.keyA, p.keyB = append(p.keyA, c.r), append(p.keyB, c.l)
					continue
				}
			}
			p.resid = append(p.resid, c)
		}
	}
}
