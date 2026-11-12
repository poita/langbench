package engine

import (
	"minisql/syntax"
	"minisql/value"
)

// source is one table of a FROM clause under its effective name.
type source struct {
	name  string // alias if given, else table name
	table *Table
}

// scope is the set of sources column references are resolved against.
type scope struct {
	srcs []source
}

func (s *scope) resolve(qual, name string) (t, c int, err error) {
	if qual != "" {
		for i, src := range s.srcs {
			if src.name == qual {
				if c := src.table.columnIndex(name); c >= 0 {
					return i, c, nil
				}
				return 0, 0, errorf("no such column: %s.%s", qual, name)
			}
		}
		return 0, 0, errorf("no such table: %s", qual)
	}
	t, c = -1, -1
	for i, src := range s.srcs {
		if j := src.table.columnIndex(name); j >= 0 {
			if t >= 0 {
				return 0, 0, errorf("ambiguous column: %s", name)
			}
			t, c = i, j
		}
	}
	if t < 0 {
		return 0, 0, errorf("no such column: %s", name)
	}
	return t, c, nil
}

// binder turns syntax trees into bound expressions.
type binder struct {
	scope    *scope
	allowAgg bool       // aggregate calls are permitted
	grouped  bool       // outside aggregate calls only grouping columns may be read
	groupBy  [][2]int   // the (source, column) pairs of the GROUP BY terms
	aggs     *[]aggSpec // receives the aggregate calls found
	inAgg    bool       // currently inside an aggregate call's argument
}

var binaryOps = map[string]op{
	"AND": opAnd, "OR": opOr, "+": opAdd, "-": opSub, "*": opMul, "/": opDiv, "%": opMod,
	"=": opEq, "!=": opNe, "<": opLt, "<=": opLe, ">": opGt, ">=": opGe,
}

func (b *binder) bind(e *syntax.Expr) (*expr, error) {
	switch e.Kind {
	case syntax.ExprInt:
		return &expr{op: opLit, lit: value.Int(e.Int)}, nil
	case syntax.ExprString:
		return &expr{op: opLit, lit: value.Text(e.Str)}, nil
	case syntax.ExprNull:
		return &expr{op: opLit}, nil
	case syntax.ExprParen:
		return b.bind(e.Left)
	case syntax.ExprColumn:
		t, c, err := b.scope.resolve(e.Qual, e.Name)
		if err != nil {
			return nil, err
		}
		if b.grouped && !b.inAgg && !b.isGrouping(t, c) {
			return nil, errorf("column %s must appear in GROUP BY or inside an aggregate", e.Name)
		}
		return &expr{op: opCol, t: t, c: c}, nil
	case syntax.ExprAgg:
		return b.bindAgg(e)
	case syntax.ExprNeg, syntax.ExprNot, syntax.ExprIsNull:
		l, err := b.bind(e.Left)
		if err != nil {
			return nil, err
		}
		n := &expr{l: l}
		switch {
		case e.Kind == syntax.ExprNeg:
			n.op = opNeg
		case e.Kind == syntax.ExprNot:
			n.op = opNot
		case e.Negated:
			n.op = opIsNotNull
		default:
			n.op = opIsNull
		}
		return n, nil
	case syntax.ExprBinary, syntax.ExprLike:
		l, err := b.bind(e.Left)
		if err != nil {
			return nil, err
		}
		r, err := b.bind(e.Right)
		if err != nil {
			return nil, err
		}
		o := opLike
		if e.Kind == syntax.ExprBinary {
			o = binaryOps[e.Op]
		}
		return &expr{op: o, l: l, r: r}, nil
	}
	return nil, errorf("unsupported expression")
}

func (b *binder) isGrouping(t, c int) bool {
	for _, g := range b.groupBy {
		if g[0] == t && g[1] == c {
			return true
		}
	}
	return false
}

func (b *binder) bindAgg(e *syntax.Expr) (*expr, error) {
	if !b.allowAgg {
		return nil, errorf("aggregate function %s not allowed here", e.Func)
	}
	if b.inAgg {
		return nil, errorf("nested aggregate function")
	}
	spec := aggSpec{fn: e.Func}
	if e.Left != nil {
		b.inAgg = true
		arg, err := b.bind(e.Left)
		b.inAgg = false
		if err != nil {
			return nil, err
		}
		spec.arg = arg
	}
	*b.aggs = append(*b.aggs, spec)
	return &expr{op: opAgg, agg: len(*b.aggs) - 1}, nil
}

// bindOpt binds e, passing nil through.
func (b *binder) bindOpt(e *syntax.Expr) (*expr, error) {
	if e == nil {
		return nil, nil
	}
	return b.bind(e)
}

// hasAggregate reports whether e contains an aggregate call.
func hasAggregate(e *syntax.Expr) bool {
	if e == nil {
		return false
	}
	return e.Kind == syntax.ExprAgg || hasAggregate(e.Left) || hasAggregate(e.Right)
}
