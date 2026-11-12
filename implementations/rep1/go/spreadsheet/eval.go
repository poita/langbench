package spreadsheet

import "math"

// node is a syntax tree node. Evaluation reads the stored values of the cells
// it references and never evaluates them on demand.
type node interface {
	eval() Value
}

type (
	numNode   struct{ v float64 }
	strNode   struct{ s string }
	refNode   struct{ c *cell }
	negNode   struct{ x node }
	arithNode struct {
		op   byte // + - * /
		l, r node
	}
	catNode struct{ l, r node }
	cmpNode struct {
		op   string
		l, r node
	}
	ifNode  struct{ cond, a, b node }
	aggNode struct {
		fn   aggFunc
		args []aggArg
	}
	aggArg struct {
		expr  node    // set for an expression argument
		cells []*cell // set for a range argument, in row-major order
	}
)

type aggFunc uint8

const (
	aggSum aggFunc = iota
	aggMin
	aggMax
	aggAvg
	aggCount
)

func (n *numNode) eval() Value { return Number(n.v) }
func (n *strNode) eval() Value { return String(n.s) }
func (n *refNode) eval() Value { return n.c.value }

// operand evaluates x as an arithmetic operand. The returned error Value is
// meaningful only when ok is false.
func operand(x node) (f float64, bad Value, ok bool) {
	v := x.eval()
	switch v.kind {
	case KindError:
		return 0, v, false
	case KindString:
		return 0, Error(ErrValue), false
	case KindNumber:
		return v.num, Value{}, true
	}
	return 0, Value{}, true
}

func (n *negNode) eval() Value {
	f, bad, ok := operand(n.x)
	if !ok {
		return bad
	}
	return Number(-f)
}

func (n *arithNode) eval() Value {
	a, bad, ok := operand(n.l)
	if !ok {
		return bad
	}
	b, bad, ok := operand(n.r)
	if !ok {
		return bad
	}
	var r float64
	switch n.op {
	case '+':
		r = a + b
	case '-':
		r = a - b
	case '*':
		r = a * b
	default:
		if b == 0 {
			return Error(ErrDiv0)
		}
		r = a / b
	}
	return finite(r)
}

func finite(f float64) Value {
	if math.IsInf(f, 0) || math.IsNaN(f) {
		return Error(ErrValue)
	}
	return Number(f)
}

func (n *catNode) eval() Value {
	a := n.l.eval()
	if a.kind == KindError {
		return a
	}
	b := n.r.eval()
	if b.kind == KindError {
		return b
	}
	return String(a.String() + b.String())
}

func boolValue(b bool) Value {
	if b {
		return Number(1)
	}
	return Number(0)
}

func (n *cmpNode) eval() Value {
	a := n.l.eval()
	if a.kind == KindError {
		return a
	}
	b := n.r.eval()
	if b.kind == KindError {
		return b
	}
	switch {
	case a.kind == KindEmpty && b.kind == KindEmpty:
		a, b = Number(0), Number(0)
	case a.kind == KindEmpty:
		a = zeroLike(b)
	case b.kind == KindEmpty:
		b = zeroLike(a)
	}
	var c int // sign of a - b
	if a.kind != b.kind {
		switch n.op {
		case "=":
			return Number(0)
		case "<>":
			return Number(1)
		}
		return Error(ErrValue)
	}
	if a.kind == KindNumber {
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
	switch n.op {
	case "=":
		return boolValue(c == 0)
	case "<>":
		return boolValue(c != 0)
	case "<":
		return boolValue(c < 0)
	case ">":
		return boolValue(c > 0)
	case "<=":
		return boolValue(c <= 0)
	default:
		return boolValue(c >= 0)
	}
}

// zeroLike returns the value an empty operand takes when compared with o.
func zeroLike(o Value) Value {
	if o.kind == KindString {
		return String("")
	}
	return Number(0)
}

func (n *ifNode) eval() Value {
	c, bad, ok := operand(n.cond)
	if !ok {
		return bad
	}
	if c != 0 {
		return n.a.eval()
	}
	return n.b.eval()
}

func (n *aggNode) eval() Value {
	var (
		sum, lo, hi float64
		count       int
	)
	collect := func(f float64) {
		if count == 0 {
			lo, hi = f, f
		} else {
			lo, hi = math.Min(lo, f), math.Max(hi, f)
		}
		sum += f
		count++
	}
	for _, a := range n.args {
		if a.expr == nil {
			for _, c := range a.cells {
				switch c.value.kind {
				case KindError:
					return c.value
				case KindNumber:
					collect(c.value.num)
				}
			}
			continue
		}
		v := a.expr.eval()
		switch v.kind {
		case KindError:
			return v
		case KindString:
			return Error(ErrValue)
		case KindNumber:
			collect(v.num)
		}
	}
	switch n.fn {
	case aggCount:
		return Number(float64(count))
	case aggSum:
		return finite(sum)
	case aggMin:
		return Number(lo)
	case aggMax:
		return Number(hi)
	default:
		if count == 0 {
			return Error(ErrDiv0)
		}
		if math.IsInf(sum, 0) || math.IsNaN(sum) {
			return Error(ErrValue)
		}
		return Number(sum / float64(count))
	}
}
