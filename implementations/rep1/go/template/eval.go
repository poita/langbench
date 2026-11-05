package template

func (e *constExpr) eval(r *rendering, sc *scope) Value { return e.v }

func (e *nameExpr) eval(r *rendering, sc *scope) Value {
	if v, ok := sc.lookup(e.name); ok {
		return v
	}
	if e.isRange {
		return rangeBuiltin
	}
	return Undefined
}

func (e *listExpr) eval(r *rendering, sc *scope) Value {
	items := make([]Value, len(e.elems))
	for i, x := range e.elems {
		items[i] = x.eval(r, sc)
	}
	return &List{Items: items}
}

func (e *negExpr) eval(r *rendering, sc *scope) Value { return negate(e.x.eval(r, sc)) }

func (e *notExpr) eval(r *rendering, sc *scope) Value { return !truthy(e.x.eval(r, sc)) }

func (e *andExpr) eval(r *rendering, sc *scope) Value {
	l := e.l.eval(r, sc)
	if !truthy(l) {
		return l
	}
	return e.r.eval(r, sc)
}

func (e *orExpr) eval(r *rendering, sc *scope) Value {
	l := e.l.eval(r, sc)
	if truthy(l) {
		return l
	}
	return e.r.eval(r, sc)
}

func (e *binExpr) eval(r *rendering, sc *scope) Value {
	l := e.l.eval(r, sc)
	rv := e.r.eval(r, sc)
	return binaryOp(e.op, l, rv)
}

func (e *cmpExpr) eval(r *rendering, sc *scope) Value {
	left := e.first.eval(r, sc)
	for i, op := range e.ops {
		right := e.rest[i].eval(r, sc)
		if !compareOp(op, left, right) {
			return false
		}
		left = right
	}
	return true
}

func (e *filterExpr) eval(r *rendering, sc *scope) Value {
	in := e.x.eval(r, sc)
	var args []Value
	if len(e.args) > 0 {
		args = make([]Value, len(e.args))
		for i, a := range e.args {
			args[i] = a.eval(r, sc)
		}
	}
	return applyFilter(e.code, in, args)
}

func (e *definedExpr) eval(r *rendering, sc *scope) Value {
	return IsUndefined(e.x.eval(r, sc)) == e.negate
}

func (e *attrExpr) eval(r *rendering, sc *scope) Value {
	return getItem(e.x.eval(r, sc), e.key)
}

func (e *indexExpr) eval(r *rendering, sc *scope) Value {
	x := e.x.eval(r, sc)
	return getItem(x, e.idx.eval(r, sc))
}

func (e *callExpr) eval(r *rendering, sc *scope) Value {
	fn := e.fn.eval(r, sc)
	var args, kwVals []Value
	if len(e.args) > 0 {
		args = make([]Value, len(e.args))
		for i, a := range e.args {
			args[i] = a.eval(r, sc)
		}
	}
	if len(e.kwVals) > 0 {
		kwVals = make([]Value, len(e.kwVals))
		for i, a := range e.kwVals {
			kwVals[i] = a.eval(r, sc)
		}
	}
	switch f := fn.(type) {
	case *macroValue:
		return f.call(args, e.kwNames, kwVals)
	case *rangeFn:
		return callRange(args, kwVals)
	case *superFn:
		if len(args) > 0 || len(kwVals) > 0 {
			throw(ErrType, "super takes no arguments")
		}
		return f.call()
	case undefinedType:
		throw(ErrUndefined, "call of undefined value")
	}
	throw(ErrType, "value is not callable")
	return nil
}

// callRange implements the built-in range function.
func callRange(args, kwVals []Value) Value {
	if len(kwVals) > 0 {
		throw(ErrType, "range takes no keyword arguments")
	}
	if len(args) < 1 || len(args) > 3 {
		throw(ErrType, "range takes 1 to 3 arguments")
	}
	var n [3]int64
	for i, a := range args {
		if IsUndefined(a) {
			throw(ErrUndefined, "undefined range argument")
		}
		v, _, k := num(a)
		if k != nkInt {
			throw(ErrType, "range arguments must be integers")
		}
		n[i] = v
	}
	start, stop, step := int64(0), n[0], int64(1)
	if len(args) >= 2 {
		start, stop = n[0], n[1]
	}
	if len(args) == 3 {
		step = n[2]
	}
	if step == 0 {
		throw(ErrType, "range step must not be zero")
	}
	var items []Value
	if step > 0 && stop > start {
		items = make([]Value, 0, (stop-start+step-1)/step)
	} else if step < 0 && start > stop {
		items = make([]Value, 0, (start-stop-step-1)/(-step))
	}
	if step > 0 {
		for i := start; i < stop; i += step {
			items = append(items, i)
		}
	} else {
		for i := start; i > stop; i += step {
			items = append(items, i)
		}
	}
	return &List{Items: items}
}
