package schema

import (
	"fmt"
	"sort"

	"sqlitefile/btree"
	"sqlitefile/record"
	"sqlitefile/value"
)

// Object is one row of the sqlite_schema table.
type Object struct {
	Type     string // "table", "index", "view" or "trigger"
	Name     string
	TblName  string
	RootPage uint32
	SQL      string
	HasSQL   bool // false when the sql column is NULL
}

// Catalog is the parsed contents of sqlite_schema. Tables and indexes whose
// CREATE statement cannot be parsed are still listed in Objects but have no
// definition.
type Catalog struct {
	Objects []Object // in schema (rowid) order

	tables  map[int]*TableDef // by index into Objects
	indexes map[int]*IndexDef
}

// Load reads sqlite_schema (the table B-tree rooted at page 1) and parses
// every CREATE TABLE and CREATE INDEX statement in it.
func Load(p *btree.Pager) (*Catalog, error) {
	c := &Catalog{tables: map[int]*TableDef{}, indexes: map[int]*IndexDef{}}
	var rec record.Record
	err := p.ScanTable(1, func(rowid int64, payload []byte) (bool, error) {
		if err := rec.Reset(payload); err != nil {
			return false, fmt.Errorf("sqlite_schema row %d: %w", rowid, err)
		}
		o := Object{
			Type:    textOf(rec.Value(0)),
			Name:    textOf(rec.Value(1)),
			TblName: textOf(rec.Value(2)),
		}
		if rp := rec.Value(3); rp.Kind == value.Integer && rp.Int > 0 && rp.Int < 1<<32 {
			o.RootPage = uint32(rp.Int)
		}
		if s := rec.Value(4); s.Kind == value.Text {
			o.SQL, o.HasSQL = s.Str, true
		}
		i := len(c.Objects)
		c.Objects = append(c.Objects, o)
		if o.HasSQL {
			switch o.Type {
			case "table":
				if def, err := ParseTable(o.SQL); err == nil {
					c.tables[i] = def
				}
			case "index":
				if def, err := ParseIndex(o.SQL); err == nil {
					c.indexes[i] = def
				}
			}
		}
		return true, nil
	})
	if err != nil {
		return nil, err
	}
	return c, nil
}

func textOf(v value.Value) string {
	if v.Kind == value.Text {
		return v.Str
	}
	return ""
}

// Table is a table found in the catalog.
type Table struct {
	Name     string
	RootPage uint32
	*TableDef
}

// Index is an index found in the catalog.
type Index struct {
	Name     string
	Table    string
	RootPage uint32
	*IndexDef
}

// Table looks up a table by name, ASCII case-insensitively. Views, triggers
// and indexes are not tables.
func (c *Catalog) Table(name string) (*Table, bool) {
	for i, o := range c.Objects {
		if o.Type == "table" && EqualFold(o.Name, name) {
			def := c.tables[i]
			if def == nil {
				return nil, false
			}
			return &Table{Name: o.Name, RootPage: o.RootPage, TableDef: def}, true
		}
	}
	return nil, false
}

// Index looks up an index created by an explicit CREATE INDEX statement.
// Automatically created indexes (NULL sql) are not returned.
func (c *Catalog) Index(name string) (*Index, bool) {
	for i, o := range c.Objects {
		if o.Type == "index" && o.HasSQL && EqualFold(o.Name, name) {
			def := c.indexes[i]
			if def == nil {
				return nil, false
			}
			return &Index{Name: o.Name, Table: o.TblName, RootPage: o.RootPage, IndexDef: def}, true
		}
	}
	return nil, false
}

// TableNames returns the names of the user tables (those not starting with
// "sqlite_"), sorted bytewise.
func (c *Catalog) TableNames() []string {
	var names []string
	for _, o := range c.Objects {
		if o.Type == "table" && !(len(o.Name) >= 7 && EqualFold(o.Name[:7], "sqlite_")) {
			names = append(names, o.Name)
		}
	}
	sort.Strings(names)
	return names
}

// Schema returns the CREATE statements, in schema order, of every object whose
// tbl_name equals table (ASCII case-insensitively) and whose sql is not NULL.
func (c *Catalog) Schema(table string) []string {
	var out []string
	for _, o := range c.Objects {
		if o.HasSQL && EqualFold(o.TblName, table) {
			out = append(out, o.SQL)
		}
	}
	return out
}
