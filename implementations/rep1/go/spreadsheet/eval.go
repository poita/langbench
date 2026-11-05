package spreadsheet

import (
	"math"

	"example.com/spreadsheet/formula"
	"example.com/spreadsheet/numfmt"
)

// eval interprets node i of e against the stored values of the cells it
// reads. References never trigger evaluation of other cells. The result may
// be Empty (a bare reference to an empty cell); the caller turns that into 0.
func (s *Sheet) eval(e *formula.Expr, i int32) Value {
	if e.Invalid {
		return ErrorValue(ErrRef)
	}
	return s.evalNode(e, i)
}

// operand coerces v for arithmetic. ok == false means the operation stops
// with result err.
func operand(v Value) (f float64, err Value, ok bool) {
	switch v.kind {
	case Number:
		return v.num, Value{}, true
	case Empty:
		return 0, Value{}, true
	case Error:
		return 0, v, false
	}
	return 0, ErrorValue(ErrValue), false
}

func boolValue(b bool) Value {
	if b {
		return Value{kind: Number, num: 1}
	}
	return Value{kind: Number, num: 0}
}

func (s *Sheet) evalNode(e *formula.Expr, i int32) Value {
	n := &e.Nodes[i]
	switch n.Kind {
	case formula.KindNum:
		return Value{kind: Number, num: n.Num}
	case formula.KindStr:
		return Value{kind: String, str: n.Str}
	case formula.KindRef:
		return s.cells[n.Cell].val
	case formula.KindNeg:
		f, err, ok := operand(s.evalNode(e, n.A))
		if !ok {
			return err
		}
		return NumberValue(-f)
	case formula.KindIf:
		f, err, ok := operand(s.evalNode(e, n.A))
		if !ok {
			return err
		}
		if f != 0 {
			return s.evalNode(e, n.B)
		}
		return s.evalNode(e, n.C)
	case formula.KindAgg:
		return s.evalAgg(e, n)
	case formula.KindBin:
		return s.evalBin(e, n)
	}
	return ErrorValue(ErrValue)
}

func (s *Sheet) evalBin(e *formula.Expr, n *formula.Node) Value {
	op := formula.BinOp(n.Op)
	a := s.evalNode(e, n.A)
	switch op {
	case formula.OpAdd, formula.OpSub, formula.OpMul, formula.OpDiv:
		x, err, ok := operand(a)
		if !ok {
			return err
		}
		y, err, ok := operand(s.evalNode(e, n.B))
		if !ok {
			return err
		}
		var r float64
		switch op {
		case formula.OpAdd:
			r = x + y
		case formula.OpSub:
			r = x - y
		case formula.OpMul:
			r = x * y
		default:
			if y == 0 {
				return ErrorValue(ErrDiv0)
			}
			r = x / y
		}
		if math.IsInf(r, 0) || math.IsNaN(r) {
			return ErrorValue(ErrValue)
		}
		return NumberValue(r)
	case formula.OpCat:
		if a.kind == Error {
			return a
		}
		b := s.evalNode(e, n.B)
		if b.kind == Error {
			return b
		}
		buf := appendText(s.scratch[:0], a)
		buf = appendText(buf, b)
		s.scratch = buf
		return Value{kind: String, str: string(buf)}
	}
	// Comparisons.
	if a.kind == Error {
		return a
	}
	b := s.evalNode(e, n.B)
	if b.kind == Error {
		return b
	}
	switch {
	case a.kind == Empty && b.kind == Empty:
		a, b = Value{kind: Number}, Value{kind: Number}
	case a.kind == Empty:
		a = emptyLike(b)
	case b.kind == Empty:
		b = emptyLike(a)
	}
	if a.kind != b.kind {
		switch op {
		case formula.OpEq:
			return boolValue(false)
		case formula.OpNe:
			return boolValue(true)
		}
		return ErrorValue(ErrValue)
	}
	var c int
	if a.kind == Number {
		switch {
		case a.num < b.num:
			c = -1
		case a.num > b.num:
			c = 1
		}
	} else {
		switch {
		case a.str < b.str:
			c = -1
		case a.str > b.str:
			c = 1
		}
	}
	switch op {
	case formula.OpEq:
		return boolValue(c == 0)
	case formula.OpNe:
		return boolValue(c != 0)
	case formula.OpLt:
		return boolValue(c < 0)
	case formula.OpGt:
		return boolValue(c > 0)
	case formula.OpLe:
		return boolValue(c <= 0)
	}
	return boolValue(c >= 0)
}

// emptyLike returns the value an empty operand takes when compared with o.
func emptyLike(o Value) Value {
	if o.kind == String {
		return Value{kind: String}
	}
	return Value{kind: Number}
}

// appendText appends the text form of v (as used by '&').
func appendText(dst []byte, v Value) []byte {
	switch v.kind {
	case String:
		return append(dst, v.str...)
	case Number:
		return numfmt.Append(dst, v.num)
	}
	return dst
}

// evalAgg streams over the arguments of SUM/MIN/MAX/AVG/COUNT in one pass.
func (s *Sheet) evalAgg(e *formula.Expr, n *formula.Node) Value {
	var count int
	var sum, lo, hi float64
	collect := func(f float64) {
		if count == 0 {
			lo, hi = f, f
		} else {
			lo = math.Min(lo, f)
			hi = math.Max(hi, f)
		}
		count++
		sum += f
	}
	for _, a := range n.Args {
		an := &e.Nodes[a]
		if an.Kind == formula.KindRange {
			for _, h := range an.Cells {
				v := &s.cells[h].val
				switch v.kind {
				case Error:
					return *v
				case Number:
					collect(v.num)
				}
			}
			continue
		}
		v := s.evalNode(e, a)
		switch v.kind {
		case Error:
			return v
		case String:
			return ErrorValue(ErrValue)
		case Number:
			collect(v.num)
		}
	}
	switch formula.AggFn(n.Op) {
	case formula.FnCount:
		return NumberValue(float64(count))
	case formula.FnMin:
		return NumberValue(lo)
	case formula.FnMax:
		return NumberValue(hi)
	case formula.FnSum:
		if math.IsInf(sum, 0) || math.IsNaN(sum) {
			return ErrorValue(ErrValue)
		}
		return NumberValue(sum)
	}
	// FnAvg
	if count == 0 {
		return ErrorValue(ErrDiv0)
	}
	if math.IsInf(sum, 0) || math.IsNaN(sum) {
		return ErrorValue(ErrValue)
	}
	return NumberValue(sum / float64(count))
}
