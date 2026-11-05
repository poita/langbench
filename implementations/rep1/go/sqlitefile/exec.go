package sqlitefile

import (
	"fmt"
	"slices"
	"strings"
)

// Result is a materialised set of rows. TEXT and BLOB values may alias the
// database image and must not be modified.
type Result struct {
	Columns []string
	Rows    [][]Value
}

// colRef is a resolved column: an index into Table.Columns, or rowidRef.
const rowidRef = -1

type planCond struct {
	ref int
	op  Op
	lit Value // affinity already applied
}

// matches reports whether column value v satisfies the condition.
func (c *planCond) matches(v Value) bool {
	switch c.op {
	case OpIs:
		return v.Kind == KindNull && c.lit.Kind == KindNull || v.Kind != KindNull && c.lit.Kind != KindNull && Compare(v, c.lit) == 0
	case OpIsNot:
		return !(v.Kind == KindNull && c.lit.Kind == KindNull || v.Kind != KindNull && c.lit.Kind != KindNull && Compare(v, c.lit) == 0)
	}
	if v.Kind == KindNull || c.lit.Kind == KindNull {
		return false
	}
	r := Compare(v, c.lit)
	switch c.op {
	case OpEq:
		return r == 0
	case OpNe:
		return r != 0
	case OpLt:
		return r < 0
	case OpLe:
		return r <= 0
	case OpGt:
		return r > 0
	}
	return r >= 0
}

// selectPlan is a SELECT resolved against the catalog: names are column
// positions and literals have affinity applied.
type selectPlan struct {
	table    *Table
	names    []string
	cols     []int
	conds    []planCond
	orderRef int
	hasOrder bool
	desc     bool
	limit    int64 // -1: unlimited
}

func (t *Table) resolve(name string) (int, error) {
	if i := t.ColumnIndex(name); i >= 0 {
		return i, nil
	}
	if strings.EqualFold(name, "rowid") {
		return rowidRef, nil
	}
	return 0, fmt.Errorf("%w: %s", ErrNoSuchColumn, name)
}

func (t *Table) affinity(ref int) Affinity {
	if ref == rowidRef {
		return AffinityInteger
	}
	return t.Columns[ref].Affinity
}

// value reads column ref of the current row: it substitutes the rowid for the
// alias column and widens integers stored in REAL-affinity columns.
func (t *Table) value(rec *record, rowid int64, ref int) Value {
	if ref == rowidRef || ref == t.RowidAlias {
		return Value{Kind: KindInteger, I: rowid}
	}
	v := rec.value(ref)
	if v.Kind == KindInteger && t.Columns[ref].Affinity == AffinityReal {
		return Value{Kind: KindReal, F: float64(v.I)}
	}
	return v
}

func (db *DB) planSelect(q *Query) (*selectPlan, error) {
	t, err := db.Table(q.Table)
	if err != nil {
		return nil, err
	}
	p := &selectPlan{table: t, limit: q.Limit}
	if q.Star {
		for i, c := range t.Columns {
			p.cols = append(p.cols, i)
			p.names = append(p.names, c.Name)
		}
	} else {
		for _, name := range q.Columns {
			ref, err := t.resolve(name)
			if err != nil {
				return nil, err
			}
			p.cols = append(p.cols, ref)
			p.names = append(p.names, name)
		}
	}
	for _, c := range q.Where {
		ref, err := t.resolve(c.Column)
		if err != nil {
			return nil, err
		}
		p.conds = append(p.conds, planCond{ref: ref, op: c.Op, lit: ApplyAffinity(c.Value, t.affinity(ref))})
	}
	if q.OrderBy != "" {
		ref, err := t.resolve(q.OrderBy)
		if err != nil {
			return nil, err
		}
		p.orderRef, p.hasOrder, p.desc = ref, true, q.Desc
	}
	return p, nil
}

