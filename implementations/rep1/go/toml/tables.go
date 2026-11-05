package toml

// seal marks t and every table nested inside it as part of a closed inline
// table. Tables that are already sealed (nested inline tables) are not
// walked again, so sealing is linear overall.
func (t *Table) seal() {
	if t.sealed {
		return
	}
	t.sealed = true
	for _, n := range t.m {
		switch c := n.(type) {
		case *Table:
			c.seal()
		case *Array:
			for _, e := range c.Elems {
				if et, ok := e.(*Table); ok {
					et.seal()
				}
			}
		}
	}
}

// openTable resolves a [path] or [[path]] header from the root and returns
// the table that becomes current.
func (p *parser) openTable(path []string, aot bool) *Table {
	t := p.root
	for _, k := range path[:len(path)-1] {
		child, ok := t.m[k]
		if !ok {
			nt := NewTable()
			t.m[k] = nt
			t = nt
			continue
		}
		t = p.enter(child, k)
	}
	last := path[len(path)-1]
	existing, ok := t.m[last]
	if !aot {
		if !ok {
			nt := NewTable()
			nt.explicit = true
			t.m[last] = nt
			return nt
		}
		et, isTable := existing.(*Table)
		if !isTable || et.explicit || et.dotted || et.sealed {
			p.fail("table " + last + " is already defined")
		}
		et.explicit = true
		return et
	}
	nt := NewTable()
	nt.explicit = true
	if !ok {
		t.m[last] = &Array{Elems: []Node{nt}, aot: true}
		return nt
	}
	arr, isArr := existing.(*Array)
	if !isArr || !arr.aot {
		p.fail(last + " is not an array of tables")
	}
	arr.Elems = append(arr.Elems, nt)
	return nt
}

// enter returns the table a header path continues through when it meets the
// existing node child at segment k: a table not inside an inline table, or
// the last element of an array of tables.
func (p *parser) enter(child Node, k string) *Table {
	switch c := child.(type) {
	case *Table:
		if c.sealed {
			p.fail("cannot extend inline table " + k)
		}
		return c
	case *Array:
		if c.aot {
			return c.Elems[len(c.Elems)-1].(*Table)
		}
	}
	p.fail(k + " is not a table")
	return nil
}

// resolveDotted walks the intermediate segments of a dotted key starting at
// t, creating missing ones as dotted tables, and returns the table that
// receives the final key.
func (p *parser) resolveDotted(t *Table, segs []string) *Table {
	for _, k := range segs {
		child, ok := t.m[k]
		if !ok {
			nt := NewTable()
			nt.dotted = true
			t.m[k] = nt
			t = nt
			continue
		}
		ct, isTable := child.(*Table)
		if !isTable || ct.explicit || ct.sealed {
			p.fail("cannot extend " + k + " with a dotted key")
		}
		t = ct
	}
	return t
}
