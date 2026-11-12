package sqlitefile

import (
	"errors"
	"fmt"
	"sort"
	"strconv"

	"sqlitefile/query"
	"sqlitefile/record"
	"sqlitefile/schema"
	"sqlitefile/value"
)

// Exec parses and runs one query line and returns the output lines (without
// line terminators). Errors cover both malformed queries and references to
// objects that do not exist.
func (db *DB) Exec(line string) (lines []string, err error) {
	defer func() {
		if r := recover(); r != nil {
			lines, err = nil, fmt.Errorf("sqlitefile: internal error: %v", r)
		}
	}()
	q, err := query.Parse(line)
	if err != nil {
		return nil, err
	}
	switch q := q.(type) {
	case *query.Tables:
		return db.catalog.TableNames(), nil
	case *query.Schema:
		stmts := db.catalog.Schema(q.Table)
		for i := range stmts {
			stmts[i] += ";"
		}
		return stmts, nil
	case *query.Count:
		return db.count(q)
	case *query.Select:
		return db.selectRows(q)
	case *query.Index:
		return db.indexLookup(q)
	}
	return nil, errors.New("sqlitefile: unknown query type")
}

func (db *DB) count(q *query.Count) ([]string, error) {
	t, ok := db.catalog.Table(q.Table)
	if !ok {
		return nil, fmt.Errorf("no such table: %s", q.Table)
	}
	n, err := db.pager.CountTable(t.RootPage)
	if err != nil {
		return nil, err
	}
	return []string{strconv.FormatInt(n, 10)}, nil
}

// colRef is a resolved column: a position in the record, or the rowid.
type colRef struct {
	pos      int // record position; ignored when rowid
	rowid    bool
	affinity value.Affinity
}

// resolve finds a column by name; a real column wins over the "rowid"
// pseudo-column. A rowid-alias column reads from the rowid.
func resolve(t *schema.Table, name string) (colRef, bool) {
	if i := t.ColumnIndex(name); i >= 0 {
		c := t.Columns[i]
		return colRef{pos: i, rowid: c.RowidPK, affinity: c.Affinity}, true
	}
	if schema.EqualFold(name, "rowid") {
		return colRef{rowid: true, affinity: value.AffinityInteger}, true
	}
	return colRef{}, false
}

// rowReader decodes table rows into column values.
type rowReader struct {
	t   *schema.Table
	rec record.Record
	rid int64
}

func (r *rowReader) load(rowid int64, payload []byte) error {
	r.rid = rowid
	return r.rec.Reset(payload)
}

func (r *rowReader) get(c colRef) value.Value {
	if c.rowid {
		return value.NewInt(r.rid)
	}
	v := r.rec.Value(c.pos)
	if v.Kind == value.Integer && c.affinity == value.AffinityReal {
		return value.NewReal(float64(v.Int))
	}
	return v
}

type cond struct {
	col colRef
	op  query.Op
	lit value.Value
}

func (c cond) matches(v value.Value) bool {
	switch c.op {
	case query.OpIs:
		return value.Compare(v, c.lit) == 0
	case query.OpIsNot:
		return value.Compare(v, c.lit) != 0
	}
	if v.IsNull() || c.lit.IsNull() {
		return false
	}
	r := value.Compare(v, c.lit)
	switch c.op {
	case query.OpEq:
		return r == 0
	case query.OpNe:
		return r != 0
	case query.OpLt:
		return r < 0
	case query.OpLe:
		return r <= 0
	case query.OpGt:
		return r > 0
	}
	return r >= 0 // OpGe
}

func formatRow(r *rowReader, cols []colRef, buf []byte) []byte {
	for i, c := range cols {
		if i > 0 {
			buf = append(buf, '\t')
		}
		buf = append(buf, r.get(c).String()...)
	}
	return buf
}

func (db *DB) allColumns(t *schema.Table) []colRef {
	cols := make([]colRef, len(t.Columns))
	for i, c := range t.Columns {
		cols[i] = colRef{pos: i, rowid: c.RowidPK, affinity: c.Affinity}
	}
	return cols
}

