package engine

import (
	"minisql/value"
)

// scan produces the candidate rows of a query in nested-loop order, keeping
// only those for which every conjunct is true.
//
// Conjuncts that read a single source are applied to that table before any
// pairing. For two sources, conjuncts of the form "A = B" whose sides read
// different tables form a composite hash key, so the join costs
// O(A + B + M) rather than O(A·B). Pairs are always emitted in nested-loop
// order: outer (first) table order, then inner (second) table order.
func scan(sc *scope, conjuncts []*expr) []env {
	switch len(sc.srcs) {
	case 0:
		en := env{}
		if allTrue(conjuncts, &en) {
			return []env{en}
		}
		return nil
	case 1:
		var out []env
		for _, row := range sc.srcs[0].table.Rows {
			en := env{}
			en.r[0] = row
			if allTrue(conjuncts, &en) {
				out = append(out, en)
			}
		}
		return out
	}
	return scanJoin(sc, conjuncts)
}

func allTrue(conjuncts []*expr, en *env) bool {
	for _, c := range conjuncts {
		if !eval(c, en).IsTrue() {
			return false
		}
	}
	return true
}

func scanJoin(sc *scope, conjuncts []*expr) []env {
	var filters [2][]*expr
	var residual []*expr
	var keys [2][]*expr // equi-join key expressions per side
	for _, c := range conjuncts {
		switch m := tableMask(c); m {
		case 0, 1:
			filters[0] = append(filters[0], c) // constants are checked with the first table
		case 2:
			filters[1] = append(filters[1], c)
		default:
			if c.op == opEq {
				lm, rm := tableMask(c.l), tableMask(c.r)
				if lm == 1 && rm == 2 {
					keys[0], keys[1] = append(keys[0], c.l), append(keys[1], c.r)
					continue
				}
				if lm == 2 && rm == 1 {
					keys[0], keys[1] = append(keys[0], c.r), append(keys[1], c.l)
					continue
				}
			}
			residual = append(residual, c)
		}
	}

	// Filter each table on its own.
	var side [2][]int
	for t := 0; t < 2; t++ {
		for i, row := range sc.srcs[t].table.Rows {
			en := env{}
			en.r[t] = row
			if allTrue(filters[t], &en) {
				side[t] = append(side[t], i)
			}
		}
	}
	ra, rb := sc.srcs[0].table.Rows, sc.srcs[1].table.Rows

	var out []env
	pair := func(a, b []value.Value) {
		en := env{}
		en.r[0], en.r[1] = a, b
		if allTrue(residual, &en) {
			out = append(out, en)
		}
	}

	if len(keys[0]) == 0 {
		for _, i := range side[0] {
			for _, j := range side[1] {
				pair(ra[i], rb[j])
			}
		}
		return out
	}

	// Hash the second table on its key expressions, then probe in the first
	// table's order. Buckets keep the second table's order.
	buckets := make(map[string][]int, len(side[1]))
	var buf []byte
	for _, j := range side[1] {
		en := env{}
		en.r[1] = rb[j]
		var ok bool
		if buf, ok = joinKey(buf[:0], keys[1], &en); ok {
			buckets[string(buf)] = append(buckets[string(buf)], j)
		}
	}
	for _, i := range side[0] {
		en := env{}
		en.r[0] = ra[i]
		var ok bool
		if buf, ok = joinKey(buf[:0], keys[0], &en); !ok {
			continue
		}
		for _, j := range buckets[string(buf)] {
			pair(ra[i], rb[j])
		}
	}
	return out
}

// joinKey appends the composite key of exprs evaluated against en. ok is
// false if any component is NULL, in which case the row can match nothing.
func joinKey(buf []byte, exprs []*expr, en *env) ([]byte, bool) {
	for _, e := range exprs {
		v := eval(e, en)
		if v.IsNull() {
			return buf, false
		}
		buf = appendKey(buf, v)
	}
	return buf, true
}
