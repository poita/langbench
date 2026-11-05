package minisql

import "strconv"

// bkind is the node kind of a bound expression.
type bkind uint8

const (
	bConst bkind = iota
	bCol
	bAgg
	bNeg
	bNot
	bAnd
	bOr
	bAdd
	bSub
	bMul
	bDiv
	bMod
	bEq
	bNe
	bLt
	bLe
	bGt
	bGe
	bIsNull
	bIsNotNull
	bLike
	bNotLike
)

// bexpr is an executable expression: names are resolved to (slot, column)
// pairs, literals are ready values and aggregates are slot indices.
type bexpr struct {
	kind bkind
	l, r *bexpr
	c    Value // bConst
	slot int   // bCol: FROM table position
	col  int   // bCol: column index
	idx  int   // bAgg: aggregate slot
}

// evalCtx is the evaluation context: the current row of each FROM table and
// the finished aggregate values of the current group.
type evalCtx struct {
	rows [2][]Value
	aggs []Value
}

func (e *bexpr) eval(c *evalCtx) Value {
	switch e.kind {
	case bConst:
		return e.c
	case bCol:
		return c.rows[e.slot][e.col]
	case bAgg:
		return c.aggs[e.idx]
	case bNeg:
		v := e.l.eval(c)
		if v.kind == KindInteger {
			return Int(-v.i)
		}
		return Null()
	case bNot:
		switch e.l.eval(c).truth() {
		case triTrue:
			return Int(0)
		case triFalse:
			return Int(1)
		}
		return Null()
	case bAnd:
		a := e.l.eval(c).truth()
		if a == triFalse {
			return Int(0)
		}
		b := e.r.eval(c).truth()
		if b == triFalse {
			return Int(0)
		}
		if a == triNull || b == triNull {
			return Null()
		}
		return Int(1)
	case bOr:
		a := e.l.eval(c).truth()
		if a == triTrue {
			return Int(1)
		}
		b := e.r.eval(c).truth()
		if b == triTrue {
			return Int(1)
		}
		if a == triNull || b == triNull {
			return Null()
		}
		return Int(0)
	case bIsNull:
		return boolValue(e.l.eval(c).kind == KindNull)
	case bIsNotNull:
		return boolValue(e.l.eval(c).kind != KindNull)
	case bLike, bNotLike:
		a, b := e.l.eval(c), e.r.eval(c)
		if a.kind == KindNull || b.kind == KindNull {
			return Null()
		}
		var abuf, bbuf [24]byte
		m := like(textOf(a, abuf[:0]), textOf(b, bbuf[:0]))
		return boolValue(m == (e.kind == bLike))
	}
	a, b := e.l.eval(c), e.r.eval(c)
	if a.kind == KindNull || b.kind == KindNull {
		return Null()
	}
	switch e.kind {
	case bEq:
		return boolValue(Compare(a, b) == 0)
	case bNe:
		return boolValue(Compare(a, b) != 0)
	case bLt:
		return boolValue(Compare(a, b) < 0)
	case bLe:
		return boolValue(Compare(a, b) <= 0)
	case bGt:
		return boolValue(Compare(a, b) > 0)
	case bGe:
		return boolValue(Compare(a, b) >= 0)
	}
	// Arithmetic is defined on INTEGERs only.
	if a.kind != KindInteger || b.kind != KindInteger {
		return Null()
	}
	switch e.kind {
	case bAdd:
		return Int(a.i + b.i)
	case bSub:
		return Int(a.i - b.i)
	case bMul:
		return Int(a.i * b.i)
	case bDiv:
		if b.i == 0 {
			return Null()
		}
		return Int(a.i / b.i)
	case bMod:
		if b.i == 0 {
			return Null()
		}
		return Int(a.i % b.i)
	}
	return Null()
}

// textOf returns v as text for LIKE, formatting integers into scratch.
func textOf(v Value, scratch []byte) string {
	switch v.kind {
	case KindText:
		return v.s
	case KindInteger:
		return string(strconv.AppendInt(scratch, v.i, 10))
	}
	return string(v.appendTo(scratch))
}

// usedSlots returns a bitmask of the FROM tables the expression reads.
func (e *bexpr) usedSlots() uint8 {
	if e == nil {
		return 0
	}
	var m uint8
	if e.kind == bCol {
		m = 1 << uint(e.slot)
	}
	return m | e.l.usedSlots() | e.r.usedSlots()
}

// splitAnd appends the top-level AND conjuncts of e to out.
func splitAnd(e *bexpr, out []*bexpr) []*bexpr {
	if e == nil {
		return out
	}
	if e.kind == bAnd {
		return splitAnd(e.r, splitAnd(e.l, out))
	}
	return append(out, e)
}