func (db *DB) selectRows(q *query.Select) ([]string, error) {
	t, ok := db.catalog.Table(q.Table)
	if !ok {
		return nil, fmt.Errorf("no such table: %s", q.Table)
	}
	var cols []colRef
	if q.Star {
		cols = db.allColumns(t)
	} else {
		for _, name := range q.Columns {
			c, ok := resolve(t, name)
			if !ok {
				return nil, fmt.Errorf("no such column: %s", name)
			}
			cols = append(cols, c)
		}
	}
	conds := make([]cond, len(q.Where))
	for i, w := range q.Where {
		c, ok := resolve(t, w.Column)
		if !ok {
			return nil, fmt.Errorf("no such column: %s", w.Column)
		}
		conds[i] = cond{col: c, op: w.Op, lit: c.affinity.ApplyToLiteral(w.Literal)}
	}
	var order colRef
	if q.OrderBy != "" {
		var ok bool
		if order, ok = resolve(t, q.OrderBy); !ok {
			return nil, fmt.Errorf("no such column: %s", q.OrderBy)
		}
	}
	if q.HasLimit && q.Limit == 0 {
		return nil, nil
	}

	type sortRow struct {
		key  value.Value
		line string
	}
	var out []string
	var sortRows []sortRow
	sorting := q.OrderBy != ""
	rr := &rowReader{t: t}
	var buf []byte
	err := db.pager.ScanTable(t.RootPage, func(rowid int64, payload []byte) (bool, error) {
		if err := rr.load(rowid, payload); err != nil {
			return false, err
		}
		for _, c := range conds {
			if !c.matches(rr.get(c.col)) {
				return true, nil
			}
		}
		buf = formatRow(rr, cols, buf[:0])
		if sorting {
			sortRows = append(sortRows, sortRow{rr.get(order), string(buf)})
			return true, nil
		}
		out = append(out, string(buf))
		return !(q.HasLimit && int64(len(out)) >= q.Limit), nil
	})
	if err != nil {
		return nil, err
	}
	if sorting {
		// Rows arrive in ascending rowid order and the sort is stable, so
		// ties stay in ascending rowid order for both directions.
		sort.SliceStable(sortRows, func(i, j int) bool {
			c := value.Compare(sortRows[i].key, sortRows[j].key)
			if q.Desc {
				return c > 0
			}
			return c < 0
		})
		if q.HasLimit && int64(len(sortRows)) > q.Limit {
			sortRows = sortRows[:q.Limit]
		}
		out = make([]string, len(sortRows))
		for i, r := range sortRows {
			out[i] = r.line
		}
	}
	return out, nil
}

func (db *DB) indexLookup(q *query.Index) ([]string, error) {
	idx, ok := db.catalog.Index(q.Name)
	if !ok || len(idx.Columns) != 1 {
		return nil, fmt.Errorf("no such single-column index: %s", q.Name)
	}
	t, ok := db.catalog.Table(idx.Table)
	if !ok {
		return nil, fmt.Errorf("index %s: no such table: %s", q.Name, idx.Table)
	}
	col, ok := resolve(t, idx.Columns[0])
	if !ok {
		return nil, fmt.Errorf("index %s: no such column: %s", q.Name, idx.Columns[0])
	}
	key := col.affinity.ApplyToLiteral(q.Literal)
	if key.IsNull() {
		return nil, nil
	}

	var rec record.Record
	cmp := func(entry []byte) (int, error) {
		if err := rec.Reset(entry); err != nil {
			return 0, err
		}
		return value.Compare(rec.Value(0), key), nil
	}
	var rowids []int64
	err := db.pager.SearchIndex(idx.RootPage, cmp, func(entry []byte) error {
		if err := rec.Reset(entry); err != nil {
			return err
		}
		n := rec.Len()
		if n < 2 {
			return errors.New("index entry has no rowid")
		}
		id := rec.Value(n - 1)
		if id.Kind != value.Integer {
			return errors.New("index entry has a non-integer rowid")
		}
		rowids = append(rowids, id.Int)
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Slice(rowids, func(i, j int) bool { return rowids[i] < rowids[j] })

	cols := db.allColumns(t)
	rr := &rowReader{t: t}
	var out []string
	var buf []byte
	for _, id := range rowids {
		payload, found, err := db.pager.SeekTable(t.RootPage, id)
		if err != nil {
			return nil, err
		}
		if !found {
			continue
		}
		if err := rr.load(id, payload); err != nil {
			return nil, err
		}
		buf = formatRow(rr, cols, buf[:0])
		out = append(out, string(buf))
	}
	return out, nil
}
