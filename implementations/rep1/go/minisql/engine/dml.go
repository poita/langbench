package engine

import (
	"minisql/syntax"
	"minisql/value"
)

func (db *Database) execCreate(s *syntax.CreateTable) error {
	if db.tables[s.Name] != nil {
		return errorf("table %s already exists", s.Name)
	}
	t := &Table{Name: s.Name}
	for _, c := range s.Columns {
		if t.columnIndex(c.Name) >= 0 {
			return errorf("duplicate column name: %s", c.Name)
		}
		t.Columns = append(t.Columns, c.Name)
	}
	if len(t.Columns) == 0 {
		return errorf("table needs at least one column")
	}
	db.tables[s.Name] = t
	return nil
}

func (db *Database) execInsert(s *syntax.Insert) error {
	t, err := db.lookup(s.Table)
	if err != nil {
		return err
	}
	b := &binder{scope: &scope{}} // no row in scope, no aggregates
	var rows [][]value.Value
	for _, exprs := range s.Rows {
		if len(exprs) != len(t.Columns) {
			return errorf("table %s has %d columns but %d values were supplied", t.Name, len(t.Columns), len(exprs))
		}
		bound := make([]*expr, len(exprs))
		for i, e := range exprs {
			if bound[i], err = b.bind(e); err != nil {
				return err
			}
		}
		row := make([]value.Value, len(bound))
		for i, e := range bound {
			row[i] = eval(e, &env{})
		}
		rows = append(rows, row)
	}
	t.Rows = append(t.Rows, rows...)
	return nil
}

func (db *Database) execDelete(s *syntax.Delete) error {
	t, err := db.lookup(s.Table)
	if err != nil {
		return err
	}
	b := &binder{scope: &scope{srcs: []source{{name: t.Name, table: t}}}}
	where, err := b.bindOpt(s.Where)
	if err != nil {
		return err
	}
	kept := t.Rows[:0]
	var en env
	for _, row := range t.Rows {
		en.r[0] = row
		if where == nil || eval(where, &en).IsTrue() {
			continue
		}
		kept = append(kept, row)
	}
	clear(t.Rows[len(kept):])
	t.Rows = kept
	return nil
}

func (db *Database) execUpdate(s *syntax.Update) error {
	t, err := db.lookup(s.Table)
	if err != nil {
		return err
	}
	b := &binder{scope: &scope{srcs: []source{{name: t.Name, table: t}}}}
	cols := make([]int, len(s.Set))
	vals := make([]*expr, len(s.Set))
	for i, a := range s.Set {
		if cols[i] = t.columnIndex(a.Column); cols[i] < 0 {
			return errorf("no such column: %s", a.Column)
		}
		if vals[i], err = b.bind(a.Value); err != nil {
			return err
		}
	}
	where, err := b.bindOpt(s.Where)
	if err != nil {
		return err
	}
	var en env
	news := make([]value.Value, len(cols))
	for _, row := range t.Rows {
		en.r[0] = row
		if where != nil && !eval(where, &en).IsTrue() {
			continue
		}
		for i, e := range vals {
			news[i] = eval(e, &en) // all right-hand sides see the old row
		}
		for i, c := range cols {
			row[c] = news[i]
		}
	}
	return nil
}
