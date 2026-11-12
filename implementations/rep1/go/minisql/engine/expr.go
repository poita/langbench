package engine

import (
	"minisql/value"
)

type op uint8

const (
	opLit op = iota
	opCol
	opAgg
	opNeg
	opNot
	opAnd
	opOr
	opAdd
	opSub
	opMul
	opDiv
	opMod
	opEq
	opNe
	opLt
	opLe
	opGt
	opGe
	opIsNull
	opIsNotNull
	opLike
)

// expr is a bound expression: every column reference has been resolved to a
// (source, column) pair and every aggregate call to an index into the
// aggregate results of the current group.
type expr struct {
	op   op
	l, r *expr
	lit  value.Value // opLit
	t, c int         // opCol: source index (0 or 1) and column index
	agg  int         // opAgg: index into env.agg
}

// env supplies the data an expression is evaluated against: at most two
// source rows (one per FROM table) and, in an aggregate query, the aggregate
// results of the current group.
type env struct {
	r   [2][]value.Value
	agg []value.Value
}

func eval(e *expr, en *env) value.Value {
	switch e.op {
	case opLit:
		return e.lit
	case opCol:
		return en.r[e.t][e.c]
	case opAgg:
		return en.agg[e.agg]
	case opNeg:
		v := eval(e.l, en)
		if v.Kind() == value.KindInt {
			return value.Int(-v.AsInt())
		}
		return value.Null()
	case opNot:
		t, known := eval(e.l, en).Truth()
		if !known {
			return value.Null()
		}
		return value.Bool(!t)
	case opAnd:
		lt, lk := eval(e.l, en).Truth()
		if lk && !lt {
			return value.Bool(false)
		}
		rt, rk := eval(e.r, en).Truth()
		if rk && !rt {
			return value.Bool(false)
		}
		if !lk || !rk {
			return value.Null()
		}
		return value.Bool(true)
	case opOr:
		lt, lk := eval(e.l, en).Truth()
		if lk && lt {
			return value.Bool(true)
		}
		rt, rk := eval(e.r, en).Truth()
		if rk && rt {
			return value.Bool(true)
		}
		if !lk || !rk {
			return value.Null()
		}
		return value.Bool(false)
	case opIsNull:
		return value.Bool(eval(e.l, en).IsNull())
	case opIsNotNull:
		return value.Bool(!eval(e.l, en).IsNull())
	case opLike:
		l, r := eval(e.l, en), eval(e.r, en)
		if l.IsNull() || r.IsNull() {
			return value.Null()
		}
		return value.Bool(value.Like(l.String(), r.String()))
	}
	l, r := eval(e.l, en), eval(e.r, en)
	if l.IsNull() || r.IsNull() {
		return value.Null()
	}
	switch e.op {
	case opEq:
		return value.Bool(value.Compare(l, r) == 0)
	case opNe:
		return value.Bool(value.Compare(l, r) != 0)
	case opLt:
		return value.Bool(value.Compare(l, r) < 0)
	case opLe:
		return value.Bool(value.Compare(l, r) <= 0)
	case opGt:
		return value.Bool(value.Compare(l, r) > 0)
	case opGe:
		return value.Bool(value.Compare(l, r) >= 0)
	}
	// Arithmetic is defined on INTEGERs only.
	if l.Kind() != value.KindInt || r.Kind() != value.KindInt {
		return value.Null()
	}
	a, b := l.AsInt(), r.AsInt()
	switch e.op {
	case opAdd:
		return value.Int(a + b)
	case opSub:
		return value.Int(a - b)
	case opMul:
		return value.Int(a * b)
	case opDiv:
		if b == 0 {
			return value.Null()
		}
		return value.Int(a / b)
	case opMod:
		if b == 0 {
			return value.Null()
		}
		return value.Int(a % b)
	}
	panic("engine: unknown operator")
}

// tableMask returns a bitmask of the FROM sources an expression reads.
func tableMask(e *expr) uint {
	if e == nil {
		return 0
	}
	m := tableMask(e.l) | tableMask(e.r)
	if e.op == opCol {
		m |= 1 << uint(e.t)
	}
	return m
}

// splitAnd appends the top-level AND conjuncts of e to out.
func splitAnd(e *expr, out []*expr) []*expr {
	if e == nil {
		return out
	}
	if e.op == opAnd {
		return splitAnd(e.r, splitAnd(e.l, out))
	}
	return append(out, e)
}

// aggSpec is one aggregate call found while binding a query.
type aggSpec struct {
	fn  string // COUNT, SUM, MIN, MAX or AVG
	arg *expr  // nil for COUNT(*)
}

// computeAggs evaluates every aggregate over the rows of one group.
func computeAggs(specs []aggSpec, rows []env) []value.Value {
	out := make([]value.Value, len(specs))
	for i, sp := range specs {
		out[i] = computeAgg(sp, rows)
	}
	return out
}

func computeAgg(sp aggSpec, rows []env) value.Value {
	if sp.arg == nil {
		return value.Int(int64(len(rows)))
	}
	var count, sum int64
	var best value.Value
	for i := range rows {
		v := eval(sp.arg, &rows[i])
		if v.IsNull() {
			continue
		}
		switch sp.fn {
		case "SUM", "AVG":
			sum += v.AsInt()
		case "MIN":
			if count == 0 || value.Compare(v, best) < 0 {
				best = v
			}
		case "MAX":
			if count == 0 || value.Compare(v, best) > 0 {
				best = v
			}
		}
		count++
	}
	switch sp.fn {
	case "COUNT":
		return value.Int(count)
	case "SUM":
		if count == 0 {
			return value.Null()
		}
		return value.Int(sum)
	case "AVG":
		if count == 0 {
			return value.Null()
		}
		return value.Avg(sum, count)
	}
	return best // MIN / MAX; NULL when count == 0
}