// scan walks the table in rowid order, calls fn for rows passing every WHERE
// condition, and stops early when fn returns true.
func (db *DB) scan(p *selectPlan, fn func(rowid int64, rec *record, volatile bool) bool) error {
	if p.limit == 0 {
		return nil
	}
	r := &reader{pg: db.pager}
	var rec record
	t := p.table
	return r.walkTable(t.Root, func(rowid int64, payload []byte, vol bool) (bool, error) {
		if err := rec.parse(payload); err != nil {
			return false, err
		}
		for i := range p.conds {
			c := &p.conds[i]
			if !c.matches(t.value(&rec, rowid, c.ref)) {
				return false, nil
			}
		}
		return fn(rowid, &rec, vol), nil
	})
}

// appendRow formats the selected columns of one row, TAB separated, plus LF.
func appendRow(dst []byte, t *Table, cols []int, rec *record, rowid int64) []byte {
	for i, ref := range cols {
		if i > 0 {
			dst = append(dst, '\t')
		}
		dst = AppendValue(dst, t.value(rec, rowid, ref))
	}
	return append(dst, '\n')
}

type matchedRow struct {
	rowid int64
	key   Value
	vals  []Value
}

// selectRows runs a plan and returns the surviving rows, ordered and limited.
func (db *DB) selectRows(p *selectPlan) ([]matchedRow, error) {
	var rows []matchedRow
	t := p.table
	err := db.scan(p, func(rowid int64, rec *record, vol bool) bool {
		m := matchedRow{rowid: rowid, vals: make([]Value, len(p.cols))}
		for i, ref := range p.cols {
			m.vals[i] = keep(t.value(rec, rowid, ref), vol)
		}
		if p.hasOrder {
			m.key = keep(t.value(rec, rowid, p.orderRef), vol)
		}
		rows = append(rows, m)
		return !p.hasOrder && p.limit >= 0 && int64(len(rows)) >= p.limit
	})
	if err != nil {
		return nil, err
	}
	if p.hasOrder {
		slices.SortFunc(rows, func(a, b matchedRow) int {
			c := Compare(a.key, b.key)
			if p.desc {
				c = -c
			}
			if c != 0 {
				return c
			}
			switch {
			case a.rowid < b.rowid:
				return -1
			case a.rowid > b.rowid:
				return 1
			}
			return 0
		})
	}
	if p.limit >= 0 && int64(len(rows)) > p.limit {
		rows = rows[:p.limit]
	}
	return rows, nil
}

// keep copies TEXT/BLOB bytes that live in the reader's scratch buffer.
func keep(v Value, volatile bool) Value {
	if volatile && v.B != nil {
		v.B = append([]byte{}, v.B...)
	}
	return v
}

// Select runs a SELECT query and returns its rows. q.Command must be
// CmdSelect.
func (db *DB) Select(q *Query) (res *Result, err error) {
	defer recoverCorrupt(&err)
	if q.Command != CmdSelect {
		return nil, fmt.Errorf("%w: not a SELECT", ErrQuery)
	}
	p, err := db.planSelect(q)
	if err != nil {
		return nil, err
	}
	rows, err := db.selectRows(p)
	if err != nil {
		return nil, err
	}
	res = &Result{Columns: p.names, Rows: make([][]Value, len(rows))}
	for i := range rows {
		res.Rows[i] = rows[i].vals
	}
	return res, nil
}

// indexPlan is a resolved INDEX command.
type indexPlan struct {
	ix  *Index
	t   *Table
	key Value
}

func (db *DB) planIndex(name string, key Value) (*indexPlan, error) {
	ix, ok := db.Index(name)
	if !ok || len(ix.Columns) != 1 {
		return nil, fmt.Errorf("%w: %s", ErrNoSuchIndex, name)
	}
	t, err := db.Table(ix.Table)
	if err != nil {
		return nil, err
	}
	ref, err := t.resolve(ix.Columns[0])
	if err != nil {
		return nil, err
	}
	return &indexPlan{ix: ix, t: t, key: ApplyAffinity(key, t.affinity(ref))}, nil
}

