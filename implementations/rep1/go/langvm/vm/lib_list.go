package vm

func init() {
	register("listNew", func(m *VM, a []Value) Value { return List(nil) })
	register("listLen", func(m *VM, a []Value) Value { return Int(int64(len(a[0].P.V))) })
	register("push", func(m *VM, a []Value) Value {
		o := a[0].P
		o.V = append(o.V, a[1])
		return Unit
	})
	register("pop", func(m *VM, a []Value) Value {
		o := a[0].P
		n := len(o.V)
		if n == 0 {
			m.Panic("empty list")
		}
		v := o.V[n-1]
		o.V[n-1] = Value{}
		o.V = o.V[:n-1]
		return v
	})
	register("insert", func(m *VM, a []Value) Value {
		o := a[0].P
		i := a[1].N
		n := len(o.V)
		if i < 0 || i > int64(n) {
			m.Panic("index out of bounds")
		}
		o.V = append(o.V, Value{})
		copy(o.V[i+1:], o.V[i:n])
		o.V[i] = a[2]
		return Unit
	})
	register("removeAt", func(m *VM, a []Value) Value {
		o := a[0].P
		i := a[1].N
		n := len(o.V)
		if i < 0 || i >= int64(n) {
			m.Panic("index out of bounds")
		}
		v := o.V[i]
		copy(o.V[i:], o.V[i+1:])
		o.V[n-1] = Value{}
		o.V = o.V[:n-1]
		return v
	})
	register("clear", func(m *VM, a []Value) Value {
		o := a[0].P
		for i := range o.V {
			o.V[i] = Value{}
		}
		o.V = o.V[:0]
		return Unit
	})
	register("listRepeat", func(m *VM, a []Value) Value {
		n := a[1].N
		if n < 0 {
			m.Panic("negative count")
		}
		out := make([]Value, n)
		for i := range out {
			out[i] = a[0]
		}
		return List(out)
	})
	register("listConcat", func(m *VM, a []Value) Value {
		x, y := a[0].P.V, a[1].P.V
		out := make([]Value, len(x)+len(y))
		copy(out, x)
		copy(out[len(x):], y)
		return List(out)
	})
	register("slice", func(m *VM, a []Value) Value {
		xs := a[0].P.V
		from, to := a[1].N, a[2].N
		if from < 0 || from > to || to > int64(len(xs)) {
			m.Panic("index out of bounds")
		}
		out := make([]Value, to-from)
		copy(out, xs[from:to])
		return List(out)
	})
	register("listCopy", func(m *VM, a []Value) Value {
		xs := a[0].P.V
		out := make([]Value, len(xs))
		copy(out, xs)
		return List(out)
	})
	register("reverseList", func(m *VM, a []Value) Value {
		xs := a[0].P.V
		n := len(xs)
		out := make([]Value, n)
		for i, v := range xs {
			out[n-1-i] = v
		}
		return List(out)
	})
	register("listFirst", func(m *VM, a []Value) Value {
		xs := a[0].P.V
		if len(xs) == 0 {
			m.Panic("empty list")
		}
		return xs[0]
	})
	register("listLast", func(m *VM, a []Value) Value {
		xs := a[0].P.V
		if len(xs) == 0 {
			m.Panic("empty list")
		}
		return xs[len(xs)-1]
	})
	register("listMap", func(m *VM, a []Value) Value {
		o, f := a[0].P, a[1]
		out := make([]Value, 0, len(o.V))
		for i := 0; i < len(o.V); i++ {
			out = append(out, m.Call1(f, o.V[i]))
		}
		return List(out)
	})
	register("listFilter", func(m *VM, a []Value) Value {
		o, f := a[0].P, a[1]
		var out []Value
		for i := 0; i < len(o.V); i++ {
			v := o.V[i]
			if m.Call1(f, v).N != 0 {
				out = append(out, v)
			}
		}
		return List(out)
	})
	register("listFold", func(m *VM, a []Value) Value {
		o, acc, f := a[0].P, a[1], a[2]
		for i := 0; i < len(o.V); i++ {
			acc = m.Call2(f, acc, o.V[i])
		}
		return acc
	})
	register("listAny", func(m *VM, a []Value) Value {
		o, f := a[0].P, a[1]
		for i := 0; i < len(o.V); i++ {
			if m.Call1(f, o.V[i]).N != 0 {
				return Bool(true)
			}
		}
		return Bool(false)
	})
	register("listAll", func(m *VM, a []Value) Value {
		o, f := a[0].P, a[1]
		for i := 0; i < len(o.V); i++ {
			if m.Call1(f, o.V[i]).N == 0 {
				return Bool(false)
			}
		}
		return Bool(true)
	})
	register("listFind", func(m *VM, a []Value) Value {
		o, f := a[0].P, a[1]
		for i := 0; i < len(o.V); i++ {
			v := o.V[i]
			if m.Call1(f, v).N != 0 {
				return Some(v)
			}
		}
		return NoneV
	})
	register("listFindIndex", func(m *VM, a []Value) Value {
		o, f := a[0].P, a[1]
		for i := 0; i < len(o.V); i++ {
			if m.Call1(f, o.V[i]).N != 0 {
				return Int(int64(i))
			}
		}
		return Int(-1)
	})
	register("listIndexOf", func(m *VM, a []Value) Value { return Int(listIndexOf(a[0].P, a[1])) })
	register("listContains", func(m *VM, a []Value) Value { return Bool(listIndexOf(a[0].P, a[1]) >= 0) })
	register("listZip", func(m *VM, a []Value) Value {
		x, y := a[0].P.V, a[1].P.V
		n := len(x)
		if len(y) < n {
			n = len(y)
		}
		out := make([]Value, n)
		for i := 0; i < n; i++ {
			out[i] = Tuple([]Value{x[i], y[i]})
		}
		return List(out)
	})
	register("listFlatten", func(m *VM, a []Value) Value {
		xss := a[0].P.V
		total := 0
		for _, xs := range xss {
			total += len(xs.P.V)
		}
		out := make([]Value, 0, total)
		for _, xs := range xss {
			out = append(out, xs.P.V...)
		}
		return List(out)
	})
	register("sortBy", libSortBy)
}

