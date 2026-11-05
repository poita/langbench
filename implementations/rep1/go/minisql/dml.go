package minisql

// CREATE TABLE, INSERT, UPDATE and DELETE: bind (with all checks) and execute.

func (db *DB) execCreate(s *createStmt) {
	if db.tables[s.name] != nil {
		semErr("table %s already exists", s.name)
	}
	t := &Table{name: s.name}
	for _, c := range s.cols {
		if t.colIndex(c.name) >= 0 {
			semErr("duplicate column name: %s", c.name)
		}
		t.cols = append(t.cols, c.name)
		t.types = append(t.types, c.typ)
	}
	db.tables[s.name] = t
}

type insertPlan struct {
	tbl  *Table
	rows [][]*bexpr
}

func (db *DB) bindInsert(s *insertStmt) *insertPlan {
	t := db.lookup(s.table)
	p := &insertPlan{tbl: t}
	b := &binder{sc: &scope{}} // no row in scope; aggregates disallowed
	for _, row := range s.rows {
		if len(row) != len(t.cols) {
			semErr("table %s has %d columns but %d values were supplied", t.name, len(t.cols), len(row))
		}
		brow := make([]*bexpr, len(row))
		for i, e := range row {
			brow[i] = b.bind(e)
		}
		p.rows = append(p.rows, brow)
	}
	return p
}

func (db *DB) execInsert(p *insertPlan) {
	n := len(p.tbl.cols)
	flat := make([]Value, len(p.rows)*n)
	var ctx evalCtx
	for i, row := range p.rows {
		out := flat[i*n : (i+1)*n : (i+1)*n]
		for j, e := range row {
			out[j] = e.eval(&ctx)
		}
		p.tbl.rows = append(p.tbl.rows, out)
	}
}

func (db *DB) singleScope(table string) (*Table, *binder) {
	t := db.lookup(table)
	return t, &binder{sc: &scope{srcs: []source{{name: t.name, tbl: t}}}}
}

type deletePlan struct {
	tbl   *Table
	where []*bexpr
}

func (db *DB) bindDelete(s *deleteStmt) *deletePlan {
	t, b := db.singleScope(s.table)
	p := &deletePlan{tbl: t}
	if s.where != nil {
		p.where = splitAnd(b.bind(s.where), nil)
	}
	return p
}

// allTrue reports whether every conjunct is true for the context's rows.
func allTrue(conj []*bexpr, c *evalCtx) bool {
	for _, e := range conj {
		if e.eval(c).truth() != triTrue {
			return false
		}
	}
	return true
}

func (db *DB) execDelete(p *deletePlan) {
	rows := p.tbl.rows
	if p.where == nil {
		p.tbl.rows = nil
		return
	}
	var ctx evalCtx
	w := 0
	for _, row := range rows {
		ctx.rows[0] = row
		if allTrue(p.where, &ctx) {
			continue
		}
		rows[w] = row
		w++
	}
	clear(rows[w:])
	p.tbl.rows = rows[:w]
}

type updatePlan struct {
	tbl   *Table
	cols  []int
	exprs []*bexpr
	where []*bexpr
}

func (db *DB) bindUpdate(s *updateStmt) *updatePlan {
	t, b := db.singleScope(s.table)
	p := &updatePlan{tbl: t}
	for _, a := range s.sets {
		c := t.colIndex(a.col)
		if c < 0 {
			semErr("no such column: %s", a.col)
		}
		p.cols = append(p.cols, c)
		p.exprs = append(p.exprs, b.bind(a.e))
	}
	if s.where != nil {
		p.where = splitAnd(b.bind(s.where), nil)
	}
	return p
}

func (db *DB) execUpdate(p *updatePlan) {
	var ctx evalCtx
	vals := make([]Value, len(p.exprs))
	for _, row := range p.tbl.rows {
		ctx.rows[0] = row
		if !allTrue(p.where, &ctx) {
			continue
		}
		for i, e := range p.exprs {
			vals[i] = e.eval(&ctx)
		}
		for i, c := range p.cols {
			row[c] = vals[i]
		}
	}
}
