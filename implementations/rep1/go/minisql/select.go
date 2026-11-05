package minisql

import "slices"

// accum is a streaming aggregate accumulator.
type accum struct {
	count int64
	sum   int64
	val   Value // current MIN / MAX
	has   bool
}

func (a *accum) add(s *aggSpec, c *evalCtx) {
	if s.star {
		a.count++
		return
	}
	v := s.arg.eval(c)
	if v.kind == KindNull {
		return
	}
	a.count++
	switch s.fn {
	case aggSum, aggAvg:
		a.sum += v.i
	case aggMin:
		if !a.has || Compare(v, a.val) < 0 {
			a.val, a.has = v, true
		}
	case aggMax:
		if !a.has || Compare(v, a.val) > 0 {
			a.val, a.has = v, true
		}
	}
}

func (a *accum) result(fn aggFn) Value {
	switch fn {
	case aggCount:
		return Int(a.count)
	case aggSum:
		if a.count == 0 {
			return Null()
		}
		return Int(a.sum)
	case aggMin, aggMax:
		if !a.has {
			return Null()
		}
		return a.val
	}
	// AVG: hundredths = (200*|s| + c) div (2c), half away from zero.
	if a.count == 0 {
		return Null()
	}
	s := a.sum
	if s < 0 {
		s = -s
	}
	h := (200*s + a.count) / (2 * a.count)
	if a.sum < 0 {
		h = -h
	}
	return RealHundredths(h)
}

type group struct {
	rep  [2][]Value // first row of the group (for grouping columns)
	keys []Value
	accs []accum
}

type resRow struct {
	vals []Value
	keys []Value
}

// scan streams every candidate row (or row pair, in nested-loop order) that
// passes the filters to emit.
func (p *selectPlan) scan(emit func(*evalCtx)) {
	var ctx evalCtx
	switch len(p.tables) {
	case 0:
		if allTrue(p.filterA, &ctx) {
			emit(&ctx)
		}
		return
	case 1:
		for _, row := range p.tables[0].rows {
			ctx.rows[0] = row
			if allTrue(p.filterA, &ctx) {
				emit(&ctx)
			}
		}
		return
	}

	// Two tables: filter the second table once, then hash-join (or
	// nested-loop) against the filtered first table.
	rowsA, rowsB := p.tables[0].rows, p.tables[1].rows
	passB := make([]int32, 0, len(rowsB))
	for i, row := range rowsB {
		ctx.rows[1] = row
		if allTrue(p.filterB, &ctx) {
			passB = append(passB, int32(i))
		}
	}
	ctx.rows[1] = nil

	if len(p.keyA) == 0 {
		for _, ra := range rowsA {
			ctx.rows[0] = ra
			if !allTrue(p.filterA, &ctx) {
				continue
			}
			for _, bi := range passB {
				ctx.rows[1] = rowsB[bi]
				if allTrue(p.resid, &ctx) {
					emit(&ctx)
				}
			}
		}
		return
	}

	var buf []byte
	encode := func(keys []*bexpr) ([]byte, bool) {
		buf = buf[:0]
		for _, k := range keys {
			v := k.eval(&ctx)
			if v.kind == KindNull {
				return nil, false
			}
			buf = appendKey(buf, v)
		}
		return buf, true
	}
	buckets := map[string]int32{}
	var lists [][]int32
	for _, bi := range passB {
		ctx.rows[1] = rowsB[bi]
		key, ok := encode(p.keyB)
		if !ok {
			continue
		}
		id, found := buckets[string(key)]
		if !found {
			id = int32(len(lists))
			buckets[string(key)] = id
			lists = append(lists, nil)
		}
		lists[id] = append(lists[id], bi)
	}
	ctx.rows[1] = nil
	for _, ra := range rowsA {
		ctx.rows[0] = ra
		if !allTrue(p.filterA, &ctx) {
			continue
		}
		key, ok := encode(p.keyA)
		if !ok {
			continue
		}
		id, found := buckets[string(key)]
		if !found {
			continue
		}
		for _, bi := range lists[id] {
			ctx.rows[1] = rowsB[bi]
			if allTrue(p.resid, &ctx) {
				emit(&ctx)
			}
		}
	}
}

func (p *selectPlan) project(ctx *evalCtx) resRow {
	r := resRow{vals: make([]Value, len(p.items))}
	for i, e := range p.items {
		r.vals[i] = e.eval(ctx)
	}
	if len(p.order) > 0 {
		r.keys = make([]Value, len(p.order))
		for i, o := range p.order {
			if o.e != nil {
				r.keys[i] = o.e.eval(ctx)
			} else {
				r.keys[i] = r.vals[o.out]
			}
		}
	}
	return r
}

func (db *DB) execSelect(p *selectPlan) *Result {
	var out []resRow
	if !p.aggQuery {
		p.scan(func(ctx *evalCtx) { out = append(out, p.project(ctx)) })
	} else {
		out = p.aggregate()
	}

	if len(p.order) > 0 {
		slices.SortStableFunc(out, func(a, b resRow) int {
			for i, o := range p.order {
				c := Compare(a.keys[i], b.keys[i])
				if o.desc {
					c = -c
				}
				if c != 0 {
					return c
				}
			}
			return 0
		})
	}

	if p.offset > 0 {
		if p.offset >= int64(len(out)) {
			out = nil
		} else {
			out = out[p.offset:]
		}
	}
	if p.limit >= 0 && p.limit < int64(len(out)) {
		out = out[:p.limit]
	}
	res := &Result{Rows: make([][]Value, len(out))}
	for i, r := range out {
		res.Rows[i] = r.vals
	}
	return res
}

// aggregate runs the scan through streaming accumulators, then evaluates
// HAVING and the select list once per group, in ascending grouping order.
func (p *selectPlan) aggregate() []resRow {
	var groups []*group
	newGroup := func(ctx *evalCtx) *group {
		g := &group{rep: ctx.rows, accs: make([]accum, len(p.aggs))}
		g.keys = make([]Value, len(p.groupCols))
		for i, gc := range p.groupCols {
			g.keys[i] = ctx.rows[gc[0]][gc[1]]
		}
		groups = append(groups, g)
		return g
	}

	if len(p.groupCols) == 0 {
		// One group, even over zero rows; it has no representative row
		// because bare columns are rejected at bind time.
		g := newGroup(&evalCtx{})
		p.scan(func(ctx *evalCtx) {
			for i := range p.aggs {
				g.accs[i].add(&p.aggs[i], ctx)
			}
		})
	} else {
		index := map[string]*group{}
		var buf []byte
		p.scan(func(ctx *evalCtx) {
			buf = buf[:0]
			for _, gc := range p.groupCols {
				buf = appendKey(buf, ctx.rows[gc[0]][gc[1]])
			}
			g, ok := index[string(buf)]
			if !ok {
				g = newGroup(ctx)
				index[string(buf)] = g
			}
			for i := range p.aggs {
				g.accs[i].add(&p.aggs[i], ctx)
			}
		})
		slices.SortFunc(groups, func(a, b *group) int {
			for i := range a.keys {
				if c := Compare(a.keys[i], b.keys[i]); c != 0 {
					return c
				}
			}
			return 0
		})
	}

	var out []resRow
	aggVals := make([]Value, len(p.aggs))
	for _, g := range groups {
		for i := range p.aggs {
			aggVals[i] = g.accs[i].result(p.aggs[i].fn)
		}
		ctx := evalCtx{rows: g.rep, aggs: aggVals}
		if p.having != nil && p.having.eval(&ctx).truth() != triTrue {
			continue
		}
		out = append(out, p.project(&ctx))
	}
	return out
}