func listIndexOf(o *Obj, x Value) int64 {
	scalar := x.P.Kind <= KChar && x.P.Kind != KFloat
	for i := 0; i < len(o.V); i++ {
		if scalar {
			if o.V[i].N == x.N {
				return int64(i)
			}
		} else if Equal(o.V[i], x) {
			return int64(i)
		}
	}
	return -1
}

// libSortBy implements sortBy on top of mergeSort.
func libSortBy(m *VM, a []Value) Value {
	cmp := a[1]
	src := make([]Value, len(a[0].P.V))
	copy(src, a[0].P.V)
	return List(mergeSort(src, func(x, y Value) int64 { return m.Call2(cmp, x, y).N }))
}

// mergeSort is the bottom-up merge sort of SPEC 15.6. It takes ownership of
// src (a private copy) and returns the sorted slice.
func mergeSort(src []Value, cmp func(x, y Value) int64) []Value {
	n := len(src)
	if n <= 1 {
		return src
	}
	dst := make([]Value, n)
	for width := 1; width < n; width *= 2 {
		for i := 0; i < n; i += 2 * width {
			lo := i
			mid := i + width
			if mid > n {
				mid = n
			}
			hi := i + 2*width
			if hi > n {
				hi = n
			}
			p, q, k := lo, mid, lo
			for p < mid && q < hi {
				if cmp(src[p], src[q]) <= 0 {
					dst[k] = src[p]
					p++
				} else {
					dst[k] = src[q]
					q++
				}
				k++
			}
			for p < mid {
				dst[k] = src[p]
				p++
				k++
			}
			for q < hi {
				dst[k] = src[q]
				q++
				k++
			}
		}
		src, dst = dst, src
	}
	return src
}