// lookup finds the matching table rows (ascending rowid) via the index B-tree
// and calls fn for each.
func (db *DB) lookup(p *indexPlan, fn func(rowid int64, rec *record)) error {
	if p.key.Kind == KindNull {
		return nil
	}
	r := &reader{pg: db.pager}
	ids, err := r.indexEq(p.ix.Root, p.key)
	if err != nil {
		return err
	}
	slices.Sort(ids)
	ids = slices.Compact(ids)
	var rec record
	for _, id := range ids {
		payload, _, found, err := r.seekTable(p.t.Root, id)
		if err != nil {
			return err
		}
		if !found {
			continue
		}
		if err := rec.parse(payload); err != nil {
			return err
		}
		fn(id, &rec)
	}
	return nil
}

func (t *Table) allColumns() []int {
	cols := make([]int, len(t.Columns))
	for i := range cols {
		cols[i] = i
	}
	return cols
}

// LookupIndex returns every row whose indexed column equals key, found by a
// key-directed descent of the named single-column index, in rowid order. The
// rows hold all table columns, as SELECT * would.
func (db *DB) LookupIndex(name string, key Value) (res *Result, err error) {
	defer recoverCorrupt(&err)
	p, err := db.planIndex(name, key)
	if err != nil {
		return nil, err
	}
	res = &Result{}
	for _, c := range p.t.Columns {
		res.Columns = append(res.Columns, c.Name)
	}
	cols := p.t.allColumns()
	err = db.lookup(p, func(rowid int64, rec *record) {
		vals := make([]Value, len(cols))
		for i, ref := range cols {
			vals[i] = p.t.value(rec, rowid, ref)
		}
		res.Rows = append(res.Rows, vals)
	})
	if err != nil {
		return nil, err
	}
	return res, nil
}

// Exec runs one query line and appends its output, exactly as the command-line
// tool would write it, to dst. On error dst is returned unchanged.
func (db *DB) Exec(line string, dst []byte) ([]byte, error) {
	q, err := ParseQuery(line)
	if err != nil {
		return dst, err
	}
	return db.ExecQuery(q, dst)
}

// ExecQuery is Exec for an already parsed query.
func (db *DB) ExecQuery(q *Query, dst []byte) (out []byte, err error) {
	start := len(dst)
	defer func() {
		if err != nil {
			out = dst[:start]
		}
	}()
	defer recoverCorrupt(&err)
	switch q.Command {
	case CmdTables:
		for _, name := range db.Tables() {
			dst = append(append(dst, name...), '\n')
		}
	case CmdSchema:
		for _, sql := range db.Schema(q.Table) {
			dst = append(append(dst, sql...), ';', '\n')
		}
	case CmdCount:
		n, err := db.Count(q.Table)
		if err != nil {
			return dst[:start], err
		}
		dst = append(AppendValue(dst, Int(n)), '\n')
	case CmdSelect:
		p, err := db.planSelect(q)
		if err != nil {
			return dst[:start], err
		}
		if p.hasOrder {
			rows, err := db.selectRows(p)
			if err != nil {
				return dst[:start], err
			}
			for _, m := range rows {
				for i, v := range m.vals {
					if i > 0 {
						dst = append(dst, '\t')
					}
					dst = AppendValue(dst, v)
				}
				dst = append(dst, '\n')
			}
			break
		}
		var n int64
		err = db.scan(p, func(rowid int64, rec *record, _ bool) bool {
			dst = appendRow(dst, p.table, p.cols, rec, rowid)
			n++
			return p.limit >= 0 && n >= p.limit
		})
		if err != nil {
			return dst[:start], err
		}
	case CmdIndex:
		p, err := db.planIndex(q.IndexName, q.Key)
		if err != nil {
			return dst[:start], err
		}
		cols := p.t.allColumns()
		err = db.lookup(p, func(rowid int64, rec *record) {
			dst = appendRow(dst, p.t, cols, rec, rowid)
		})
		if err != nil {
			return dst[:start], err
		}
	default:
		return dst, fmt.Errorf("%w: unknown command", ErrQuery)
	}
	return dst, nil
}
