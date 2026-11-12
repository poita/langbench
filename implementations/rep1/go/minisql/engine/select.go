package engine

import (
	"slices"
	"sort"

	"minisql/syntax"
	"minisql/value"
)

// orderKey is a bound ORDER BY term: either a reference to an output column
// (alias or ordinal) or an expression evaluated against the source row/group.
type orderKey struct {
	out  int // output column index, or -1
	e    *expr
	desc bool
}

// outRow is an output row together with its sort keys.
type outRow struct {
	vals []value.Value
	keys []value.Value
}

func (db *Database) execSelect(s *syntax.Select) (*Result, error) {
	// ---- bind -------------------------------------------------------
	sc := &scope{}
	for _, ref := range s.From {
		t, err := db.lookup(ref.Name)
		if err != nil {
			return nil, err
		}
		name := ref.Alias
		if name == "" {
			name = ref.Name
		}
		for _, other := range sc.srcs {
			if other.name == name {
				return nil, errorf("table name %s specified more than once", name)
			}
		}
		sc.srcs = append(sc.srcs, source{name: name, table: t})
	}

	isAgg := len(s.GroupBy) > 0 || hasAggregate(s.Having)
	for _, it := range s.Items {
		isAgg = isAgg || hasAggregate(it.Expr)
	}
	for _, o := range s.OrderBy {
		isAgg = isAgg || hasAggregate(o.Expr)
	}

	filterB := &binder{scope: sc}
	where, err := filterB.bindOpt(s.Where)
	if err != nil {
		return nil, err
	}
	on, err := filterB.bindOpt(s.On)
	if err != nil {
		return nil, err
	}
	conjuncts := splitAnd(where, splitAnd(on, nil))

	var aggs []aggSpec
	b := &binder{scope: sc, allowAgg: isAgg, grouped: isAgg, aggs: &aggs}
	for _, g := range s.GroupBy {
		t, c, err := sc.resolve(g.Qual, g.Name)
		if err != nil {
			return nil, err
		}
		b.groupBy = append(b.groupBy, [2]int{t, c})
	}

	var items []*expr
	var aliases []string
	for _, it := range s.Items {
		if it.Star {
			if len(sc.srcs) == 0 {
				return nil, errorf("no tables specified")
			}
			for ti, src := range sc.srcs {
				for ci := range src.table.Columns {
					e := &expr{op: opCol, t: ti, c: ci}
					if b.grouped && !b.isGrouping(ti, ci) {
						return nil, errorf("column %s must appear in GROUP BY or inside an aggregate", src.table.Columns[ci])
					}
					items = append(items, e)
					aliases = append(aliases, "")
				}
			}
			continue
		}
		e, err := b.bind(it.Expr)
		if err != nil {
			return nil, err
		}
		items = append(items, e)
		aliases = append(aliases, it.Alias)
	}

	having, err := b.bindOpt(s.Having)
	if err != nil {
		return nil, err
	}

	order := make([]orderKey, len(s.OrderBy))
	for i, term := range s.OrderBy {
		k := orderKey{out: -1, desc: term.Desc}
		switch ex := term.Expr; {
		case ex.Kind == syntax.ExprColumn && ex.Qual == "" && slices.Contains(aliases, ex.Name):
			k.out = slices.Index(aliases, ex.Name)
		case ex.Kind == syntax.ExprInt:
			if ex.Int < 1 || ex.Int > int64(len(items)) {
				return nil, errorf("ORDER BY position %d is out of range", ex.Int)
			}
			k.out = int(ex.Int - 1)
		default:
			if k.e, err = b.bind(ex); err != nil {
				return nil, err
			}
		}
		order[i] = k
	}

	// ---- execute ----------------------------------------------------
	envs := scan(sc, conjuncts)

	var rows []outRow
	emit := func(en *env) {
		row := outRow{vals: make([]value.Value, len(items))}
		for i, e := range items {
			row.vals[i] = eval(e, en)
		}
		if len(order) > 0 {
			row.keys = make([]value.Value, len(order))
			for i, k := range order {
				if k.out >= 0 {
					row.keys[i] = row.vals[k.out]
				} else {
					row.keys[i] = eval(k.e, en)
				}
			}
		}
		rows = append(rows, row)
	}

	if !isAgg {
		for i := range envs {
			emit(&envs[i])
		}
	} else {
		for _, g := range groupRows(envs, b.groupBy, len(s.GroupBy) > 0) {
			en := env{r: g.rep.r, agg: computeAggs(aggs, g.rows)}
			if having != nil && !eval(having, &en).IsTrue() {
				continue
			}
			emit(&en)
		}
	}

	if len(order) > 0 {
		sort.SliceStable(rows, func(i, j int) bool {
			for n, k := range order {
				c := value.Compare(rows[i].keys[n], rows[j].keys[n])
				if k.desc {
					c = -c
				}
				if c != 0 {
					return c < 0
				}
			}
			return false
		})
	}

	if s.Offset != nil {
		rows = rows[min(*s.Offset, int64(len(rows))):]
	}
	if s.Limit != nil {
		rows = rows[:min(*s.Limit, int64(len(rows)))]
	}
	res := &Result{Rows: make([][]value.Value, len(rows))}
	for i, r := range rows {
		res.Rows[i] = r.vals
	}
	return res, nil
}

// group is the set of candidate rows sharing the same grouping values.
type group struct {
	rep  env // the first row of the group (empty for an empty ungrouped group)
	rows []env
}

// groupRows partitions envs into groups ordered by their grouping values. When
// grouped is false all rows form a single group, even if there are none.
func groupRows(envs []env, cols [][2]int, grouped bool) []*group {
	if !grouped {
		g := &group{rows: envs}
		if len(envs) > 0 {
			g.rep = envs[0]
		}
		return []*group{g}
	}
	index := make(map[string]*group)
	var groups []*group
	var key []byte
	for i := range envs {
		en := &envs[i]
		key = key[:0]
		for _, c := range cols {
			key = appendKey(key, en.r[c[0]][c[1]])
		}
		g := index[string(key)]
		if g == nil {
			g = &group{rep: *en}
			index[string(key)] = g
			groups = append(groups, g)
		}
		g.rows = append(g.rows, *en)
	}
	sort.SliceStable(groups, func(i, j int) bool {
		for _, c := range cols {
			x := groups[i].rep.r[c[0]][c[1]]
			y := groups[j].rep.r[c[0]][c[1]]
			if n := value.Compare(x, y); n != 0 {
				return n < 0
			}
		}
		return false
	})
	return groups
}

// appendKey appends an unambiguous encoding of v, usable as a hash key:
// values encode equal exactly when they compare equal.
func appendKey(key []byte, v value.Value) []byte {
	switch v.Kind() {
	case value.KindInt, value.KindReal:
		n := uint64(v.AsInt())
		if v.Kind() == value.KindReal {
			n = uint64(v.Hundredths())
		}
		key = append(key, 'n')
		for s := 56; s >= 0; s -= 8 {
			key = append(key, byte(n>>uint(s)))
		}
	case value.KindText:
		s := v.AsText()
		n := len(s)
		key = append(key, 't', byte(n>>24), byte(n>>16), byte(n>>8), byte(n))
		key = append(key, s...)
	default:
		key = append(key, 'z')
	}
	return key
}
